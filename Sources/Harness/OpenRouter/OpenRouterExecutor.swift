import Foundation
import FoundationModels

/// Runs generation requests against OpenRouter's Responses API and streams
/// the result into the framework's channel.
///
/// The framework creates one executor per configuration and reuses it for
/// every model that shares that configuration. Requests carry the full
/// transcript each time, which is what OpenRouter needs: it stores nothing
/// between calls.
public struct OpenRouterExecutor: LanguageModelExecutor {
    public typealias Configuration = OpenRouterConfiguration
    public typealias Model = OpenRouterLanguageModel

    let configuration: OpenRouterConfiguration
    let session: URLSession

    public init(configuration: OpenRouterConfiguration) throws {
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        sessionConfiguration.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public func prewarm(model: OpenRouterLanguageModel, transcript: Transcript) {
        // A server-backed model has nothing to load ahead of time.
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenRouterLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let body = try ResponsesRequestBuilder(model: model).body(for: request)
        let urlRequest = try makeURLRequest(body: body)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.http(status: 0, code: nil, message: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw OpenRouterErrorMapping.error(status: http.statusCode, body: data)
        }

        var translator = ResponsesStreamTranslator(generationID: http.value(forHTTPHeaderField: "x-generation-id"))
        var parser = ServerSentEventParser()
        var finished = false
        // `AsyncBytes.lines` drops empty lines, and a blank line is what ends an
        // SSE event, so the stream is split on newline bytes by hand.
        var buffer: [UInt8] = []
        func deliver(_ line: String) async throws -> Bool {
            guard let event = parser.feed(line) else { return false }
            if event.data == "[DONE]" { return true }
            for translated in try translator.handle(data: event.data) {
                await channel.send(try translated.channelEvent())
            }
            return false
        }
        for try await byte in bytes {
            if byte == 0x0A {
                if buffer.last == 0x0D { buffer.removeLast() }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                if try await deliver(line) { finished = true; break }
            } else {
                buffer.append(byte)
            }
        }
        if !finished {
            if !buffer.isEmpty { _ = try await deliver(String(decoding: buffer, as: UTF8.self)) }
            if let event = parser.flush(), event.data != "[DONE]" {
                for translated in try translator.handle(data: event.data) {
                    await channel.send(try translated.channelEvent())
                }
            }
        }
        try translator.finish()
    }

    func makeURLRequest(body: JSONValue) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appending(path: "responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token = try configuration.resolveBearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try body.encoded()
        return request
    }
}

// MARK: - Channel adapter

extension ResponsesStreamTranslator.Event {
    typealias Channel = LanguageModelExecutorGenerationChannel

    func channelEvent() throws -> Channel.Event {
        switch self {
        case .appendText(let target, let text):
            switch target {
            case .response(let entryID):
                return .response(entryID: entryID, action: .appendText(text, tokenCount: 0))
            case .reasoning(let entryID):
                return .reasoning(entryID: entryID, action: .appendText(text, tokenCount: 0))
            case .toolCalls(let entryID):
                return .toolCalls(entryID: entryID, action: .updateMetadata(["text": text]))
            }
        case .reasoningSignature(let entryID, let data):
            return .reasoning(entryID: entryID, action: .updateSignature(data, tokenCount: 0))
        case .metadata(let target, let values):
            let converted = try Self.convert(values)
            switch target {
            case .response(let entryID): return .response(entryID: entryID, action: .updateMetadata(converted))
            case .reasoning(let entryID): return .reasoning(entryID: entryID, action: .updateMetadata(converted))
            case .toolCalls(let entryID): return .toolCalls(entryID: entryID, action: .updateMetadata(converted))
            }
        case .appendArguments(let entryID, let callID, let name, let delta):
            return .toolCalls(entryID: entryID, action: .toolCall(id: callID, name: name, action: .appendArguments(delta, tokenCount: 0)))
        case .toolCallMetadata(let entryID, let callID, let name, let values):
            return .toolCalls(entryID: entryID, action: .toolCall(id: callID, name: name, action: .updateMetadata(try Self.convert(values))))
        case .usage(let target, let usage, let values):
            let input = Channel.Usage.Input(totalTokenCount: usage.inputTokens, cachedTokenCount: usage.cachedTokens)
            let output = Channel.Usage.Output(totalTokenCount: usage.outputTokens, reasoningTokenCount: usage.reasoningTokens)
            let converted = try Self.convert(values)
            switch target {
            case .response(let entryID):
                return .response(entryID: entryID, action: .updateUsage(input: input, output: output, metadata: converted))
            case .reasoning(let entryID):
                return .reasoning(entryID: entryID, action: .updateUsage(input: input, output: output, metadata: converted))
            case .toolCalls(let entryID):
                return .toolCalls(entryID: entryID, action: .updateUsage(input: input, output: output, metadata: converted))
            }
        }
    }

    private static func convert(_ values: [String: JSONValue]) throws -> [String: any ConvertibleToGeneratedContent] {
        var result: [String: any ConvertibleToGeneratedContent] = [:]
        for (key, value) in values {
            switch value {
            case .null: continue
            case .bool(let bool): result[key] = bool
            case .number(let number): result[key] = number
            case .string(let string): result[key] = string
            case .array, .object: result[key] = try GeneratedContent(json: value.encodedString())
            }
        }
        return result
    }
}
