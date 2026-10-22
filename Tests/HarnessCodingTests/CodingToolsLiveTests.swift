import Foundation
import FoundationModels
import Testing
import Harness
import HarnessCoding

/// Live tests against OpenRouter. They run only when `OPENROUTER_API_KEY` is set.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
struct CodingToolsLiveTests {
    @Test func modelReadsAndEditsAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "harness-coding-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "greeting.txt")
        try "Hello, world!\nSecond line stays.\n".write(to: file, atomically: true, encoding: .utf8)

        let tools = CodingTools(workspace: try Workspace(root: root))
        let gate = ToolGate(policy: .allowAll)
        let model = OpenRouterLanguageModel(modelID: "anthropic/claude-haiku-4.5", defaultReasoningEffort: "low")
        let session = LanguageModelSession(
            model: model,
            tools: tools.gated(by: gate),
            instructions: "You are a coding agent working in a workspace. Use the tools. Read a file before editing it. Keep replies to one sentence."
        )
        let response = try await session.respond(to: "In greeting.txt, change the word 'world' to 'Nathan'. Leave everything else alone.")
        #expect(!response.content.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "Hello, Nathan!\nSecond line stays.\n")
        let toolNames = session.transcript.flatMap { entry -> [String] in
            if case .toolCalls(let calls) = entry { return calls.map(\.toolName) }
            return []
        }
        #expect(toolNames.contains("read"))
        #expect(toolNames.contains("edit"))
    }
}
