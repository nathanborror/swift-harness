import Foundation

/// The agent's memory on disk: plain Markdown files the model reads and writes.
///
/// ```text
/// <root>/
///   MEMORY.md        index and curated facts, loaded every session under a cap
///   USER.md          preferences as dated directives, loaded every session, small cap
///   notes/           one append-only file per day, searched on demand
///   topics/          one subject per file, read on demand
/// ```
///
/// Only the index and the user file enter the context automatically. Everything
/// else is reached through the memory tools. The harness never edits the curated
/// files itself; it caps what it shows and tells the model when a file is over.
public struct MemoryDirectory: Sendable, Hashable {
    public struct Limits: Sendable, Hashable {
        /// Characters of `MEMORY.md` shown each session.
        public var indexCharacters: Int
        /// Lines of `MEMORY.md` shown each session.
        public var indexLines: Int
        /// Characters of `USER.md` shown each session.
        public var userCharacters: Int
        /// Characters of recent notes shown when a session starts.
        public var recentNotesCharacters: Int

        public init(indexCharacters: Int = 25_000, indexLines: Int = 200, userCharacters: Int = 4_000, recentNotesCharacters: Int = 8_000) {
            self.indexCharacters = indexCharacters
            self.indexLines = indexLines
            self.userCharacters = userCharacters
            self.recentNotesCharacters = recentNotesCharacters
        }
    }

    public let root: URL
    public let limits: Limits

    public var indexURL: URL { root.appending(path: "MEMORY.md") }
    public var userURL: URL { root.appending(path: "USER.md") }
    public var notesURL: URL { root.appending(path: "notes", directoryHint: .isDirectory) }
    public var topicsURL: URL { root.appending(path: "topics", directoryHint: .isDirectory) }

    public init(root: URL, limits: Limits = Limits()) throws {
        self.root = root.standardizedFileURL
        self.limits = limits
        for url in [notesURL, topicsURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [indexURL, userURL] where !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    /// A memory root in the app's Application Support folder, optionally scoped to a project name.
    public static func defaultRoot(project: String? = nil) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var url = support.appending(path: "Harness/Memory", directoryHint: .isDirectory)
        if let project { url.append(path: project, directoryHint: .isDirectory) }
        return url
    }

    // MARK: Reading for the context window

    public struct Rendering: Sendable, Equatable {
        public let text: String
        public let truncated: Bool
    }

    /// The index, cut to the limits. Says so when it was cut, and leaves the file alone.
    public func renderIndex() -> Rendering {
        render(indexURL, characters: limits.indexCharacters, lines: limits.indexLines, name: "MEMORY.md")
    }

    public func renderUser() -> Rendering {
        render(userURL, characters: limits.userCharacters, lines: nil, name: "USER.md")
    }

    /// Today's and yesterday's notes, newest first, under the notes cap.
    public func renderRecentNotes(now: Date = Date()) -> Rendering {
        var pieces: [String] = []
        for offset in [0, -1] {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: now) ?? now
            let url = noteURL(for: date)
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            pieces.append("### \(url.lastPathComponent)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let joined = pieces.joined(separator: "\n\n")
        guard joined.count > limits.recentNotesCharacters else { return Rendering(text: joined, truncated: false) }
        let cut = String(joined.prefix(limits.recentNotesCharacters))
        return Rendering(text: cut + "\n\n[Recent notes truncated at \(limits.recentNotesCharacters) characters. Use memory_search or memory_read for the rest.]", truncated: true)
    }

    private func render(_ url: URL, characters: Int, lines: Int?, name: String) -> Rendering {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Rendering(text: "", truncated: false) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var kept = trimmed
        var truncated = false
        if let lines {
            let all = kept.split(separator: "\n", omittingEmptySubsequences: false)
            if all.count > lines {
                kept = all.prefix(lines).joined(separator: "\n")
                truncated = true
            }
        }
        if kept.count > characters {
            kept = String(kept.prefix(characters))
            truncated = true
        }
        if truncated {
            kept += "\n\n[\(name) is over its limit of \(characters) characters\(lines.map { " or \($0) lines" } ?? "") and was cut here. The file on disk is intact. Read it with memory_read and shorten it: merge duplicates, drop stale entries, move detail into topics/.]"
        }
        return Rendering(text: kept, truncated: truncated)
    }

    // MARK: Writing

    public func noteURL(for date: Date = Date()) -> URL {
        notesURL.appending(path: "\(Self.dayFormatter.string(from: date)).md")
    }

    /// Appends a paragraph to today's note with a timestamp. Append-only by construction.
    @discardableResult
    public func appendNote(_ text: String, date: Date = Date()) throws -> URL {
        let url = noteURL(for: date)
        let stamp = Self.timeFormatter.string(from: date)
        let entry = "- \(stamp) \(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } else {
            try "# \(Self.dayFormatter.string(from: date))\n\n\(entry)".write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    // MARK: Search

    public struct Match: Sendable, Equatable {
        public let path: String
        public let line: Int
        public let text: String
    }

    /// Case-insensitive keyword search over every Markdown file. Every term must appear on the line.
    public func search(_ query: String, limit: Int = 20) -> [Match] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return [] }
        var matches: [Match] = []
        for url in markdownFiles() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lowered = line.lowercased()
                guard terms.allSatisfy({ lowered.contains($0) }) else { continue }
                matches.append(Match(path: relativePath(url), line: index + 1, text: String(line)))
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    func markdownFiles() -> [URL] {
        var urls: [URL] = [indexURL, userURL]
        for directory in [notesURL, topicsURL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            urls += names.filter { $0.hasSuffix(".md") }.sorted(by: >).map { directory.appending(path: $0) }
        }
        return urls
    }

    func relativePath(_ url: URL) -> String {
        let rootPath = root.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
