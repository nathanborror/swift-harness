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

    private let runner: AgentRunner
    private var log: SessionLog?
    private var current: Task<Void, Never>?

    /// Builds the configuration's prompter into the session: if the configuration
    /// has none, a `UIPermissionPrompter` is created and used.
    public init(configuration: AgentConfiguration) {
        var configuration = configuration
        let prompter = (configuration.prompter as? UIPermissionPrompter) ?? UIPermissionPrompter()
        configuration.prompter = prompter
        self.prompter = prompter
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

    /// Closes the log. Call when the session is finished for good.
    public func close() async {
        await log?.close()
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
    }
}
