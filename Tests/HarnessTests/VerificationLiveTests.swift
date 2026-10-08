import Foundation
import FoundationModels
import Testing
@testable import Harness

/// Experiments the README's verification notes rest on. They spend a little
/// money and print what they find, so the notes can be re-checked later.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil), .serialized)
struct VerificationLiveTests {
    private func cachedTokens(in session: LanguageModelSession) -> [(cached: Int, written: Int)] {
        session.transcript.compactMap { entry -> (Int, Int)? in
            guard case .response(let response) = entry else { return nil }
            let written = response.metadata[OpenRouterMetadataKey.cacheWriteTokens].flatMap { try? $0.value(Int.self) } ?? 0
            return (0, written)
        }
    }

    @Test func promptCacheHitsAcrossTurnsOfOneSession() async throws {
        // A stable prefix over Anthropic's minimum cacheable size for this model.
        let filler = (1...450).map { "Rule \($0): keep answers short and factual." }.joined(separator: " ")
        let model = OpenRouterLanguageModel(modelID: "anthropic/claude-haiku-4.5", defaultReasoningEffort: "low", sessionID: "harness-cache-check-\(UUID().uuidString)")
        let session = LanguageModelSession(model: model, instructions: "You are terse. " + filler)
        var perTurn: [(input: Int, cached: Int)] = []
        var previous = (0, 0)
        for turn in 1...3 {
            _ = try await session.respond(to: "Turn \(turn). Reply with the word ok.")
            let usage = session.usage
            perTurn.append((usage.input.totalTokenCount - previous.0, usage.input.cachedTokenCount - previous.1))
            previous = (usage.input.totalTokenCount, usage.input.cachedTokenCount)
        }
        print("VERIFY cache per turn (input, cached):", perTurn)
        #expect(perTurn[0].input > 4_000, "the prefix must exceed the minimum cacheable size")
        #expect(perTurn[1].cached > 0 || perTurn[2].cached > 0, "later turns should read from the cache")
    }

    @Test func maskedToolOutputsAreAcceptedByTheNewestClaudeModels() async throws {
        for modelID in ["anthropic/claude-haiku-5.5", "anthropic/claude-sonnet-4.6"] {
            let model = OpenRouterLanguageModel(modelID: modelID, defaultReasoningEffort: "low")
            let session = LanguageModelSession(model: model, tools: [WeatherTool()], instructions: "Be terse. Use get_weather for weather questions.")
            _ = try await session.respond(to: "Weather in Oslo? Think briefly first.")
            _ = try await session.respond(to: "And in Bergen?")
            // Mask the first tool output the way ContextManagement does, then continue.
            var entries = Array(session.transcript.history)
            var masked = false
            for index in entries.indices {
                if case .toolOutput(let output) = entries[index], !masked {
                    entries[index] = .toolOutput(Transcript.ToolOutput(id: output.id, toolName: output.toolName, segments: [.text(.init(content: "[Output of get_weather elided to save context.]"))]))
                    masked = true
                }
            }
            #expect(masked, "\(modelID): a tool output should exist to mask")
            let resumed = LanguageModelSession(model: model, tools: [WeatherTool()], transcript: Transcript(entries: Array(session.transcript.prefix(1)) + entries))
            do {
                let reply = try await resumed.respond(to: "Which of the two cities did you check first? One word.")
                print("VERIFY masking on \(modelID): accepted, reply:", reply.content.prefix(60))
            } catch {
                print("VERIFY masking on \(modelID): REJECTED:", error.localizedDescription)
                Issue.record("\(modelID) rejected a history with a masked tool output: \(error.localizedDescription)")
            }
        }
    }
}
