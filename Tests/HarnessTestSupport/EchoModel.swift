import Foundation
import FoundationModels

/// A test model whose executor answers with a transform of the last prompt and
/// calls a tool when the prompt asks for one. No network, deterministic.
public struct EchoModel: LanguageModel {
    public typealias Executor = EchoExecutor
    public struct Configuration: Hashable, Sendable {
        public var id = "echo"
        public init() {}
    }

    public init() {}

    public var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling, .vision]) }
    public var executorConfiguration: Configuration { Configuration() }
}

public struct EchoExecutor: LanguageModelExecutor {
    public typealias Configuration = EchoModel.Configuration
    public typealias Model = EchoModel

    public init(configuration: Configuration) throws {}

    public func prewarm(model: EchoModel, transcript: Transcript) {}

    public func respond(to request: LanguageModelExecutorGenerationRequest, model: EchoModel, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
        var lastPrompt = ""
        var lastToolOutput: String?
        for entry in request.transcript {
            switch entry {
            case .prompt(let prompt): lastPrompt = prompt.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
            case .toolOutput(let output): lastToolOutput = output.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
            default: break
            }
        }
        // "explode" fails the request the way a provider outage would.
        if lastToolOutput == nil, lastPrompt == "explode" { throw EchoFailure() }
        // "call <tool> <json>" asks for one tool call, then the next turn echoes the tool's output.
        if lastToolOutput == nil, lastPrompt.hasPrefix("call "), request.enabledToolDefinitions.contains(where: { lastPrompt.hasPrefix("call \($0.name) ") }) {
            let rest = lastPrompt.dropFirst(5)
            let toolName = String(rest.prefix { $0 != " " })
            let json = String(rest.dropFirst(toolName.count + 1))
            await channel.send(.toolCalls(entryID: "tc-\(request.id.uuidString)", action: .toolCall(id: "call-\(request.id.uuidString)", name: toolName, action: .appendArguments(json, tokenCount: 0))))
            await channel.send(.toolCalls(entryID: "tc-\(request.id.uuidString)", action: .updateUsage(input: .init(totalTokenCount: 10, cachedTokenCount: 0), output: .init(totalTokenCount: 5, reasoningTokenCount: 0))))
            return
        }
        let text = lastToolOutput.map { "tool said: \($0)" } ?? "echo: \(lastPrompt)"
        let entryID = "msg-\(request.id.uuidString)"
        await channel.send(.response(entryID: entryID, action: .appendText(text, tokenCount: 0)))
        await channel.send(.response(entryID: entryID, action: .updateUsage(input: .init(totalTokenCount: 10, cachedTokenCount: 0), output: .init(totalTokenCount: 5, reasoningTokenCount: 0))))
    }
}

public struct EchoFailure: Error, LocalizedError {
    public var errorDescription: String? { "provider exploded" }
}
