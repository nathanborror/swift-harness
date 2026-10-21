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
        self.init(configuration: configuration, session: nil)
    }

    /// Tests pass a session with a mock transport.
    init(configuration: OpenRouterConfiguration, session: URLSession?) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
            sessionConfiguration.timeoutIntervalForResource = configuration.timeout
            sessionConfiguration.waitsForConnectivity = true
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    public func prewarm(model: OpenRouterLanguageModel, transcript: Transcript) {
        // A server-backed model has nothing to load ahead of time.
    }

    /// A failure that is safe to retry because nothing reached the session yet.
    struct TransientFailure: Error {
        let underlying: any Error
        let retryAfter: TimeInterval?
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenRouterLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let body = try ResponsesRequestBuilder(model: model).body(for: request)
        let urlRequest = try makeURLRequest(body: body)
        let policy = configuration.retry
        var attempt = 0
        while true {
            attempt += 1
            let dump = DebugDump(directory: configuration.debugDirectory, requestID: request.id, attempt: attempt)
            dump.writeRequest(body)
            do {
                try await performOnce(urlRequest, channel: channel, dump: dump, usageHandler: model.usageHandler)
                return
            } catch let failure as TransientFailure {
                guard attempt < max(policy.maximumAttempts, 1) else { throw Self.mapped(failure.underlying) }
                let backoff = min(policy.baseDelay * pow(2, Double(attempt - 1)), policy.maximumDelay)
                let delay = min(failure.retryAfter ?? backoff, policy.maximumDelay)
                try await Task.sleep(for: .seconds(delay))
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    private func performOnce(_ urlRequest: URLRequest, channel: LanguageModelExecutorGenerationChannel, dump: DebugDump, usageHandler: (@Sendable (OpenRouterUsage) -> Void)?) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        let started = Date()
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let error as URLError where Self.isTransient(error) {
            dump.writeFailure(error, started: started)
            throw TransientFailure(underlying: error, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.http(status: 0, code: nil, message: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            dump.writeResponse(data, http: http, started: started)
            let error = OpenRouterErrorMapping.error(status: http.statusCode, body: data)
            if Self.transientStatuses.contains(http.statusCode) {
                throw TransientFailure(underlying: error, retryAfter: Self.retryAfter(http))
            }
            throw error
        }

        var translator = ResponsesStreamTranslator(generationID: http.value(forHTTPHeaderField: "x-generation-id"))
        var parser = ServerSentEventParser()
        var finished = false
        var delivered = false
        // `AsyncBytes.lines` drops empty lines, and a blank line is what ends an
        // SSE event, so the stream is split on newline bytes by hand.
        var buffer: [UInt8] = []
        var raw = Data()
        defer { dump.writeResponse(raw, http: http, started: started) }
        func deliver(_ line: String) async throws -> Bool {
            guard let event = parser.feed(line) else { return false }
            if event.data == "[DONE]" { return true }
            for translated in try translator.handle(data: event.data) {
                try await send(translated)
            }
            return false
        }
        func send(_ translated: ResponsesStreamTranslator.Event) async throws {
            await channel.send(try translated.channelEvent())
            delivered = true
            if case .usage(_, let usage, let metadata) = translated {
                usageHandler?(OpenRouterUsage(usage, metadata: metadata))
            }
        }
        do {
            for try await byte in bytes {
                if dump.isEnabled { raw.append(byte) }
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
                        try await send(translated)
                    }
                }
            }
            try translator.finish()
        } catch where !delivered {
            // Nothing reached the session: a failed or empty stream can be retried.
            if let error = error as? URLError, Self.isTransient(error) {
                throw TransientFailure(underlying: error, retryAfter: nil)
            }
            if error is OpenRouterError {
                throw TransientFailure(underlying: error, retryAfter: nil)
            }
            throw error
        }
    }

    static let transientStatuses: Set<Int> = [408, 409, 425, 429, 500, 502, 503, 504]

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) { return max(date.timeIntervalSinceNow, 0) }
        return nil
    }

    /// Gives a URL timeout the framework's vocabulary so callers handle it like any other model timeout.
    static func mapped(_ error: any Error) -> any Error {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return LanguageModelError.timeout(.init(debugDescription: urlError.localizedDescription, metadata: ["code": urlError.code.rawValue]))
        }
        return error
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

// MARK: - Usage

extension OpenRouterUsage {
    init(_ usage: ResponsesStreamTranslator.Usage, metadata: [String: JSONValue]) {
        self.init(
            generationID: (metadata[OpenRouterMetadataKey.generationID] ?? metadata[OpenRouterMetadataKey.responseID])?.stringValue,
            model: metadata[OpenRouterMetadataKey.model]?.stringValue,
            cost: metadata[OpenRouterMetadataKey.cost]?.doubleValue,
            inputTokens: usage.inputTokens,
            cachedTokens: usage.cachedTokens,
            outputTokens: usage.outputTokens,
            reasoningTokens: usage.reasoningTokens
        )
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

/// Writes one attempt's request and response to the debug directory, when one is set.
struct DebugDump: Sendable {
    let directory: URL?
    let prefix: String

    init(directory: URL?, requestID: UUID, attempt: Int) {
        self.directory = directory
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        // Attempts of one request sort together: time, request, attempt.
        self.prefix = "\(formatter.string(from: Date()))-\(requestID.uuidString.prefix(8).lowercased())-\(attempt)"
    }

    var isEnabled: Bool { directory != nil }

    func writeRequest(_ body: JSONValue) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.encoded(pretty: true).write(to: directory.appending(path: "\(prefix).request.json"))
    }

    func writeResponse(_ data: Data, http: HTTPURLResponse, started: Date) {
        guard let directory else { return }
        try? data.write(to: directory.appending(path: "\(prefix).response.sse"))
        let headers = http.allHeaderFields.reduce(into: [String: JSONValue]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = .string(String(describing: pair.value))
        }
        let meta: JSONValue = .object([
            "status": .number(Double(http.statusCode)),
            "seconds": .number(Date().timeIntervalSince(started)),
            "headers": .object(headers),
        ])
        try? meta.encoded(pretty: true).write(to: directory.appending(path: "\(prefix).meta.json"))
    }

    func writeFailure(_ error: any Error, started: Date) {
        guard let directory else { return }
        let meta: JSONValue = .object(["error": .string(String(describing: error)), "seconds": .number(Date().timeIntervalSince(started))])
        try? meta.encoded(pretty: true).write(to: directory.appending(path: "\(prefix).meta.json"))
    }
}
