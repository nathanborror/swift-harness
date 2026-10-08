import Foundation
import FoundationModels
import Testing
@testable import Harness

@Suite struct ModelCatalogTests {
    private func fixture() throws -> [String: OpenRouterModelInfo] {
        let url = try #require(Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Fixtures"))
        return try OpenRouterModelCatalog.decode(try Data(contentsOf: url))
    }

    @Test func decodesCapabilitiesFromTheListing() throws {
        let models = try fixture()
        let haiku = try #require(models["anthropic/claude-haiku-4.5"])
        #expect(haiku.contextLength == 200_000)
        #expect(haiku.maxCompletionTokens == 64_000)
        #expect(haiku.supportsTools && haiku.supportsStructuredOutputs && haiku.supportsReasoning && haiku.supportsImages)
        #expect(haiku.capabilities.contains(.toolCalling) && haiku.capabilities.contains(.vision))
        #expect(haiku.pricing?.promptPerMillion == 1.0)
        #expect(haiku.contextPolicy()?.contextTokens == 200_000)
        #expect(haiku.tokenizer == "Claude")

        let sonnet = try #require(models["anthropic/claude-sonnet-4.6"])
        #expect(sonnet.contextLength == 1_000_000)

        let plain = try #require(models["nvidia/switchyard"])
        #expect(!plain.supportsTools && !plain.supportsImages)
        #expect(!plain.capabilities.contains(.toolCalling))
    }

    @Test func cachedCatalogServesWithoutTheNetwork() async throws {
        let url = try #require(Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Fixtures"))
        let cache = FileManager.default.temporaryDirectory.appending(path: "harness-models-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: url, to: cache)
        let catalog = OpenRouterModelCatalog(configuration: OpenRouterConfiguration(baseURL: URL(string: "https://invalid.invalid")!, credential: .none), cacheURL: cache)
        let info = try await catalog.info(for: "openai/gpt-5.5")
        #expect(info?.contextLength == 1_050_000)
        let model = try await catalog.makeModel("anthropic/claude-haiku-4.5", sessionID: "s", defaultReasoningEffort: "low")
        #expect(model.capabilities.contains(.vision) && model.sessionID == "s" && model.defaultReasoningEffort == "low")
        let unknown = try await catalog.makeModel("someone/new-model")
        #expect(unknown.capabilities.contains(.toolCalling), "unknown models keep the default capabilities")
        let stale = OpenRouterModelCatalog(configuration: OpenRouterConfiguration(baseURL: URL(string: "https://invalid.invalid")!, credential: .none), cacheURL: cache, cacheLifetime: 0)
        await #expect(throws: (any Error).self) { _ = try await stale.all() }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] != nil))
struct ModelCatalogLiveTests {
    @Test func fetchesTheLiveListing() async throws {
        let cache = FileManager.default.temporaryDirectory.appending(path: "harness-models-live-\(UUID().uuidString).json")
        let catalog = OpenRouterModelCatalog(cacheURL: cache)
        let all = try await catalog.all(forceRefresh: true)
        #expect(all.count > 100)
        let haiku = try #require(try await catalog.info(for: "anthropic/claude-haiku-4.5"))
        #expect(haiku.supportsTools && haiku.contextLength ?? 0 >= 100_000)
        #expect(FileManager.default.fileExists(atPath: cache.path), "the listing is cached")
        let withEfforts = all.first { $0.reasoning?.supportedEfforts?.isEmpty == false }
        if let withEfforts {
            await #expect(throws: OpenRouterError.self) {
                _ = try await catalog.makeModel(withEfforts.id, defaultReasoningEffort: "not-an-effort")
            }
        }
    }
}
