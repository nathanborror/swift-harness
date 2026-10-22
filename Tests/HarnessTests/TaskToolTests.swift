import Foundation
import FoundationModels
import Testing
@testable import Harness
import HarnessTestSupport

@Suite struct TaskToolTests {
    @Test func echoModelDrivesASession() async throws {
        let session = LanguageModelSession(model: EchoModel(), tools: [EchoTool()], instructions: "test")
        let plain = try await session.respond(to: "hello")
        #expect(plain.content == "echo: hello")
        let viaTool = try await session.respond(to: #"call echo {"text":"ping"}"#)
        #expect(viaTool.content == "tool said: ping")
        #expect(session.usage.input.totalTokenCount == 30)
    }

    @Test func delegatesToANamedAgentAndLogs() async throws {
        let log = try SessionLog(url: FileManager.default.temporaryDirectory.appending(path: "harness-task-\(UUID().uuidString)/events.jsonl"))
        let explorer = SubagentDefinition(name: "explorer", description: "Looks things up", model: EchoModel(), instructions: "Explore.", tools: [EchoTool()])
        let tool = TaskTool(agents: [explorer], log: log)
        #expect(tool.description.contains("- explorer: Looks things up"))

        let result = try await tool.call(arguments: .init(agent: "explorer", prompt: "find it", description: "lookup"))
        #expect(result == "echo: find it")
        let unknown = try await tool.call(arguments: .init(agent: "nope", prompt: "x", description: nil))
        #expect(unknown.contains("Available: explorer"))

        await log.close()
        let records = try SessionLog.read(url: log.url)
        guard case .subagent(let name, let description, let characters, let input, let output, _, let failed)? = records.first?.event else {
            Issue.record("expected a subagent record")
            return
        }
        #expect(name == "explorer" && description == "lookup" && characters == result.count && input == 10 && output == 5 && !failed)
    }

    @Test func stopsASubagentAtItsToolCallLimit() async throws {
        let agent = SubagentDefinition(name: "worker", description: "Works", model: EchoModel(), instructions: "Work.", tools: [EchoTool()], maximumToolCalls: 0)
        let tool = TaskTool(agents: [agent])
        await #expect(throws: SubagentError.toolCallLimit(0)) {
            _ = try await tool.call(arguments: .init(agent: "worker", prompt: #"call echo {"text":"x"}"#, description: nil))
        }
        let gated = ToolGate(policy: .allowAll).gate(tool)
        let shaped = try await gated.call(arguments: TaskTool.Arguments(agent: "worker", prompt: #"call echo {"text":"x"}"#, description: nil).generatedContent)
        #expect(shaped.hasPrefix("Error: task failed: The sub-agent reached its limit of 0 tool calls"))
    }

    @Test func parentSessionCanDelegateThroughTheTool() async throws {
        let agent = SubagentDefinition(name: "explorer", description: "Looks things up", model: EchoModel(), instructions: "Explore.", tools: [])
        let parent = LanguageModelSession(model: EchoModel(), tools: [TaskTool(agents: [agent])], instructions: "parent")
        let response = try await parent.respond(to: #"call task {"agent":"explorer","prompt":"what is up"}"#)
        #expect(response.content == "tool said: echo: what is up")
    }
}
