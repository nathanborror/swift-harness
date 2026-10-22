import Foundation
import FoundationModels
import Observation

/// A long-lived agent session for an app to observe.
///
/// Owns the framework session across turns, so `session.transcript` and
/// `session.isResponding` are available to views directly, and adds what the
/// framework does not expose: the text streaming in, recent harness activity,
/// the last error, and the permission prompter. Create it with a configuration,
/// optionally resuming from a saved transcript.
@MainActor
@Observable
public final class AgentSession: AgentObserver {
    public private(set) var session: LanguageModelSession?
    public private(set) var directory: SessionDirectory?
    /// The reply being streamed for the current turn.
    public private(set) var streamingText = ""
    /// Recent harness events, newest last, capped.
    public private(set) var activity: [HarnessEvent] = []
    public private(set) var usage = LanguageModelSession.Usage(input: .init(totalTokenCount: 0, cachedTokenCount: 0), output: .init(totalTokenCount: 0, reasoningTokenCount: 0))
    public private(set) var lastError: (any Error)?
    public private(set) var isRunning = false
    public let prompter: UIPermissionPrompter
    public var activityLimit = 200
    /// Called on the main actor for every event, after it is recorded on
    /// `activity`, so a wrapper can mirror the session without polling it.
    public var eventHandler: (@MainActor (HarnessEvent) -> Void)?

    /// Metadata key on prompts that a scheduled job sent, holding the job ID. Views hide these.
    public static let jobPromptMetadataKey = "harness.job"

    private let runner: AgentRunner
    private let jobSink: JobResultSink
    private var log: SessionLog?
    private var current: Task<Void, Never>?

    /// Builds the configuration's prompter into the session: if the configuration
    /// has none, a `UIPermissionPrompter` is created and used. The response tool
    /// for scheduled runs is added so the heartbeat can run in this session.
    public init(configuration: AgentConfiguration) {
        var configuration = configuration
        let prompter = (configuration.prompter as? UIPermissionPrompter) ?? UIPermissionPrompter()
        configuration.prompter = prompter
        self.prompter = prompter
        let sink = JobResultSink()
        self.jobSink = sink
        configuration.toolsets.append(ToolList([JobResponseTool(sink: sink)]))
        self.runner = AgentRunner(configuration: configuration)
    }

    /// Starts the session, resuming from a transcript when one is given.
    public func start(resuming transcript: Transcript? = nil) async throws {
        let assembly = try await runner.makeSession(history: transcript, observer: self)
        session = assembly.session
        directory = assembly.directory
        log = assembly.log
        usage = assembly.session.usage
    }

    /// Sends a prompt and streams the reply. Returns when the turn ends.
    public func send(_ prompt: String) async {
        await send(Prompt(prompt))
    }

    /// Sends a built prompt, which may carry attachments beside its text,
    /// and streams the reply. Returns when the turn ends.
    public func send(_ prompt: Prompt) async {
        if session == nil {
            do { try await start() } catch { lastError = error; return }
        }
        guard let session, !isRunning else { return }
        isRunning = true
        lastError = nil
        streamingText = ""
        let task = Task {
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    streamingText = snapshot.content
                }
            } catch is CancellationError {
                // Cancelled by the person.
            } catch {
                lastError = error
            }
        }
        current = task
        await task.value
        current = nil
        usage = session.usage
        isRunning = false
    }

    /// Stops the current turn.
    public func cancel() {
        current?.cancel()
    }

    // MARK: Scheduled runs in this session

    /// A runner the scheduler can use so the heartbeat runs here, with the
    /// conversation as context, rather than in a fresh session.
    public nonisolated var jobRunner: any JobRunner {
        AgentSessionJobRunner(agent: self)
    }

    /// Runs a job's wake message as a turn in this session. Throws `JobRunnerSkip`
    /// when a turn is already running, so the scheduler records a skip and keeps
    /// the job's events for the next tick.
    public func runJob(_ wake: WakeMessage) async throws -> JobResult {
        if session == nil { try await start() }
        guard let session else { throw JobRunnerSkip(reason: "session unavailable") }
        guard !isRunning else { throw JobRunnerSkip(reason: "session busy") }
        isRunning = true
        defer { isRunning = false }
        let inputBefore = session.usage.input.totalTokenCount
        let outputBefore = session.usage.output.totalTokenCount
        let response = try await session.respond(
            to: Prompt(wake.rendered()),
            metadata: [Self.jobPromptMetadataKey: wake.job.id]
        )
        usage = session.usage
        return await JobResult.interpret(
            response.content,
            sink: jobSink,
            inputTokens: session.usage.input.totalTokenCount - inputBefore,
            outputTokens: session.usage.output.totalTokenCount - outputBefore
        )
    }

    /// Closes the log. Call when the session is finished for good.
    public func close() async {
        await log?.close()
    }

    /// True for a prompt a scheduled job sent, so a view can hide it.
    public static func isJobPrompt(_ entry: Transcript.Entry) -> Bool {
        guard case .prompt(let prompt) = entry else { return false }
        return prompt.metadata[jobPromptMetadataKey] != nil
    }

    // MARK: AgentObserver

    public nonisolated func text(_ delta: String) async {
        // Streaming text is read from snapshots in send(); deltas are not needed here.
    }

    public nonisolated func event(_ event: HarnessEvent) async {
        await record(event)
    }

    private func record(_ event: HarnessEvent) {
        activity.append(event)
        if activity.count > activityLimit { activity.removeFirst(activity.count - activityLimit) }
        eventHandler?(event)
    }
}

struct AgentSessionJobRunner: JobRunner {
    let agent: AgentSession

    func run(_ wake: WakeMessage) async throws -> JobResult {
        try await agent.runJob(wake)
    }
}
