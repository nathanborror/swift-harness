import Foundation

/// Translates Responses API stream events into provider-neutral events that
/// map directly onto the framework's generation channel.
///
/// Kept free of framework types so tests can inspect its output. The channel
/// adapter lives in the executor.
struct ResponsesStreamTranslator {
    enum Target: Equatable, Sendable {
        case response(entryID: String)
        case reasoning(entryID: String)
        case toolCalls(entryID: String)
    }

    struct Usage: Equatable, Sendable {
        var inputTokens: Int
        var cachedTokens: Int
        var outputTokens: Int
        var reasoningTokens: Int
    }

    enum Event: Equatable, Sendable {
        case appendText(Target, String)
        case reasoningSignature(entryID: String, Data)
        case metadata(Target, [String: JSONValue])
        case appendArguments(entryID: String, callID: String, name: String, String)
        case toolCallMetadata(entryID: String, callID: String, name: String, [String: JSONValue])
        case usage(Target, Usage, [String: JSONValue])
    }

    private enum ItemKind { case message, reasoning, functionCall(callID: String, name: String), other }

    private struct ItemState {
        var kind: ItemKind
        var streamedText = ""
        var streamedArguments = ""
    }

    let generationID: String?
    private(set) var responseID: String?
    private(set) var completed = false
    private var items: [String: ItemState] = [:]
    private var lastTarget: Target?

    init(generationID: String?) {
        self.generationID = generationID
    }

    private var toolCallsEntryID: String { "toolcalls_\(responseID ?? "response")" }

    mutating func handle(data: String) throws -> [Event] {
        let event: JSONValue
        do {
            event = try JSONValue(jsonString: data)
        } catch {
            throw OpenRouterError.malformedEvent(String(data.prefix(200)))
        }
        if let error = event["error"], !error.isNull, event["type"]?.stringValue == nil {
            throw OpenRouterError.streamFailed(message: error["message"]?.stringValue ?? data)
        }
        guard let type = event["type"]?.stringValue else {
            throw OpenRouterError.malformedEvent("missing type")
        }
        switch type {
        case "response.created", "response.in_progress":
            if let id = event["response"]?["id"]?.stringValue { responseID = id }
            return []
        case "response.output_item.added":
            return try itemAdded(event["item"])
        case "response.output_text.delta":
            return try textDelta(event, target: .response)
        case "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.reasoning.delta":
            return try textDelta(event, target: .reasoning)
        case "response.function_call_arguments.delta":
            return try argumentsDelta(event)
        case "response.function_call_arguments.done":
            return try argumentsDone(event)
        case "response.output_item.done":
            return try itemDone(event["item"])
        case "response.completed", "response.incomplete":
            return try completed(event["response"], incomplete: type == "response.incomplete")
        case "response.failed":
            let message = event["response"]?["error"]?["message"]?.stringValue ?? "response failed"
            throw OpenRouterError.streamFailed(message: message)
        case "error":
            let message = event["message"]?.stringValue ?? event["error"]?["message"]?.stringValue ?? data
            throw OpenRouterError.streamFailed(message: message)
        default:
            return []
        }
    }

    func finish() throws {
        guard completed else { throw OpenRouterError.streamFailed(message: "stream ended before response.completed") }
    }

    // MARK: Item lifecycle

    private mutating func itemAdded(_ item: JSONValue?) throws -> [Event] {
        guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
            throw OpenRouterError.malformedEvent("output_item.added without id/type")
        }
        switch type {
        case "message":
            items[id] = ItemState(kind: .message)
            return []
        case "reasoning":
            items[id] = ItemState(kind: .reasoning)
            return []
        case "function_call":
            let callID = item["call_id"]?.stringValue ?? id
            let name = item["name"]?.stringValue ?? ""
            items[id] = ItemState(kind: .functionCall(callID: callID, name: name))
            lastTarget = .toolCalls(entryID: toolCallsEntryID)
            let initial = item["arguments"]?.stringValue ?? ""
            guard !initial.isEmpty else { return [] }
            items[id]?.streamedArguments = initial
            return [.appendArguments(entryID: toolCallsEntryID, callID: callID, name: name, initial)]
        default:
            items[id] = ItemState(kind: .other)
            return []
        }
    }

    private enum DeltaTarget { case response, reasoning }

    private mutating func textDelta(_ event: JSONValue, target: DeltaTarget) throws -> [Event] {
        guard let itemID = event["item_id"]?.stringValue else { throw OpenRouterError.malformedEvent("delta without item_id") }
        let delta = event["delta"]?.stringValue ?? ""
        if items[itemID] == nil { items[itemID] = ItemState(kind: target == .response ? .message : .reasoning) }
        items[itemID]?.streamedText += delta
        guard !delta.isEmpty else { return [] }
        let eventTarget: Target = target == .response ? .response(entryID: itemID) : .reasoning(entryID: itemID)
        lastTarget = eventTarget
        return [.appendText(eventTarget, delta)]
    }

    private mutating func argumentsDelta(_ event: JSONValue) throws -> [Event] {
        guard let itemID = event["item_id"]?.stringValue, let state = items[itemID],
            case .functionCall(let callID, let name) = state.kind
        else { throw OpenRouterError.malformedEvent("arguments delta for unknown item") }
        let delta = event["delta"]?.stringValue ?? ""
        items[itemID]?.streamedArguments += delta
        guard !delta.isEmpty else { return [] }
        lastTarget = .toolCalls(entryID: toolCallsEntryID)
        return [.appendArguments(entryID: toolCallsEntryID, callID: callID, name: name, delta)]
    }

    private mutating func argumentsDone(_ event: JSONValue) throws -> [Event] {
        guard let itemID = event["item_id"]?.stringValue, let state = items[itemID],
            case .functionCall(let callID, let name) = state.kind
        else { return [] }
        let full = event["arguments"]?.stringValue ?? ""
        guard state.streamedArguments.isEmpty, !full.isEmpty else { return [] }
        items[itemID]?.streamedArguments = full
        return [.appendArguments(entryID: toolCallsEntryID, callID: callID, name: name, full)]
    }

    private mutating func itemDone(_ item: JSONValue?) throws -> [Event] {
        guard let item, let id = item["id"]?.stringValue, let type = item["type"]?.stringValue else {
            throw OpenRouterError.malformedEvent("output_item.done without id/type")
        }
        var events: [Event] = []
        let state = items[id]
        switch type {
        case "message":
            let text = Self.text(in: item["content"], partType: "output_text", key: "text")
            if (state?.streamedText ?? "").isEmpty, !text.isEmpty {
                events.append(.appendText(.response(entryID: id), text))
                items[id, default: ItemState(kind: .message)].streamedText = text
            }
            events.append(.metadata(.response(entryID: id), [OpenRouterMetadataKey.itemID: .string(id)]))
            lastTarget = .response(entryID: id)
        case "reasoning":
            let text = Self.text(in: item["content"], partType: "reasoning_text", key: "text")
            let summary = Self.text(in: item["summary"], partType: "summary_text", key: "text")
            let combined = text.isEmpty ? summary : text
            if (state?.streamedText ?? "").isEmpty, !combined.isEmpty {
                events.append(.appendText(.reasoning(entryID: id), combined))
                items[id, default: ItemState(kind: .reasoning)].streamedText = combined
            }
            if let signature = item["signature"]?.stringValue, !signature.isEmpty {
                events.append(.reasoningSignature(entryID: id, Data(signature.utf8)))
            }
            var metadata: [String: JSONValue] = [OpenRouterMetadataKey.item: .string(try item.encodedString())]
            if let format = item["format"]?.stringValue { metadata[OpenRouterMetadataKey.reasoningFormat] = .string(format) }
            events.append(.metadata(.reasoning(entryID: id), metadata))
            lastTarget = .reasoning(entryID: id)
        case "function_call":
            let callID = item["call_id"]?.stringValue ?? id
            let name = item["name"]?.stringValue ?? ""
            let full = item["arguments"]?.stringValue ?? ""
            if (state?.streamedArguments ?? "").isEmpty, !full.isEmpty {
                events.append(.appendArguments(entryID: toolCallsEntryID, callID: callID, name: name, full))
                items[id, default: ItemState(kind: .functionCall(callID: callID, name: name))].streamedArguments = full
            }
            var stored = item
            if case .object(var object) = stored {
                object["arguments"] = nil
                stored = .object(object)
            }
            events.append(.toolCallMetadata(entryID: toolCallsEntryID, callID: callID, name: name, [
                OpenRouterMetadataKey.itemID: .string(id),
                OpenRouterMetadataKey.item: .string(try stored.encodedString()),
            ]))
            lastTarget = .toolCalls(entryID: toolCallsEntryID)
        default:
            break
        }
        return events
    }

    private mutating func completed(_ response: JSONValue?, incomplete: Bool) throws -> [Event] {
        completed = true
        if let id = response?["id"]?.stringValue { responseID = id }
        var events: [Event] = []
        // Providers that do not stream per item still deliver everything in the final output array.
        for item in response?["output"]?.arrayValue ?? [] {
            guard let id = item["id"]?.stringValue, items[id] == nil else { continue }
            events += try itemAdded(item)
            events += try itemDone(item)
        }
        guard let target = lastTarget else { throw OpenRouterError.noOutput }
        var metadata: [String: JSONValue] = [:]
        if let responseID { metadata[OpenRouterMetadataKey.responseID] = .string(responseID) }
        if let generationID { metadata[OpenRouterMetadataKey.generationID] = .string(generationID) }
        if let model = response?["model"]?.stringValue { metadata[OpenRouterMetadataKey.model] = .string(model) }
        if incomplete {
            metadata[OpenRouterMetadataKey.incompleteReason] = response?["incomplete_details"]?["reason"] ?? .string("unknown")
        }
        let usageJSON = response?["usage"]
        if let cost = usageJSON?["cost"]?.doubleValue { metadata[OpenRouterMetadataKey.cost] = .number(cost) }
        if let writes = usageJSON?["input_tokens_details"]?["cache_write_tokens"]?.intValue {
            metadata[OpenRouterMetadataKey.cacheWriteTokens] = .number(Double(writes))
        }
        let usage = Usage(
            inputTokens: usageJSON?["input_tokens"]?.intValue ?? 0,
            cachedTokens: usageJSON?["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0,
            outputTokens: usageJSON?["output_tokens"]?.intValue ?? 0,
            reasoningTokens: usageJSON?["output_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0
        )
        events.append(.metadata(target, metadata))
        events.append(.usage(target, usage, metadata))
        return events
    }

    private static func text(in parts: JSONValue?, partType: String, key: String) -> String {
        (parts?.arrayValue ?? [])
            .filter { $0["type"]?.stringValue == partType }
            .compactMap { $0[key]?.stringValue }
            .joined()
    }
}
