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

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
struct HarnessLiveTests {
    struct NeverPrompter: PermissionPrompter {
        func confirm(_ invocation: ToolInvocation) async -> PermissionResponse { .deny }
    }

    struct Profile: LanguageModelSession.DynamicProfile {
        let model: OpenRouterLanguageModel
        let tools: [any Tool]
        let directory: SessionDirectory
        let log: SessionLog

        var body: some LanguageModelSession.DynamicProfile {
            Profile {
                Instructions("Be terse. Use get_weather for weather questions. Use delete_file when asked to delete.")
                tools
            }
            .model(model)
            .logging(to: log)
            .persistingTranscript(in: directory, log: log)
        }
    }

    struct DeleteFileTool: AnnotatedTool {
        @Generable struct Arguments { var path: String }
        let name = "delete_file"
        let description = "Deletes a file at a path"
        var annotations: ToolAnnotations = .destructive
        func call(arguments: Arguments) async throws -> String { "deleted \(arguments.path)" }
    }

    @Test func gatedToolsLogAndPersistThroughAProfile() async throws {
        let directory = try SessionDirectory(root: FileManager.default.temporaryDirectory.appending(path: "harness-live-\(UUID().uuidString)"))
        let log = try directory.makeLog()
        let policy = PermissionPolicy(rules: [.tool("get_weather", .allow), .destructive(.ask)], fallback: .ask)
        let gate = ToolGate(policy: policy, prompter: NeverPrompter(), shaper: ToolResultShaper(outputsDirectory: directory.outputsURL), log: log)
        let model = OpenRouterLanguageModel(modelID: "anthropic/claude-haiku-4.5", defaultReasoningEffort: "low", sessionID: directory.sessionID)
        let session = LanguageModelSession(profile: Profile(
            model: model,
            tools: [gate.gate(WeatherTool()), gate.gate(DeleteFileTool())],
            directory: directory,
            log: log
        ))

        let weather = try await session.respond(to: "What is the weather in Oslo?")
        #expect(weather.content.contains("4") || weather.content.lowercased().contains("rain"))

        let deletion = try await session.respond(to: "Delete the file notes.txt, then tell me in one sentence whether it worked.")
        #expect(!deletion.content.isEmpty)

        await log.close()
        let records = try SessionLog.read(url: directory.logURL)
        var decisions: [PermissionDecision] = []
        var sawPrompt = false
        var sawToolOutput = false
        for record in records {
            switch record.event {
            case .permission(_, let decision, _, _, _): decisions.append(decision)
            case .prompt: sawPrompt = true
            case .toolOutput: sawToolOutput = true
            default: break
            }
        }
        #expect(decisions.contains(.allow), "weather tool should be allowed")
        #expect(decisions.contains(.deny), "delete tool should be denied without consent")
        #expect(sawPrompt && sawToolOutput)

        let saved = try #require(try directory.loadTranscript())
        #expect(saved.count == session.transcript.history.count)
        #expect(saved.contains { if case .toolOutput = $0 { return true } else { return false } })
    }
}
