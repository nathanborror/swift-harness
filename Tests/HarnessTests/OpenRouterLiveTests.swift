import Foundation
import FoundationModels
import Testing
@testable import Harness

/// Live tests against OpenRouter. They run only when `OPENROUTER_API_KEY` is set
/// and each one costs a fraction of a cent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
struct OpenRouterLiveTests {
    private var model: OpenRouterLanguageModel {
        OpenRouterLanguageModel(modelID: "anthropic/claude-haiku-4.5", defaultReasoningEffort: "low", sessionID: "harness-live-tests")
    }

    @Test func runsAToolCallRoundTrip() async throws {
        let session = LanguageModelSession(model: model, tools: [WeatherTool()], instructions: "Be terse. Use get_weather for weather questions.")
        let response = try await session.respond(to: "What is the weather in Oslo?")
        #expect(response.content.lowercased().contains("rain") || response.content.contains("4"))

        let kinds = session.transcript.map { entry -> String in
            switch entry {
            case .instructions: "instructions"
            case .prompt: "prompt"
            case .response: "response"
            case .reasoning: "reasoning"
            case .toolCalls: "toolCalls"
            case .toolOutput: "toolOutput"
            @unknown default: "other"
            }
        }
        #expect(kinds.contains("toolCalls"))
        #expect(kinds.contains("toolOutput"))
        #expect(kinds.last == "response")
        #expect(session.usage.input.totalTokenCount > 0)
        #expect(session.usage.output.totalTokenCount > 0)

        for case .toolOutput(let output) in session.transcript {
            let calls = session.transcript.compactMap { entry -> Transcript.ToolCalls? in
                if case .toolCalls(let calls) = entry { return calls }
                return nil
            }
            #expect(calls.flatMap { $0 }.contains { $0.id == output.id }, "tool output id should match a tool call id")
        }
    }

    @Test func streamsTextAndReportsUsage() async throws {
        let session = LanguageModelSession(model: model, instructions: "Answer in one short sentence.")
        var snapshots = 0
        let stream = session.streamResponse(to: "Name one color.")
        for try await _ in stream { snapshots += 1 }
        #expect(snapshots >= 1)
        let last = session.transcript.last
        guard case .response(let response)? = last else {
            Issue.record("expected a response entry, got \(String(describing: last))")
            return
        }
        #expect(!response.segments.isEmpty)
        #expect(response.metadata[OpenRouterMetadataKey.responseID] != nil)
        #expect(session.usage.input.totalTokenCount > 0)
    }

    @Generable
    struct Trip {
        @Guide(description: "Destination city")
        var destination: String
        @Guide(description: "Length in days")
        var days: Int
    }

    @Test func guidedGenerationReturnsTypedContent() async throws {
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: "Plan a 3 day trip to Tokyo.", generating: Trip.self)
        #expect(response.content.destination.lowercased().contains("tokyo"))
        #expect(response.content.days == 3)
    }

    @Test func continuesAConversationAcrossTurns() async throws {
        let session = LanguageModelSession(model: model, instructions: "Be terse.")
        _ = try await session.respond(to: "My favorite number is 42. Just say OK.")
        let second = try await session.respond(to: "What is my favorite number? Reply with digits only.")
        #expect(second.content.contains("42"))
    }
}
