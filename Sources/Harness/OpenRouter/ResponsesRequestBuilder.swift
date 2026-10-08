import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

/// Turns a framework generation request into a Responses API body.
///
/// Transcript entries map one to one onto Responses items: instructions become
/// the `instructions` field, prompts become user messages, responses become
/// assistant messages, reasoning and tool calls become their own items, and
/// tool outputs become `function_call_output` items. Items the provider sent
/// earlier are replayed from the raw copy kept in metadata so opaque state
/// such as signatures survives.
struct ResponsesRequestBuilder {
    let model: OpenRouterLanguageModel

    func body(for request: LanguageModelExecutorGenerationRequest) throws -> JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model.modelID),
            "stream": true,
        ]

        var instructions: [String] = []
        var input: [JSONValue] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let value):
                let text = Self.text(from: value.segments)
                if !text.isEmpty { instructions.append(text) }
            case .prompt(let prompt):
                input.append(.object(["role": "user", "content": .array(try Self.inputContent(prompt.segments))]))
            case .response(let response):
                input.append(Self.assistantMessage(response))
            case .reasoning(let reasoning):
                input.append(Self.reasoningItem(reasoning))
            case .toolCalls(let calls):
                for call in calls { input.append(Self.functionCall(call)) }
            case .toolOutput(let output):
                input.append(try Self.functionCallOutput(output))
            @unknown default:
                continue
            }
        }
        if !instructions.isEmpty {
            object["instructions"] = .string(instructions.joined(separator: "\n\n"))
        }
        object["input"] = .array(input)

        if !request.enabledToolDefinitions.isEmpty {
            object["tools"] = .array(try request.enabledToolDefinitions.map(Self.functionTool))
        }

        let generation = request.generationOptions
        if let temperature = generation.temperature { object["temperature"] = .number(temperature) }
        if let sampling = generation.samplingMode {
            switch sampling.kind {
            case .greedy: object["temperature"] = 0
            case .randomTopK(let k, _): object["top_k"] = .number(Double(k))
            case .randomProbabilityThreshold(let p, _): object["top_p"] = .number(p)
            @unknown default: break
            }
        }
        if let maximum = generation.maximumResponseTokens { object["max_output_tokens"] = .number(Double(maximum)) }
        if let mode = generation.toolCallingMode {
            switch mode.kind {
            case .allowed: object["tool_choice"] = "auto"
            case .required: object["tool_choice"] = "required"
            case .disallowed: object["tool_choice"] = "none"
            @unknown default: break
            }
        }

        if let effort = Self.reasoningEffort(request.contextOptions.reasoningLevel) ?? model.defaultReasoningEffort {
            object["reasoning"] = .object(["effort": .string(effort)])
        }
        if model.capabilities.contains(.reasoning) {
            object["include"] = ["reasoning.encrypted_content"]
        }

        var provider = model.providerPreferences
        if let schema = request.schema {
            let json = try Self.providerSchema(schema)
            object["text"] = .object([
                "format": .object([
                    "type": "json_schema",
                    "name": .string(Self.schemaName(schema.name)),
                    "strict": false,
                    "schema": json,
                ])
            ])
            provider["require_parameters"] = true
        }
        if !provider.isEmpty { object["provider"] = .object(provider) }

        if model.usesPromptCache { object["cache_control"] = .object(["type": "ephemeral"]) }
        if let sessionID = model.sessionID { object["session_id"] = .string(sessionID) }
        for (key, value) in model.additionalParameters { object[key] = value }
        return .object(object)
    }

    // MARK: Entries to items

    static func functionTool(_ definition: Transcript.ToolDefinition) throws -> JSONValue {
        .object([
            "type": "function",
            "name": .string(definition.name),
            "description": .string(definition.description),
            "parameters": try providerSchema(definition.parameters),
            "strict": false,
        ])
    }

    static func assistantMessage(_ response: Transcript.Response) -> JSONValue {
        .object([
            "type": "message",
            "id": .string(response.id),
            "role": "assistant",
            "status": "completed",
            "content": [.object(["type": "output_text", "text": .string(text(from: response.segments)), "annotations": []])],
        ])
    }

    static func reasoningItem(_ reasoning: Transcript.Reasoning) -> JSONValue {
        if let raw = storedItem(reasoning.metadata) { return raw }
        var item: [String: JSONValue] = [
            "type": "reasoning",
            "id": .string(reasoning.id),
            "status": "completed",
            "summary": [],
        ]
        let content = text(from: reasoning.segments)
        item["content"] = content.isEmpty ? [] : [.object(["type": "reasoning_text", "text": .string(content)])]
        if let signature = reasoning.signature, let text = String(data: signature, encoding: .utf8) {
            item["signature"] = .string(text)
        }
        if let format = reasoning.metadata[OpenRouterMetadataKey.reasoningFormat].flatMap({ try? $0.value(String.self) }) {
            item["format"] = .string(format)
        }
        return .object(item)
    }

    static func functionCall(_ call: Transcript.ToolCall) -> JSONValue {
        var item = storedItem(call.metadata)?.objectValue ?? [:]
        item["type"] = "function_call"
        item["call_id"] = .string(call.id)
        item["name"] = .string(call.toolName)
        item["arguments"] = .string(call.arguments.jsonString)
        if item["id"] == nil, let itemID = call.metadata[OpenRouterMetadataKey.itemID].flatMap({ try? $0.value(String.self) }) {
            item["id"] = .string(itemID)
        }
        if item["status"] == nil { item["status"] = "completed" }
        return .object(item)
    }

    static func functionCallOutput(_ output: Transcript.ToolOutput) throws -> JSONValue {
        let hasAttachment = output.segments.contains {
            if case .attachment = $0 { return true }
            return false
        }
        let value: JSONValue = hasAttachment ? .array(try inputContent(output.segments)) : .string(text(from: output.segments))
        return .object(["type": "function_call_output", "call_id": .string(output.id), "output": value])
    }

    // MARK: Segments

    static func text(from segments: [Transcript.Segment]) -> String {
        var parts: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text): parts.append(text.content)
            case .structure(let structure): parts.append(structure.content.jsonString)
            case .attachment: continue
            @unknown default: continue
            }
        }
        return parts.joined(separator: "\n")
    }

    static func inputContent(_ segments: [Transcript.Segment]) throws -> [JSONValue] {
        var parts: [JSONValue] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                parts.append(.object(["type": "input_text", "text": .string(text.content)]))
            case .structure(let structure):
                parts.append(.object(["type": "input_text", "text": .string(structure.content.jsonString)]))
            case .attachment(let attachment):
                switch attachment.content {
                case .image(let image):
                    parts.append(.object(["type": "input_image", "image_url": .string(try imageDataURL(image))]))
                @unknown default:
                    continue
                }
            @unknown default:
                continue
            }
        }
        return parts
    }

    static func imageDataURL(_ image: Transcript.ImageAttachment) throws -> String {
        if let url = image.url, url.isFileURL, let data = try? Data(contentsOf: url) {
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            return "data:\(type);base64,\(data.base64EncodedString())"
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw OpenRouterError.malformedEvent("Could not create an image encoder.")
        }
        CGImageDestinationAddImage(destination, image.cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OpenRouterError.malformedEvent("Could not encode an image attachment.")
        }
        return "data:image/png;base64,\((data as Data).base64EncodedString())"
    }

    // MARK: Helpers

    /// Encodes a generation schema as JSON Schema and removes Apple's `x-order`
    /// annotation, which Anthropic's structured-output validator rejects.
    static func providerSchema(_ schema: GenerationSchema) throws -> JSONValue {
        strippingVendorKeys(try JSONValue(encoding: schema))
    }

    static func strippingVendorKeys(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            var cleaned: [String: JSONValue] = [:]
            for (key, child) in object where key != "x-order" {
                cleaned[key] = strippingVendorKeys(child)
            }
            return .object(cleaned)
        case .array(let array):
            return .array(array.map(strippingVendorKeys))
        default:
            return value
        }
    }

    static func storedItem(_ metadata: [String: GeneratedContent]) -> JSONValue? {
        guard let content = metadata[OpenRouterMetadataKey.item], let raw = try? content.value(String.self) else { return nil }
        return try? JSONValue(jsonString: raw)
    }

    static func reasoningEffort(_ level: ContextOptions.ReasoningLevel?) -> String? {
        guard let level else { return nil }
        switch level {
        case .light: return "low"
        case .moderate: return "medium"
        case .deep: return "high"
        case .custom(let value): return value
        @unknown default: return nil
        }
    }

    static func schemaName(_ name: String) -> String {
        let allowed = name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return cleaned.isEmpty ? "output" : String(cleaned.prefix(64))
    }
}
