import Foundation
import FoundationModels
import Testing
@testable import Harness

/// A URLProtocol that answers from a scripted queue, one response per request.
final class MockTransport: URLProtocol {
    struct Scripted: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data
        var failWith: URLError.Code? = nil
    }

    nonisolated(unsafe) static var queue: [Scripted] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func reset(_ responses: [Scripted]) {
        lock.withLock { queue = responses; requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next: Scripted? = Self.lock.withLock {
            Self.requests.append(request)
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let code = next.failWith {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ExecutorRetryTests {
    private func makeExecutor(retry: OpenRouterConfiguration.RetryPolicy = .init(maximumAttempts: 2, baseDelay: 0.01)) -> (OpenRouterExecutor, OpenRouterLanguageModel) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTransport.self]
        let openRouter = OpenRouterConfiguration(credential: .apiKey("test"), retry: retry)
        let executor = OpenRouterExecutor(configuration: openRouter, session: URLSession(configuration: configuration))
        return (executor, OpenRouterLanguageModel(modelID: "test/model", configuration: openRouter, usesPromptCache: false))
    }

    private func stream(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The channel applies back-pressure: `send` suspends until a consumer reads. Drain it.
    private func respond(_ executor: OpenRouterExecutor, _ model: OpenRouterLanguageModel) async throws {
        let channel = LanguageModelExecutorGenerationChannel()
        let drain = Task { for try await _ in channel {} }
        defer { drain.cancel() }
        try await executor.respond(to: request(), model: model, streamingInto: channel)
    }

    private func request() -> LanguageModelExecutorGenerationRequest {
        LanguageModelExecutorGenerationRequest(id: UUID(), transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))]), enabledTools: [], schema: nil, generationOptions: GenerationOptions(), contextOptions: ContextOptions(), metadata: [:])
    }

    @Test func retriesAServerErrorOnceThenSucceeds() async throws {
        MockTransport.reset([
            .init(status: 503, body: Data(#"{"error":{"code":503,"message":"overloaded"}}"#.utf8)),
            .init(status: 200, body: try stream("stream-text")),
        ])
        let (executor, model) = makeExecutor()
        try await respond(executor, model)
        #expect(MockTransport.requests.count == 2)
    }

    @Test func honorsRetryAfterAndGivesUpAfterTheLastAttempt() async throws {
        MockTransport.reset([
            .init(status: 429, headers: ["Retry-After": "0"], body: Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)),
            .init(status: 429, headers: ["Retry-After": "0"], body: Data(#"{"error":{"code":429,"message":"slow down"}}"#.utf8)),
        ])
        let (executor, model) = makeExecutor()
        await #expect(throws: LanguageModelError.self) {
            try await respond(executor, model)
        }
        #expect(MockTransport.requests.count == 2)
    }

    @Test func doesNotRetryClientErrors() async throws {
        MockTransport.reset([
            .init(status: 400, body: Data(#"{"error":{"code":400,"message":"bad field"}}"#.utf8)),
            .init(status: 200, body: try stream("stream-text")),
        ])
        let (executor, model) = makeExecutor()
        await #expect(throws: OpenRouterError.self) {
            try await respond(executor, model)
        }
        #expect(MockTransport.requests.count == 1)
    }

    @Test func retriesAConnectionFailureAndMapsATimeout() async throws {
        MockTransport.reset([
            .init(status: 0, body: Data(), failWith: .networkConnectionLost),
            .init(status: 200, body: try stream("stream-tool-call")),
        ])
        let (executor, model) = makeExecutor()
        try await respond(executor, model)
        #expect(MockTransport.requests.count == 2)

        MockTransport.reset([.init(status: 0, body: Data(), failWith: .timedOut)])
        let (single, model2) = makeExecutor(retry: .none)
        await #expect(throws: LanguageModelError.self) {
            try await respond(single, model2)
        }
        #expect(MockTransport.requests.count == 1)
    }

    @Test func retriesACommittedErrorChunkWhenNothingWasDelivered() async throws {
        MockTransport.reset([
            .init(status: 200, body: Data("data: {\"error\":{\"code\":502,\"message\":\"upstream\"}}\n\ndata: [DONE]\n\n".utf8)),
            .init(status: 200, body: try stream("stream-text")),
        ])
        let (executor, model) = makeExecutor()
        try await respond(executor, model)
        #expect(MockTransport.requests.count == 2)
    }
}

// Same serialized suite as the retry tests: both script the shared mock transport.
extension ExecutorRetryTests {
    @Test func writesRequestResponseAndMetaPerAttempt() async throws {
        let debug = FileManager.default.temporaryDirectory.appending(path: "harness-debug-\(UUID().uuidString)")
        MockTransport.reset([
            .init(status: 503, body: Data(#"{"error":{"code":503,"message":"overloaded"}}"#.utf8)),
            .init(status: 200, headers: ["x-generation-id": "gen-dump"], body: try Data(contentsOf: #require(Bundle.module.url(forResource: "stream-text", withExtension: "sse", subdirectory: "Fixtures")))),
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTransport.self]
        let openRouter = OpenRouterConfiguration(credential: .apiKey("test"), retry: .init(maximumAttempts: 2, baseDelay: 0.01), debugDirectory: debug)
        let executor = OpenRouterExecutor(configuration: openRouter, session: URLSession(configuration: configuration))
        let model = OpenRouterLanguageModel(modelID: "test/model", configuration: openRouter)
        let channel = LanguageModelExecutorGenerationChannel()
        let drain = Task { for try await _ in channel {} }
        defer { drain.cancel() }
        let request = LanguageModelExecutorGenerationRequest(id: UUID(), transcript: Transcript(entries: [.prompt(.init(segments: [.text(.init(content: "hi"))]))]), enabledTools: [], schema: nil, generationOptions: GenerationOptions(), contextOptions: ContextOptions(), metadata: [:])
        try await executor.respond(to: request, model: model, streamingInto: channel)

        let files = try FileManager.default.contentsOfDirectory(atPath: debug.path).sorted()
        #expect(files.filter { $0.hasSuffix(".request.json") }.count == 2, "one request per attempt")
        #expect(files.filter { $0.hasSuffix(".response.sse") }.count == 2)
        #expect(files.filter { $0.hasSuffix(".meta.json") }.count == 2)
        let requestBody = try JSONValue(data: try Data(contentsOf: debug.appending(path: files.first { $0.hasSuffix("-1.request.json") }!)))
        #expect(requestBody["model"]?.stringValue == "test/model")
        let meta = try JSONValue(data: try Data(contentsOf: debug.appending(path: files.first { $0.hasSuffix("-2.meta.json") }!)))
        #expect(meta["status"]?.intValue == 200)
        #expect(meta["headers"]?["x-generation-id"]?.stringValue == "gen-dump")
        let sse = try String(contentsOf: debug.appending(path: files.first { $0.hasSuffix("-2.response.sse") }!), encoding: .utf8)
        #expect(sse.contains("response.completed"))
    }
}
