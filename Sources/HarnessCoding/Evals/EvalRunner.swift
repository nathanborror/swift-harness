import Foundation
import Harness
import FoundationModels

public struct TrialResult: Codable, Sendable, Equatable {
    public let task: String
    public let suite: String?
    public let trial: Int
    public let passed: Bool
    public let graders: [GraderResult]
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let toolCalls: Int
    public let duration: TimeInterval
    public let sessionPath: String?
    public let workspacePath: String
    public let responseExcerpt: String
    public let error: String?
}

public struct EvalReport: Codable, Sendable {
    public struct TaskSummary: Codable, Sendable, Equatable {
        public let task: String
        public let suite: String?
        public let trials: Int
        public let passes: Int
        public let unknowns: Int
        public let meanInputTokens: Int
        public let meanDuration: TimeInterval
        public var passRate: Double { trials == 0 ? 0 : Double(passes) / Double(trials) }
    }

    public let startedAt: Date
    public let model: String?
    public let trials: [TrialResult]

    public var tasks: [TaskSummary] {
        let names = trials.map(\.task).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return names.map { name in
            let mine = trials.filter { $0.task == name }
            return TaskSummary(
                task: name,
                suite: mine.first?.suite,
                trials: mine.count,
                passes: mine.filter(\.passed).count,
                unknowns: mine.filter { $0.graders.contains { $0.passed == nil } }.count,
                meanInputTokens: mine.isEmpty ? 0 : mine.map(\.inputTokens).reduce(0, +) / mine.count,
                meanDuration: mine.isEmpty ? 0 : mine.map(\.duration).reduce(0, +) / Double(mine.count)
            )
        }
    }

    public func rendered() -> String {
        var lines = ["task                            suite        pass   trials  unknown  tokens   seconds"]
        for summary in tasks {
            let name = summary.task.padding(toLength: 31, withPad: " ", startingAt: 0)
            let suite = (summary.suite ?? "-").padding(toLength: 12, withPad: " ", startingAt: 0)
            let rate = String(format: "%3.0f%%", summary.passRate * 100)
            lines.append("\(name) \(suite) \(rate)   \(summary.passes)/\(summary.trials)     \(summary.unknowns)        \(summary.meanInputTokens)   \(String(format: "%.1f", summary.meanDuration))")
        }
        let failures = trials.filter { !$0.passed }
        if !failures.isEmpty {
            lines.append("")
            lines.append("failures:")
            for trial in failures {
                let failed = trial.graders.filter { $0.passed != true }.map { "\($0.grader): \($0.detail)" }.joined(separator: "; ")
                lines.append("  \(trial.task) #\(trial.trial): \(trial.error ?? failed)")
                if let path = trial.sessionPath { lines.append("    session \(path)") }
            }
        }
        let total = trials.count
        let passed = trials.filter(\.passed).count
        lines.append("")
        lines.append("\(passed)/\(total) trials passed")
        return lines.joined(separator: "\n")
    }
}

/// Runs each task for a number of trials, each in a fresh workspace, and grades the outcomes.
public struct EvalRunner: Sendable {
    public typealias ConfigurationBuilder = @Sendable (_ workspace: Workspace, _ sessionRoot: URL) -> AgentConfiguration

    public let outputRoot: URL
    public let judge: (any LanguageModel)?
    public let configure: ConfigurationBuilder

    public init(outputRoot: URL, judge: (any LanguageModel)? = nil, configure: @escaping ConfigurationBuilder) {
        self.outputRoot = outputRoot
        self.judge = judge
        self.configure = configure
    }

    public func run(tasks: [(task: EvalTask, directory: URL?)], trials: Int, model: String? = nil, progress: (@Sendable (TrialResult) async -> Void)? = nil) async throws -> EvalReport {
        let startedAt = Date()
        let runRoot = outputRoot.appending(path: SessionDirectory.makeSessionID(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        var results: [TrialResult] = []
        for (task, directory) in tasks {
            for trial in 1...max(trials, 1) {
                let result = await runTrial(task: task, taskDirectory: directory, trial: trial, runRoot: runRoot)
                results.append(result)
                await progress?(result)
            }
        }
        let report = EvalReport(startedAt: startedAt, model: model, trials: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: runRoot.appending(path: "report.json"), options: [.atomic])
        try report.rendered().write(to: runRoot.appending(path: "report.txt"), atomically: true, encoding: .utf8)
        return report
    }

    func runTrial(task: EvalTask, taskDirectory: URL?, trial: Int, runRoot: URL) async -> TrialResult {
        let trialRoot = runRoot.appending(path: "\(task.name)-\(trial)", directoryHint: .isDirectory)
        let workspaceURL = trialRoot.appending(path: "workspace", directoryHint: .isDirectory)
        let sessionRoot = trialRoot.appending(path: "sessions", directoryHint: .isDirectory)
        func failure(_ message: String) -> TrialResult {
            TrialResult(task: task.name, suite: task.suite, trial: trial, passed: false, graders: [], inputTokens: 0, cachedTokens: 0, outputTokens: 0, toolCalls: 0, duration: 0, sessionPath: nil, workspacePath: workspaceURL.path, responseExcerpt: "", error: message)
        }
        do {
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            let workspace = try Workspace(root: workspaceURL)
            try await task.seed(workspace: workspace, taskDirectory: taskDirectory)
            let configuration = configure(workspace, sessionRoot)
            let runner = AgentRunner(configuration: configuration)
            let result: AgentRunResult
            if let timeout = task.timeoutSeconds {
                result = try await withThrowingTaskGroup(of: AgentRunResult.self) { group in
                    group.addTask { try await runner.run(prompt: task.prompt) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw TimeLimitError(seconds: timeout)
                    }
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
            } else {
                result = try await runner.run(prompt: task.prompt)
            }
            let context = GradingContext(task: task, workspace: workspace, result: result, judge: judge)
            var graders: [GraderResult] = []
            for grader in task.graders { graders.append(await grader.grade(context)) }
            let passed = !graders.isEmpty && graders.allSatisfy { $0.passed == true }
            return TrialResult(
                task: task.name,
                suite: task.suite,
                trial: trial,
                passed: passed,
                graders: graders,
                inputTokens: result.usage.input.totalTokenCount,
                cachedTokens: result.usage.input.cachedTokenCount,
                outputTokens: result.usage.output.totalTokenCount,
                toolCalls: result.toolCalls.count,
                duration: result.duration,
                sessionPath: result.directory.url.path,
                workspacePath: workspaceURL.path,
                responseExcerpt: String(result.response.prefix(300)),
                error: nil
            )
        } catch {
            return failure(error.localizedDescription)
        }
    }
}
