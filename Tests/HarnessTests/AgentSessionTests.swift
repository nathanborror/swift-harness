import Foundation
import FoundationModels
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
        return AgentConfiguration(model: EchoModel(), workspace: workspace, sessionRoot: base.appending(path: "sessions"), policy: .allowAll, includesExplorer: false)
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
        let kinds = agent.activity.map { event -> String in
            switch event {
            case .sessionStarted: "started"
            case .toolCall: "toolCall"
            case .toolOutput: "toolOutput"
            default: "other"
            }
        }
        #expect(kinds == ["started", "toolCall", "toolOutput"])
        await agent.close()
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

    @Test @MainActor func cancelStopsATurn() async throws {
        let agent = AgentSession(configuration: try makeConfiguration())
        try await agent.start()
        let turn = Task { await agent.send("slow") }
        agent.cancel()
        await turn.value
        #expect(!agent.isRunning)
    }
}
