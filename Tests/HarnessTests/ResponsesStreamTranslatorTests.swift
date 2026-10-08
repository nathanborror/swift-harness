import Foundation
import Testing
@testable import Harness

@Suite struct ResponsesStreamTranslatorTests {
    private func translate(_ fixture: String) throws -> [ResponsesStreamTranslator.Event] {
        var translator = ResponsesStreamTranslator(generationID: "gen-test")
        var parser = ServerSentEventParser()
        var events: [ResponsesStreamTranslator.Event] = []
        for line in try Fixtures.sse(fixture) {
            guard let sse = parser.feed(line) else { continue }
            if sse.data == "[DONE]" { break }
            events += try translator.handle(data: sse.data)
        }
        try translator.finish()
        return events
    }

    @Test func toolCallStreamProducesArgumentsThenUsage() throws {
        let events = try translate("stream-tool-call")
        var arguments = ""
        var callID: String?
        for case .appendArguments(_, let id, let name, let delta) in events {
            callID = id
            #expect(name == "get_weather")
            arguments += delta
        }
        #expect(arguments == "{\"city\": \"Oslo\"}")
        #expect(callID?.hasPrefix("toolu_") == true)
        guard case .usage(let target, let usage, let metadata)? = events.last else {
            Issue.record("last event should be usage, got \(String(describing: events.last))")
            return
        }
        if case .toolCalls = target {} else { Issue.record("usage should attach to the tool calls entry") }
        #expect(usage.inputTokens > 0)
        #expect(metadata[OpenRouterMetadataKey.generationID] == .string("gen-test"))
        #expect(metadata[OpenRouterMetadataKey.responseID]?.stringValue?.hasPrefix("gen-") == true)
        let stored = events.compactMap { event -> [String: JSONValue]? in
            if case .toolCallMetadata(_, _, _, let values) = event { return values }
            return nil
        }
        #expect(stored.count == 1)
        #expect(stored.first?[OpenRouterMetadataKey.itemID]?.stringValue?.hasPrefix("fc_") == true)
    }

    @Test func textStreamProducesDeltasInOrder() throws {
        let events = try translate("stream-text")
        var text = ""
        var entryIDs = Set<String>()
        for case .appendText(.response(let entryID), let delta) in events {
            entryIDs.insert(entryID)
            text += delta
        }
        #expect(text.hasPrefix("Oslo is currently"))
        #expect(entryIDs.count == 1)
        guard case .usage(.response, _, _)? = events.last else {
            Issue.record("usage should attach to the response entry")
            return
        }
    }

    @Test func reasoningStreamCarriesSignatureAndRawItem() throws {
        let events = try translate("stream-reasoning")
        var reasoning = ""
        var signature: Data?
        var rawItem: String?
        var sawText = false
        var sawArguments = false
        for event in events {
            switch event {
            case .appendText(.reasoning, let delta): reasoning += delta
            case .appendText(.response, _): sawText = true
            case .reasoningSignature(_, let data): signature = data
            case .metadata(.reasoning, let values): rawItem = values[OpenRouterMetadataKey.item]?.stringValue
            case .appendArguments: sawArguments = true
            default: break
            }
        }
        #expect(!reasoning.isEmpty)
        #expect(sawText)
        #expect(sawArguments)
        #expect(signature != nil)
        let item = try JSONValue(jsonString: try #require(rawItem))
        #expect(item["type"]?.stringValue == "reasoning")
        #expect(item["format"]?.stringValue == "anthropic-claude-v1")
    }

    @Test func failedResponseThrows() throws {
        var translator = ResponsesStreamTranslator(generationID: nil)
        #expect(throws: OpenRouterError.self) {
            _ = try translator.handle(data: #"{"type":"response.failed","response":{"error":{"message":"boom"}}}"#)
        }
    }

    @Test func committedErrorChunkThrows() throws {
        var translator = ResponsesStreamTranslator(generationID: nil)
        #expect(throws: OpenRouterError.self) {
            _ = try translator.handle(data: #"{"error":{"code":502,"message":"upstream"}}"#)
        }
    }
}
