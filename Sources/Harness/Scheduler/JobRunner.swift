import Foundation
import FoundationModels

/// What one tick produced.
public struct JobResult: Sendable, Equatable {
    public var outcome: JobOutcome
    public var summary: String
    /// Text for the owner, or nil to stay silent.
    public var notification: String?
    /// A full replacement for the job's scratch checklist.
    public var scratch: String?
    /// Seconds until the next check, when the job paces itself.
    public var nextCheckSeconds: Int?
    public var inputTokens: Int
    public var outputTokens: Int

    public init(outcome: JobOutcome, summary: String, notification: String? = nil, scratch: String? = nil, nextCheckSeconds: Int? = nil, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.outcome = outcome
        self.summary = summary
        self.notification = notification
        self.scratch = scratch
        self.nextCheckSeconds = nextCheckSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static let silent = JobResult(outcome: .noChange, summary: "NO_REPLY")
}

/// The time context a scheduled run receives, since models do not track time.
public struct WakeMessage: Sendable, Equatable {
    public let job: Job
    public let scheduledAt: Date?
    public let now: Date
    /// System events queued since the job last ran, such as a background process exiting.
    public let events: [String]

    public init(job: Job, scheduledAt: Date?, now: Date, events: [String] = []) {
        self.job = job
        self.scheduledAt = scheduledAt
        self.now = now
        self.events = events
    }

    public func rendered() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = job.schedule.timeZone
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm zzz"
        var lines = [
            "This is an unattended scheduled run of the job \"\(job.name)\". Nobody is present to clarify or approve, so complete the task with what you have. Your final reply is the deliverable, not a plan, an acknowledgement, or a request for input. If nothing needs doing, reply exactly NO_REPLY. If something failed, start your reply with AUTOMATION_FAILED on its own line, then say what failed and what you tried; the scheduler owns retries and alerts. Do not sleep or poll; if you need to check again later, say so through the job_respond tool.",
            "Current time: \(formatter.string(from: now)).",
        ]
        if let scheduledAt { lines.append("Scheduled time: \(formatter.string(from: scheduledAt)).") }
        if !events.isEmpty { lines.append("Events since the last run:\n" + events.map { "- \($0)" }.joined(separator: "\n")) }
        if !job.state.scratch.isEmpty { lines.append("Checklist:\n\(job.state.scratch)") }
        lines.append("Task:\n\(job.prompt)")
        return lines.joined(separator: "\n\n")
    }
}

/// Runs one tick. The default runs a fresh agent session; an app can supply
/// its own to run in its main session or through a different model.
public protocol JobRunner: Sendable {
    func run(_ wake: WakeMessage) async throws -> JobResult
}

/// The response tool a scheduled run uses to end in a named outcome, notify
/// or stay quiet, rewrite its checklist, and choose its next check.
public struct JobResponseTool: AnnotatedTool {
    @Generable(description: "Report the outcome of this scheduled run.")
    public struct Arguments {
        @Guide(description: "no_change, progress, done, blocked, or needs_attention", .anyOf(["no_change", "progress", "done", "blocked", "needs_attention"]))
        public var outcome: String
        @Guide(description: "One or two sentences on what happened, for the run log")
        public var summary: String
        @Guide(description: "Whether the owner should be told")
        public var notify: Bool
        @Guide(description: "The message for the owner, when notify is true")
        public var notificationText: String?
        @Guide(description: "Seconds until the next check, between 60 and 3600, when the pace should change")
        public var nextCheckSeconds: Int?
        @Guide(description: "A full replacement for the checklist, when it should change")
        public var scratch: String?
    }

    public let name = "job_respond"
    public let description = "Ends this scheduled run with a named outcome. Call it once, last. Use notify only for things the owner must see; routine status stays quiet."
    public let annotations: ToolAnnotations = .readOnly
    let sink: JobResultSink

    public init(sink: JobResultSink) {
        self.sink = sink
    }

    public func call(arguments: Arguments) async throws -> String {
        let outcome = JobOutcome(rawValue: arguments.outcome) ?? .progress
        await sink.store(JobResult(
            outcome: outcome,
            summary: arguments.summary,
            notification: arguments.notify ? (arguments.notificationText ?? arguments.summary) : nil,
            scratch: arguments.scratch,
            nextCheckSeconds: arguments.nextCheckSeconds
        ))
        return "Recorded outcome \(outcome.rawValue). You may finish your reply now."
    }
}

public actor JobResultSink {
    private var result: JobResult?
    public init() {}
    func store(_ result: JobResult) { self.result = result }
    func take() -> JobResult? { result }
}

/// Runs a job in a fresh session with the configured tools, the response tool,
/// and the wake message as the prompt. Silence is `NO_REPLY`.
public struct AgentJobRunner: JobRunner {
    public let model: any LanguageModel
    public let tools: [any Tool]
    public let instructions: String
    public let log: SessionLog?

    public init(model: any LanguageModel, tools: [any Tool], instructions: String = "You run scheduled checks for a person who is not present. Be brief and factual.", log: SessionLog? = nil) {
        self.model = model
        self.tools = tools
        self.instructions = instructions
        self.log = log
    }

    public func run(_ wake: WakeMessage) async throws -> JobResult {
        let sink = JobResultSink()
        var allowed = tools
        if let names = wake.job.toolNames { allowed = tools.filter { names.contains($0.name) } }
        allowed.append(JobResponseTool(sink: sink))
        let counter = ToolCallCounter(limit: wake.job.limits.maximumToolCalls)
        let session = LanguageModelSession(profile: JobProfile(model: model, instructions: instructions, tools: allowed, counter: counter))
        let response = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await session.respond(to: wake.rendered()).content }
            group.addTask {
                try await Task.sleep(for: .seconds(wake.job.limits.timeoutSeconds))
                throw CodingToolError.timeout(seconds: wake.job.limits.timeoutSeconds)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        let input = session.usage.input.totalTokenCount
        let output = session.usage.output.totalTokenCount
        let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if var recorded = await sink.take() {
            recorded.inputTokens = input
            recorded.outputTokens = output
            return recorded
        }
        if text == "NO_REPLY" || text.isEmpty {
            var silent = JobResult.silent
            silent.inputTokens = input
            silent.outputTokens = output
            return silent
        }
        if text.hasPrefix("AUTOMATION_FAILED") {
            return JobResult(outcome: .failed, summary: String(text.dropFirst("AUTOMATION_FAILED".count)).trimmingCharacters(in: .whitespacesAndNewlines), notification: nil, inputTokens: input, outputTokens: output)
        }
        return JobResult(outcome: .progress, summary: String(text.prefix(500)), notification: text, inputTokens: input, outputTokens: output)
    }
}

struct JobProfile: LanguageModelSession.DynamicProfile, Sendable {
    let model: any LanguageModel
    let instructions: String
    let tools: [any Tool]
    let counter: ToolCallCounter

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(instructions)
            tools
        }
        .model(model)
        .onToolCall { try await counter.count() }
    }
}
