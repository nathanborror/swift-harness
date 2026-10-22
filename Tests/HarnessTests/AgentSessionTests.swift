import Foundation
import FoundationModels
import CoreGraphics
import Testing
@testable import Harness

@Suite struct UIPermissionPrompterTests {
    @Test @MainActor func respondResolvesThePendingRequest() async throws {
        let prompter = UIPermissionPrompter(timeout: .seconds(30))
        let invocation = ToolInvocation(toolName: "delete", arguments: try GeneratedContent(json: "{}"), annotations: .destructive)
        let task = Task { await prompter.confirm(invocation) }
        while prompter.pending == nil { await Task.yield() }
        #expect(prompter.pending?.invocation.toolName == "delete")
        prompter.respond(.allowOnce)
        #expect(await task.value == .allowOnce)
        #expect(prompter.pending == nil)
    }

    @Test @MainActor func unansweredRequestsAreDeniedAfterTheTimeout() async throws {
        let prompter = UIPermissionPrompter(timeout: .milliseconds(100))
        let invocation = ToolInvocation(toolName: "delete", arguments: try GeneratedContent(json: "{}"), annotations: nil)
        let response = await prompter.confirm(invocation)
        #expect(response == .deny)
        #expect(prompter.pending == nil)
    }

    @Test @MainActor func asksAreServedOneAtATime() async throws {
        let prompter = UIPermissionPrompter(timeout: .seconds(30))
        let invocation = ToolInvocation(toolName: "x", arguments: try GeneratedContent(json: "{}"), annotations: nil)
        let first = Task { await prompter.confirm(invocation) }
        let second = Task { await prompter.confirm(invocation) }
        while prompter.pending == nil || prompter.queued == 0 { await Task.yield() }
        prompter.respond(.deny)
        while prompter.pending == nil { await Task.yield() }
        prompter.respond(.allowAlways)
        let responses = [await first.value, await second.value]
        #expect(responses.sorted { "\($0)" < "\($1)" } == [.allowAlways, .deny])
    }
}

@Suite struct AgentSessionTests {
    private func makeConfiguration() throws -> AgentConfiguration {
        let base = FileManager.default.temporaryDirectory.appending(path: "harness-agentsession-\(UUID().uuidString)")
        let workspace = try Workspace(root: base.appending(path: "ws"))
        return AgentConfiguration.coding(model: EchoModel(), workspace: workspace, sessionRoot: base.appending(path: "sessions"), policy: .allowAll, includesExplorer: false)
    }

    private static func kind(of event: HarnessEvent) -> String {
        switch event {
        case .sessionStarted: "started"
        case .prompt: "prompt"
        case .response: "response"
        case .toolCall: "toolCall"
        case .toolOutput: "toolOutput"
        default: "other"
        }
    }

    @Test @MainActor func runsTurnsAndObservesActivity() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        await agent.send("hello")
        #expect(agent.streamingText == "echo: hello")
        #expect(agent.lastError == nil && !agent.isRunning)
        #expect(agent.usage.input.totalTokenCount == 10)
        await agent.send(#"call write {"path":"a.txt","content":"x"}"#)
        #expect(agent.streamingText.hasPrefix("tool said: Wrote a.txt"))
        let session = try #require(agent.session)
        #expect(session.transcript.history.count == 6, "prompt, response, prompt, toolCalls, toolOutput, response")
        var handled: [String] = []
        agent.eventHandler = { event in handled.append(Self.kind(of: event)) }
        let kinds = agent.activity.map(Self.kind(of:))
        #expect(kinds == ["started", "prompt", "response", "prompt", "toolCall", "toolOutput", "response"])
        await agent.send("again")
        #expect(handled == ["prompt", "response"], "the handler sees every event as it is recorded")
        await agent.close()
    }

    @Test @MainActor func aBuiltPromptKeepsItsAttachmentAndLabel() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        var recorded: [HarnessEvent] = []
        agent.eventHandler = { recorded.append($0) }
        await agent.send(Prompt {
            "what is this"
            Attachment(image).label("photo.png")
        })
        #expect(agent.streamingText == "echo: what is this", "\(String(describing: agent.lastError))")
        let session = try #require(agent.session)
        guard case .prompt(let prompt)? = session.transcript.history.first else { Issue.record("no prompt entry"); return }
        let attachments = prompt.segments.compactMap { segment -> Transcript.AttachmentSegment? in
            if case .attachment(let attachment) = segment { return attachment }
            return nil
        }
        #expect(attachments.count == 1)
        #expect(attachments.first?.label == "photo.png")
        if case .image(let stored)? = attachments.first?.content { #expect(stored.cgImage.width == 8) }
        guard case .prompt(let event)? = recorded.first(where: { if case .prompt = $0 { true } else { false } }),
              case .prompt(let observed)? = event.first else { Issue.record("no prompt event"); return }
        #expect(observed.segments.count == 2, "the observer sees the attachment too")
    }

    @Test @MainActor func resumesFromASavedTranscript() async throws {
        let configuration = try makeConfiguration()
        let first = AgentSession(configuration: configuration)
        await first.send("remember this")
        let saved = try #require(try first.directory?.loadTranscript())
        await first.close()

        let second = AgentSession(configuration: configuration)
        try await second.start(resuming: saved)
        let session = try #require(second.session)
        #expect(session.transcript.history.count == 2)
        await second.send("again")
        #expect(session.transcript.history.count == 4)
        #expect(second.streamingText == "echo: again")
    }

    @Test @MainActor func aFailedTurnKeepsItsPromptAndTheNextTurnStillWorks() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        await agent.send("explode")
        #expect(agent.lastError != nil)
        let session = try #require(agent.session)
        #expect(session.transcript.history.count == 1, "the prompt stays; the turn is not reverted")
        await agent.send("hello")
        #expect(agent.lastError == nil)
        #expect(agent.streamingText == "echo: hello")
        #expect(session.transcript.history.count == 3)
    }

    @Test @MainActor func cancelStopsATurn() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        try await agent.start()
        let turn = Task { await agent.send("slow") }
        agent.cancel()
        await turn.value
        #expect(!agent.isRunning)
    }
}

@Suite struct AgentSessionHeartbeatTests {
    private func makeConfiguration() throws -> AgentConfiguration {
        let base = FileManager.default.temporaryDirectory.appending(path: "harness-heartbeat-\(UUID().uuidString)")
        let workspace = try Workspace(root: base.appending(path: "ws"))
        return AgentConfiguration.coding(model: EchoModel(), workspace: workspace, sessionRoot: base.appending(path: "sessions"), policy: .allowAll, includesExplorer: false)
    }

    @Test @MainActor func heartbeatRunsInTheMainSessionAndTagsItsPrompt() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        await agent.send("hello")
        let job = Job.heartbeat(every: 600, scratch: "- watch the build")
        let wake = WakeMessage(job: job, scheduledAt: nil, now: Date())
        let result = try await agent.runJob(wake)
        #expect(result.outcome == .progress, "the echo model repeats the wake, which is not the sentinel")
        #expect(result.inputTokens == 10 && result.outputTokens == 5, "usage is per run, not cumulative")
        let session = try #require(agent.session)
        let prompts = session.transcript.compactMap { entry -> Transcript.Prompt? in
            if case .prompt(let prompt) = entry { return prompt }
            return nil
        }
        #expect(prompts.count == 2)
        #expect(prompts.last?.metadata[AgentSession.jobPromptMetadataKey].flatMap { try? $0.value(String.self) } == "heartbeat")
        #expect(session.transcript.filter(AgentSession.isJobPrompt).count == 1)
        #expect(agent.streamingText == "echo: hello", "a job turn does not touch the streamed reply")
    }

    @Test @MainActor func responseToolIsAvailableAndSinkInterpretsOutcomes() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        try await agent.start()
        let session = try #require(agent.session)
        let definitions = session.transcript.compactMap { entry -> [String]? in
            if case .instructions(let instructions) = entry { return instructions.toolDefinitions.map(\.name) }
            return nil
        }.flatMap { $0 }
        #expect(definitions.contains("job_respond"), "the main session carries the response tool")

        let sink = JobResultSink()
        await sink.store(JobResult(outcome: .needsAttention, summary: "disk is full", notification: "Disk full", nextCheckSeconds: 120))
        let viaTool = await JobResult.interpret("anything", sink: sink, inputTokens: 3, outputTokens: 4)
        #expect(viaTool.outcome == .needsAttention && viaTool.notification == "Disk full" && viaTool.inputTokens == 3)
        #expect(await JobResult.interpret("NO_REPLY", sink: sink, inputTokens: 1, outputTokens: 1).outcome == .noChange, "the sink is cleared after take")
        let failed = await JobResult.interpret("AUTOMATION_FAILED\nthe build is red", sink: sink, inputTokens: 0, outputTokens: 0)
        #expect(failed.outcome == .failed && failed.summary == "the build is red")
    }

    @Test @MainActor func busySessionSkipsTheTickAndKeepsItsEvents() async throws {
        var configuration = try makeConfiguration()
        configuration.policy = .default
        let agent = AgentSession(configuration: configuration)
        try await agent.start()
        // A write asks under the default policy, so the turn parks on the prompter and the session stays busy.
        let turn = Task { await agent.send(#"call write {"path":"a.txt","content":"x"}"#) }
        while agent.prompter.pending == nil { await Task.yield() }
        #expect(agent.isRunning)

        let store = try JobStore(root: FileManager.default.temporaryDirectory.appending(path: "harness-jobs-\(UUID().uuidString)"))
        let scheduler = Scheduler(store: store, runner: agent.jobRunner, delivery: InboxDelivery(store: store))
        try await scheduler.add(Job.heartbeat(every: 600))
        let skipped = await scheduler.enqueue(event: "bg_1 exited")
        #expect(skipped?.status == .skipped && skipped?.skipReason == "session busy")

        agent.prompter.respond(.deny)
        await turn.value
        #expect(!agent.isRunning)
        let run = try #require(await scheduler.runNow("heartbeat"))
        #expect(run.status == .ok)
        let wakePrompt = try #require(agent.session?.transcript.last { AgentSession.isJobPrompt($0) })
        if case .prompt(let prompt) = wakePrompt {
            #expect(TranscriptText.segments(prompt.segments).contains("bg_1 exited"), "the event held during the skip reached the next run")
        }
    }
}
