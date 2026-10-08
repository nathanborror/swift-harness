import Foundation
import FoundationModels

/// The on-disk home of one session: its event log, its saved transcript, and
/// the folder where oversized tool output is parked.
///
/// ```text
/// <root>/<sessionID>/
///   events.jsonl      append-only harness events
///   transcript.json   the framework transcript, saved after every turn
///   outputs/          offloaded tool results
/// ```
public struct SessionDirectory: Sendable, Hashable {
    public let url: URL

    public var sessionID: String { url.lastPathComponent }
    public var logURL: URL { url.appending(path: "events.jsonl") }
    public var transcriptURL: URL { url.appending(path: "transcript.json") }
    public var outputsURL: URL { url.appending(path: "outputs", directoryHint: .isDirectory) }

    /// Creates or opens `<root>/<sessionID>`.
    public init(root: URL, sessionID: String = Self.makeSessionID()) throws {
        self.url = root.appending(path: sessionID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputsURL, withIntermediateDirectories: true)
    }

    /// A root inside the app's Application Support folder.
    public static func defaultRoot(subdirectory: String = "Harness/Sessions") throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: subdirectory, directoryHint: .isDirectory)
    }

    /// Sortable, filesystem-safe: a timestamp followed by a short random suffix.
    public static func makeSessionID(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "\(formatter.string(from: date))-\(suffix)"
    }

    /// Lists existing session directories under a root, newest first.
    public static func list(in root: URL) throws -> [SessionDirectory] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let items = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { SessionDirectory(existing: $0) }
            .sorted { $0.sessionID > $1.sessionID }
    }

    private init(existing url: URL) {
        self.url = url
    }

    public func makeLog() throws -> SessionLog {
        try SessionLog(url: logURL)
    }

    public func saveTranscript(_ transcript: Transcript) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(transcript)
        try data.write(to: transcriptURL, options: [.atomic])
    }

    public func loadTranscript() throws -> Transcript? {
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return nil }
        let data = try Data(contentsOf: transcriptURL)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }
}
