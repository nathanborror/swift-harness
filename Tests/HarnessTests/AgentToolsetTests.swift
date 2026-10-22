import Foundation
import FoundationModels
import Testing
@testable import Harness

/// A toolset with no workspace: one gated tool, instructions, and a manifest fact.
struct GreetingToolset: AgentToolset {
    func tools(in context: AgentToolsetContext) -> [any Tool] {
        [context.gate.gate(EchoTool())]
    }

    var instructions: String? { "Greet people warmly." }
    var manifestMetadata: [String: String] { ["calendar": "work"] }
}

@Suite struct AgentToolsetTests {
    private func makeConfiguration(toolsets: [any AgentToolset]) -> AgentConfiguration {
        let base = FileManager.default.temporaryDirectory.appending(path: "harness-toolset-\(UUID().uuidString)")
        return AgentConfiguration(model: EchoModel(), instructions: "You help with greetings.", toolsets: toolsets, sessionRoot: base.appending(path: "sessions"))
    }

    @Test func runsWithoutAWorkspace() async throws {
        let result = try await AgentRunner(configuration: makeConfiguration(toolsets: [GreetingToolset()])).run(prompt: #"call echo {"text":"hi"}"#)
        #expect(result.toolCalls == ["echo"])
        #expect(result.response == "tool said: hi")
        let instructions = result.transcript.compactMap { entry -> Transcript.Instructions? in
            if case .instructions(let instructions) = entry { return instructions }
            return nil
        }.first
        let text = TranscriptText.segments(try #require(instructions).segments)
        #expect(text.contains("You help with greetings."))
        #expect(text.contains("Greet people warmly."))
        #expect(instructions?.toolDefinitions.map(\.name) == ["echo"])
        #expect(result.directory.loadManifest()?.metadata == ["calendar": "work"])
    }

    @Test func toolListPassesToolsThroughUngated() async throws {
        var configuration = makeConfiguration(toolsets: [ToolList([DeleteTool()])])
        configuration.policy = .readOnlyOnly
        let result = try await AgentRunner(configuration: configuration).run(prompt: #"call delete {"text":"x"}"#)
        #expect(result.response == "tool said: deleted x", "the policy would deny a gated destructive tool")
    }

    @Test func manifestReadsTheLegacyWorkspacePath() throws {
        let json = #"{"createdAt":"2026-10-08T12:00:00Z","modelID":"m","workspacePath":"/tmp/ws"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SessionDirectory.Manifest.self, from: Data(json.utf8))
        #expect(manifest.metadata == ["workspace": "/tmp/ws"])
        #expect(manifest.modelID == "m")
    }
}
