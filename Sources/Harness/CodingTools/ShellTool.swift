#if os(macOS)
import Foundation
import FoundationModels

/// Runs a shell command inside the workspace.
///
/// Each call is a fresh `/bin/sh` process. On a sandboxed app the child
/// inherits the app's sandbox, so it can reach only what the app can. The
/// environment is fixed so nothing pages or emits color codes. At the time
/// limit the process is killed and the model is told how to retry.
public struct ShellTool: AnnotatedTool {
    @Generable(description: "Run a shell command.")
    public struct Arguments {
        @Guide(description: "The command, run with /bin/sh -c")
        public var command: String
        @Guide(description: "Working directory, relative to the workspace. Defaults to the workspace root.")
        public var workdir: String?
        @Guide(description: "Time limit in seconds. Defaults to 120, at most 600.", .range(1...600))
        public var timeoutSeconds: Int?
    }

    public let name: String
    public let description = "Runs a command with /bin/sh in the workspace and returns its combined output and exit code. Output is captured in full and bounded afterward, so do not pipe through head or tail. Commands cannot answer interactive prompts. Prefer rg for search."
    public let annotations = ToolAnnotations(isReadOnly: false, isDestructive: false, isOpenWorld: true)
    let context: CodingToolContext

    public init(context: CodingToolContext, name: String = "shell") {
        self.context = context
        self.name = name
    }

    public func call(arguments: Arguments) async throws -> String {
        let directory = try arguments.workdir.map { try context.workspace.url(for: $0) } ?? context.workspace.root
        let limit = min(TimeInterval(arguments.timeoutSeconds ?? Int(context.limits.shellTimeout)), context.limits.shellTimeoutMaximum)
        let result = try await ProcessRunner.run(command: arguments.command, directory: directory, timeout: limit)
        var text = result.output.trimmingCharacters(in: .newlines)
        if text.isEmpty { text = "(no output)" }
        if result.timedOut {
            return text + "\n\n[" + (CodingToolError.timeout(seconds: Int(limit)).errorDescription ?? "timed out") + "]"
        }
        if result.exitCode != 0 {
            text += "\n\n[exit code \(result.exitCode)]"
        }
        return text
    }
}

enum ProcessRunner {
    struct Result: Sendable {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
    }

    static let environment: [String: String] = [
        "TERM": "dumb",
        "NO_COLOR": "1",
        "PAGER": "cat",
        "GIT_PAGER": "cat",
        "GIT_TERMINAL_PROMPT": "0",
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
    ]

    static func run(command: String, directory: URL, timeout: TimeInterval) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }

        let exited = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.continuation.yield(); exited.continuation.finish() }
        try process.run()

        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in exited.stream { break }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return !Task.isCancelled
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if timedOut {
            process.terminate()
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        // Give the readability handler a moment to drain what the process wrote last.
        try? await Task.sleep(for: .milliseconds(50))
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close()

        return Result(output: buffer.text, exitCode: process.terminationStatus, timedOut: timedOut)
    }

    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.withLock { data.append(chunk) }
        }

        var text: String {
            lock.withLock { String(decoding: data, as: UTF8.self) }
        }
    }
}
#endif
