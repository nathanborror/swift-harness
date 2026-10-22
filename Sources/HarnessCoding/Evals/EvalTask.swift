import Foundation
import Harness

/// One eval task: a prompt, how to seed the workspace, and how to grade the result.
///
/// Stored as `task.json` in a folder. Files in a sibling `files/` folder are
/// copied into the workspace before the run. Graders check the outcome, the
/// final state of the workspace and the transcript, not the path taken.
public struct EvalTask: Codable, Sendable, Equatable {
    public struct Setup: Codable, Sendable, Equatable {
        /// Files to write into the workspace, path to content.
        public var files: [String: String]?
        /// A shell command run in the workspace after the files are written. macOS only.
        public var command: String?

        public init(files: [String: String]? = nil, command: String? = nil) {
            self.files = files
            self.command = command
        }
    }

    public var name: String
    public var prompt: String
    public var setup: Setup?
    public var graders: [Grader]
    public var timeoutSeconds: Int?
    /// Which suite this belongs to: `capability` tasks climb from a low pass rate; `regression` tasks should stay near 100%.
    public var suite: String?

    public init(name: String, prompt: String, setup: Setup? = nil, graders: [Grader], timeoutSeconds: Int? = nil, suite: String? = nil) {
        self.name = name
        self.prompt = prompt
        self.setup = setup
        self.graders = graders
        self.timeoutSeconds = timeoutSeconds
        self.suite = suite
    }

    /// Loads `task.json` from a task folder.
    public static func load(from directory: URL) throws -> EvalTask {
        let data = try Data(contentsOf: directory.appending(path: "task.json"))
        var task = try JSONDecoder().decode(EvalTask.self, from: data)
        if task.name.isEmpty { task.name = directory.lastPathComponent }
        return task
    }

    /// Loads every task folder under a root, sorted by name.
    public static func loadAll(in root: URL) throws -> [(task: EvalTask, directory: URL)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        return try names.compactMap { name in
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.appending(path: "task.json").path) else { return nil }
            return (try load(from: directory), directory)
        }
    }

    /// Writes seed files and copies the task's `files/` folder into a workspace.
    public func seed(workspace: Workspace, taskDirectory: URL?) async throws {
        for (path, content) in setup?.files ?? [:] {
            let url = try workspace.url(for: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        if let taskDirectory {
            let files = taskDirectory.appending(path: "files", directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: files.path) {
                let names = try FileManager.default.contentsOfDirectory(atPath: files.path)
                for name in names {
                    let destination = workspace.root.appending(path: name)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.copyItem(at: files.appending(path: name), to: destination)
                }
            }
        }
        #if os(macOS)
        if let command = setup?.command {
            let result = try await ProcessRunner.run(command: command, directory: workspace.root, timeout: 120)
            guard result.exitCode == 0, !result.timedOut else {
                throw EvalError.setupFailed(task: name, output: result.output)
            }
        }
        #endif
    }
}

public enum EvalError: Error, Sendable, LocalizedError {
    case setupFailed(task: String, output: String)

    public var errorDescription: String? {
        switch self {
        case .setupFailed(let task, let output): "Setup for task \(task) failed:\n\(output)"
        }
    }
}
