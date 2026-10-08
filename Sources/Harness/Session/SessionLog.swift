import Foundation
import FoundationModels

/// What the harness records about a session, beyond the transcript itself.
///
/// Transcript entries are logged as they are appended, each wrapped in a
/// one-entry `Transcript` because entries are not individually `Codable`.
public enum HarnessEvent: Codable, Sendable, Equatable {
    case sessionStarted(sessionID: String, modelID: String?)
    case prompt(Transcript)
    case reasoning(Transcript)
    case response(Transcript)
    case toolCall(Transcript)
    case toolOutput(Transcript)
    case permission(tool: String, decision: PermissionDecision, rule: String?, reason: String?, arguments: String)
    case toolResult(tool: String, characters: Int, truncated: Bool, offloadedTo: String?, duration: TimeInterval, failed: Bool)
    case escalation(reason: String)
    case note(String)
}

public struct LogRecord: Codable, Sendable, Equatable {
    public let sequence: Int
    public let timestamp: Date
    public let event: HarnessEvent
}

/// An append-only JSONL log, one record per line.
///
/// Writes never throw to the caller: a logging failure must not stop a reply.
/// The last failure is kept on `lastError` for the app to surface.
public actor SessionLog {
    public nonisolated let url: URL
    public private(set) var lastError: (any Error)?
    private var sequence: Int
    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.sequence = (try? Self.read(url: url).last?.sequence).map { $0 + 1 } ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    @discardableResult
    public func record(_ event: HarnessEvent) -> LogRecord {
        let record = LogRecord(sequence: sequence, timestamp: Date(), event: event)
        sequence += 1
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            lastError = error
        }
        return record
    }

    public func close() {
        try? handle.close()
    }

    /// Reads every record in the file. Malformed lines are skipped.
    public static func read(url: URL) throws -> [LogRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(LogRecord.self, from: line)
        }
    }
}
