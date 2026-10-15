import Foundation
import FoundationModels
import CoreGraphics
import Testing
@testable import Harness

@Generable(description: "Weather lookup arguments")
struct WeatherArguments {
    @Guide(description: "City name")
    var city: String
    var units: String?
}

struct WeatherTool: Tool {
    let name = "get_weather"
    let description = "Get current weather for a city"
    func call(arguments: WeatherArguments) async throws -> String { "\(arguments.city): 4C, light rain." }
}

@Suite struct ResponsesRequestBuilderTests {
    private func makeRequest(transcript: Transcript, schema: GenerationSchema? = nil, context: ContextOptions = ContextOptions()) -> LanguageModelExecutorGenerationRequest {
        LanguageModelExecutorGenerationRequest(
            id: UUID(),
            transcript: transcript,
            enabledTools: [Transcript.ToolDefinition(tool: WeatherTool())],
            schema: schema,
            generationOptions: GenerationOptions(temperature: 0.2, maximumResponseTokens: 300),
            contextOptions: context,
            metadata: [:]
        )
    }

    @Test func mapsEveryEntryKindToAnItem() throws {
        let callArguments = try GeneratedContent(json: #"{"city":"Oslo"}"#)
        let transcript = Transcript(entries: [
            .instructions(.init(id: "i", segments: [.text(.init(content: "Be terse."))], toolDefinitions: [])),
            .prompt(.init(id: "p", segments: [.text(.init(content: "Weather in Oslo?"))])),
            .reasoning(.init(id: "rs_1", segments: [.text(.init(content: "Simple."))], signature: Data("sig".utf8))),
            .response(.init(id: "msg_1", segments: [.text(.init(content: "Checking."))])),
            .toolCalls(.init(id: "tc", [Transcript.ToolCall(id: "call_1", metadata: [OpenRouterMetadataKey.itemID: "fc_1"], toolName: "get_weather", arguments: callArguments)])),
            .toolOutput(.init(id: "call_1", toolName: "get_weather", segments: [.text(.init(content: "Oslo: 4C"))])),
        ])
        let model = OpenRouterLanguageModel(modelID: "test/model", defaultReasoningEffort: "low", sessionID: "s1")
        let body = try ResponsesRequestBuilder(model: model).body(for: makeRequest(transcript: transcript, context: ContextOptions(reasoningLevel: .deep)))

        #expect(body["model"]?.stringValue == "test/model")
        #expect(body["instructions"]?.stringValue == "Be terse.")
        #expect(body["stream"]?.boolValue == true)
        #expect(body["reasoning"]?["effort"]?.stringValue == "high")
        #expect(body["include"] == ["reasoning.encrypted_content"])
        #expect(body["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["session_id"]?.stringValue == "s1")
        #expect(body["temperature"]?.doubleValue == 0.2)
        #expect(body["max_output_tokens"]?.intValue == 300)

        let input = try #require(body["input"]?.arrayValue)
        #expect(input.map { $0["type"]?.stringValue ?? $0["role"]?.stringValue } == ["user", "reasoning", "message", "function_call", "function_call_output"])
        #expect(input[0]["content"]?[0]?["text"]?.stringValue == "Weather in Oslo?")
        #expect(input[1]["signature"]?.stringValue == "sig")
        #expect(input[1]["content"]?[0]?["text"]?.stringValue == "Simple.")
        #expect(input[2]["content"]?[0]?["type"]?.stringValue == "output_text")
        #expect(input[3]["call_id"]?.stringValue == "call_1")
        #expect(input[3]["id"]?.stringValue == "fc_1")
        #expect(input[3]["arguments"]?.stringValue?.contains("Oslo") == true)
        #expect(input[4]["call_id"]?.stringValue == "call_1")
        #expect(input[4]["output"]?.stringValue == "Oslo: 4C")

        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools.count == 1)
        #expect(tools[0]["name"]?.stringValue == "get_weather")
        #expect(tools[0]["parameters"]?["required"] == ["city"])
        #expect(tools[0]["parameters"]?["properties"]?["units"]?["type"]?.stringValue == "string")
        #expect(tools[0]["parameters"]?["x-order"] == nil, "Anthropic rejects x-order in schemas")
    }

    @Test func imagesGoAsJPEGUnlessTheyHaveAlpha() throws {
        func image(alpha: CGImageAlphaInfo) throws -> CGImage {
            let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue))
            return try #require(context.makeImage())
        }
        let opaque = try ResponsesRequestBuilder.imageDataURL(Transcript.ImageAttachment(try image(alpha: .noneSkipLast)))
        #expect(opaque.hasPrefix("data:image/jpeg;base64,"))
        let translucent = try ResponsesRequestBuilder.imageDataURL(Transcript.ImageAttachment(try image(alpha: .premultipliedLast)))
        #expect(translucent.hasPrefix("data:image/png;base64,"))
    }

    @Test func stripsVendorKeysRecursively() {
        let schema: JSONValue = ["type": "object", "x-order": ["a"], "properties": ["a": ["type": "object", "x-order": [], "properties": [:]]]]
        let cleaned = ResponsesRequestBuilder.strippingVendorKeys(schema)
        #expect(cleaned["x-order"] == nil)
        #expect(cleaned["properties"]?["a"]?["x-order"] == nil)
        #expect(cleaned["properties"]?["a"]?["type"]?.stringValue == "object")
    }

    @Test func replaysStoredReasoningItemVerbatim() throws {
        let raw = #"{"id":"rs_x","type":"reasoning","status":"completed","content":[],"summary":[],"encrypted_content":"opaque","format":"openai-responses-v1"}"#
        let transcript = Transcript(entries: [
            .prompt(.init(id: "p", segments: [.text(.init(content: "hi"))])),
            .reasoning(.init(id: "rs_x", metadata: [OpenRouterMetadataKey.item: raw], segments: [], signature: nil)),
        ])
        let body = try ResponsesRequestBuilder(model: OpenRouterLanguageModel(modelID: "m")).body(for: makeRequest(transcript: transcript))
        let item = try #require(body["input"]?[1])
        #expect(item["encrypted_content"]?.stringValue == "opaque")
        #expect(item["format"]?.stringValue == "openai-responses-v1")
    }

    @Test func schemaBecomesJSONSchemaFormatWithRequiredParameters() throws {
        let transcript = Transcript(entries: [.prompt(.init(id: "p", segments: [.text(.init(content: "hi"))]))])
        let body = try ResponsesRequestBuilder(model: OpenRouterLanguageModel(modelID: "m")).body(for: makeRequest(transcript: transcript, schema: WeatherArguments.generationSchema))
        #expect(body["text"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["text"]?["format"]?["schema"]?["type"]?.stringValue == "object")
        #expect(body["text"]?["format"]?["schema"]?["x-order"] == nil)
        #expect(body["provider"]?["require_parameters"]?.boolValue == true)
    }

    @Test func toolCallingModeMapsToToolChoice() throws {
        let transcript = Transcript(entries: [.prompt(.init(id: "p", segments: [.text(.init(content: "hi"))]))])
        var request = makeRequest(transcript: transcript)
        request.generationOptions = GenerationOptions(toolCallingMode: .required)
        let body = try ResponsesRequestBuilder(model: OpenRouterLanguageModel(modelID: "m", usesPromptCache: false)).body(for: request)
        #expect(body["tool_choice"]?.stringValue == "required")
        #expect(body["cache_control"] == nil)
    }
}
