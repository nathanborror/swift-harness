#if os(macOS)
import Foundation
import FoundationModels

/// Long-running commands the model started and may check on later.
///
/// Each process streams its output to a file so the model reads a bounded tail
/// instead of holding the whole thing in context. A completion handler lets the
/// app wake a session when a process exits, so nothing has to poll.
public actor BackgroundProcessManager {
    public enum Status: Sendable, Equatable, Codable {
        case running
        case exited(code: Int32)
        case stopped
    }

    public struct Record: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let command: String
        public let outputPath: String
        public let startedAt: Date
        public var status: Status
        public var finishedAt: Date?
    }

    public typealias ExitHandler = @Sendable (Record) async -> Void

    private var records: [String: Record] = [:]
    private var processes: [String: Process] = [:]
    private let outputsDirectory: URL
    private var onExit: ExitHandler?

    public init(outputsDirectory: URL) {
        self.outputsDirectory = outputsDirectory
    }

    /// Called after a process exits, with its final record.
    public func setExitHandler(_ handler: ExitHandler?) {
        onExit = handler
    }

    public var all: [Record] { records.values.sorted { $0.startedAt < $1.startedAt } }

    public func record(_ id: String) -> Record? { records[id] }

    /// Starts a command and returns its record at once.
    public func start(command: String, directory: URL) throws -> Record {
        try FileManager.default.createDirectory(at: outputsDirectory, withIntermediateDirectories: true)
        let id = "bg_" + String(UUID().uuidString.prefix(8)).lowercased()
        let outputURL = outputsDirectory.appending(path: "\(id).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(ProcessRunner.environment) { _, override in override }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] finished in
            try? handle.close()
            let code = finished.terminationStatus
            let killed = finished.terminationReason == .uncaughtSignal
            Task { await self?.finish(id, code: code, killed: killed) }
        }
        try process.run()
        let record = Record(id: id, command: command, outputPath: outputURL.path, startedAt: Date(), status: .running, finishedAt: nil)
        records[id] = record
        processes[id] = process
        return record
    }

    private func finish(_ id: String, code: Int32, killed: Bool) async {
        guard var record = records[id] else { return }
        if record.status == .running {
            record.status = killed ? .stopped : .exited(code: code)
        }
        record.finishedAt = Date()
        records[id] = record
        processes[id] = nil
        await onExit?(record)
    }

    /// Terminates a running process, escalating to a kill signal after a moment.
    public func stop(_ id: String) async -> Record? {
        guard var record = records[id] else { return nil }
        guard let process = processes[id], record.status == .running else { return record }
        record.status = .stopped
        records[id] = record
        process.terminate()
        try? await Task.sleep(for: .seconds(1))
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return records[id]
    }

    /// The last part of a process's output.
    public func outputTail(_ id: String, maximumCharacters: Int = 4_000) -> String {
        guard let record = records[id], let text = try? String(contentsOf: URL(fileURLWithPath: record.outputPath), encoding: .utf8) else { return "" }
        return String(text.suffix(maximumCharacters))
    }

    /// Waits until the process is no longer running, or the timeout passes.
    public func waitForExit(_ id: String, timeout: Duration) async -> Record? {
        let deadline = ContinuousClock.now + timeout
        while let record = records[id], record.status == .running, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return records[id]
    }
}

/// Reports on a background process and returns the tail of its output.
public struct ProcessStatusTool: AnnotatedTool {
    @Generable(description: "Check a background process.")
    public struct Arguments {
        @Guide(description: "The process id returned when it was started")
        public var id: String
    }

    public let name = "process_status"
    public let description = "Reports whether a background process is still running or how it exited, with the last part of its output. Do not poll in a loop; the harness wakes you when the process exits."
    public let annotations: ToolAnnotations = .readOnly
    let manager: BackgroundProcessManager

    public init(manager: BackgroundProcessManager) {
        self.manager = manager
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let record = await manager.record(arguments.id) else {
            let ids = await manager.all.map(\.id).joined(separator: ", ")
            return "No background process \(arguments.id). Known: \(ids.isEmpty ? "none" : ids)."
        }
        let tail = await manager.outputTail(arguments.id)
        let status: String
        switch record.status {
        case .running: status = "running"
        case .exited(let code): status = "exited with code \(code)"
        case .stopped: status = "stopped"
        }
        return "\(record.id) is \(status). Full output: \(record.outputPath)\n\n\(tail.isEmpty ? "(no output yet)" : tail)"
    }
}

/// Stops a background process.
public struct ProcessStopTool: AnnotatedTool {
    @Generable(description: "Stop a background process.")
    public struct Arguments {
        @Guide(description: "The process id")
        public var id: String
    }

    public let name = "process_stop"
    public let description = "Stops a background process started with the shell tool."
    public let annotations: ToolAnnotations = .mutating
    let manager: BackgroundProcessManager

    public init(manager: BackgroundProcessManager) {
        self.manager = manager
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let record = await manager.stop(arguments.id) else { return "No background process \(arguments.id)." }
        return "\(record.id) \(record.status == .running ? "is still running" : "stopped")."
    }
}
#endif
