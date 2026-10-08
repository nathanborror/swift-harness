import Foundation
import FoundationModels

/// Shared state for the coding tools: where they may work, what the model has
/// read, and a lock that serializes edits.
public final class CodingToolContext: Sendable {
    public struct Limits: Sendable, Equatable {
        /// Lines returned by one read when no limit is given.
        public var readLines: Int
        /// Bytes returned by one read at most.
        public var readBytes: Int
        /// Shell time limit when the model gives none.
        public var shellTimeout: TimeInterval
        /// The longest time limit the model may ask for.
        public var shellTimeoutMaximum: TimeInterval

        public init(readLines: Int = 2_000, readBytes: Int = 50_000, shellTimeout: TimeInterval = 120, shellTimeoutMaximum: TimeInterval = 600) {
            self.readLines = readLines
            self.readBytes = readBytes
            self.shellTimeout = shellTimeout
            self.shellTimeoutMaximum = shellTimeoutMaximum
        }
    }

    public let workspace: Workspace
    public let limits: Limits
    let reads: FileReadRegistry
    let edits: EditSerializer

    public init(workspace: Workspace, limits: Limits = Limits()) {
        self.workspace = workspace
        self.limits = limits
        self.reads = FileReadRegistry()
        self.edits = EditSerializer()
    }
}

/// Remembers what the model has read so edits can refuse to overwrite a file
/// that changed on disk, or one the model never looked at.
actor FileReadRegistry {
    struct Snapshot: Equatable {
        var modified: Date?
        var size: Int?
    }

    enum Status: Equatable {
        case unread
        case unchanged
        case changed
    }

    private var snapshots: [String: Snapshot] = [:]

    func recordRead(_ url: URL) {
        snapshots[url.path] = Self.snapshot(of: url)
    }

    func status(of url: URL) -> Status {
        guard let recorded = snapshots[url.path] else { return .unread }
        return recorded == Self.snapshot(of: url) ? .unchanged : .changed
    }

    private static func snapshot(of url: URL) -> Snapshot {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Snapshot(modified: attributes?[.modificationDate] as? Date, size: attributes?[.size] as? Int)
    }
}

/// Runs file mutations one at a time so two tool calls cannot interleave
/// writes to the same file.
actor EditSerializer {
    func perform<T: Sendable>(_ body: @Sendable () throws -> T) rethrows -> T {
        try body()
    }
}

public enum CodingToolError: Error, Sendable, LocalizedError, Equatable {
    case notFound(path: String, suggestions: [String])
    case notUTF8(path: String)
    case notRead(path: String)
    case changedSinceRead(path: String)
    case textNotFound(path: String, index: Int)
    case textNotUnique(path: String, index: Int, occurrences: Int)
    case isDirectory(path: String)
    case timeout(seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .notFound(let path, let suggestions):
            var text = "File not found: \(path)"
            if !suggestions.isEmpty { text += "\nDid you mean one of these?\n" + suggestions.map { "  \($0)" }.joined(separator: "\n") }
            return text
        case .notUTF8(let path):
            return "\(path) is not UTF-8 text. Use the shell to inspect binary files."
        case .notRead(let path):
            return "\(path) has not been read in this session. Read it first, then edit or overwrite it."
        case .changedSinceRead(let path):
            return "\(path) changed on disk since it was last read. Read it again before editing."
        case .textNotFound(let path, let index):
            return "Edit \(index + 1): old_text was not found in \(path). The text must match exactly, including whitespace and indentation. Re-read the file and copy the exact text."
        case .textNotUnique(let path, let index, let occurrences):
            return "Edit \(index + 1): old_text appears \(occurrences) times in \(path). Include more surrounding context so it matches exactly once, or set replace_all to true."
        case .isDirectory(let path):
            return "\(path) is a directory."
        case .timeout(let seconds):
            return "Command did not complete within \(seconds) seconds and was killed. If it needs longer and is not waiting for input, retry with a larger timeout_seconds."
        }
    }
}

enum CodingToolSupport {
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    static func readText(at url: URL, path: String) throws -> String {
        try readFile(at: url, path: path).text
    }

    /// Reads UTF-8 text and reports whether a byte-order mark was present,
    /// since Foundation's string decoding drops it silently.
    static func readFile(at url: URL, path: String) throws -> (text: String, hasBOM: Bool) {
        var data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CodingToolError.notFound(path: path, suggestions: suggestions(for: url))
        }
        let hasBOM = data.starts(with: utf8BOM)
        if hasBOM { data.removeFirst(utf8BOM.count) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodingToolError.notUTF8(path: path)
        }
        return (text, hasBOM)
    }

    /// Up to three names in the same folder that resemble the missing one.
    static func suggestions(for url: URL) -> [String] {
        let wanted = url.lastPathComponent.lowercased()
        guard !wanted.isEmpty,
            let names = try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        else { return [] }
        let stem = wanted.split(separator: ".").first.map(String.init) ?? wanted
        return names
            .filter { name in
                let lowered = name.lowercased()
                return lowered.contains(stem) || stem.contains(lowered.split(separator: ".").first.map(String.init) ?? lowered)
            }
            .sorted()
            .prefix(3)
            .map { url.deletingLastPathComponent().appending(path: $0).path }
    }
}
