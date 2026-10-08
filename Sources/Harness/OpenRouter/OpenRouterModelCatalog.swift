import Foundation
import FoundationModels

/// What OpenRouter reports about one model.
public struct OpenRouterModelInfo: Sendable, Equatable, Codable, Identifiable {
    public struct Reasoning: Sendable, Equatable, Codable {
        public var supportedEfforts: [String]?
        public var defaultEffort: String?
        public var defaultEnabled: Bool?
        public var supportsMaxTokens: Bool?
        public var mandatory: Bool?

        enum CodingKeys: String, CodingKey {
            case supportedEfforts = "supported_efforts"
            case defaultEffort = "default_effort"
            case defaultEnabled = "default_enabled"
            case supportsMaxTokens = "supports_max_tokens"
            case mandatory
        }
    }

    public struct Pricing: Sendable, Equatable, Codable {
        /// Dollars per token, as strings in the API.
        public var prompt: String?
        public var completion: String?
        public var inputCacheRead: String?
        public var inputCacheWrite: String?

        enum CodingKeys: String, CodingKey {
            case prompt, completion
            case inputCacheRead = "input_cache_read"
            case inputCacheWrite = "input_cache_write"
        }

        public var promptPerMillion: Double? { prompt.flatMap(Double.init).map { $0 * 1_000_000 } }
        public var completionPerMillion: Double? { completion.flatMap(Double.init).map { $0 * 1_000_000 } }
    }

    struct Architecture: Sendable, Equatable, Codable {
        var inputModalities: [String]?
        var tokenizer: String?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
            case tokenizer
        }
    }

    struct TopProvider: Sendable, Equatable, Codable {
        var contextLength: Int?
        var maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case contextLength = "context_length"
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    public let id: String
    public let name: String?
    public let contextLength: Int?
    public let supportedParameters: [String]
    public let reasoning: Reasoning?
    public let pricing: Pricing?
    let architecture: Architecture?
    let topProvider: TopProvider?

    enum CodingKeys: String, CodingKey {
        case id, name, reasoning, pricing, architecture
        case contextLength = "context_length"
        case supportedParameters = "supported_parameters"
        case topProvider = "top_provider"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        supportedParameters = try container.decodeIfPresent([String].self, forKey: .supportedParameters) ?? []
        reasoning = try? container.decodeIfPresent(Reasoning.self, forKey: .reasoning)
        pricing = try? container.decodeIfPresent(Pricing.self, forKey: .pricing)
        architecture = try? container.decodeIfPresent(Architecture.self, forKey: .architecture)
        topProvider = try? container.decodeIfPresent(TopProvider.self, forKey: .topProvider)
    }

    public var inputModalities: [String] { architecture?.inputModalities ?? ["text"] }
    public var tokenizer: String? { architecture?.tokenizer }
    public var maxCompletionTokens: Int? { topProvider?.maxCompletionTokens }

    public var supportsTools: Bool { supportedParameters.contains("tools") }
    public var supportsStructuredOutputs: Bool { supportedParameters.contains("structured_outputs") || supportedParameters.contains("response_format") }
    public var supportsReasoning: Bool { reasoning != nil || supportedParameters.contains("reasoning") || supportedParameters.contains("include_reasoning") }
    public var supportsImages: Bool { inputModalities.contains("image") }

    /// The framework capabilities this model declares.
    public var capabilities: LanguageModelCapabilities {
        var list: [LanguageModelCapabilities.Capability] = []
        if supportsTools { list.append(.toolCalling) }
        if supportsStructuredOutputs { list.append(.guidedGeneration) }
        if supportsReasoning { list.append(.reasoning) }
        if supportsImages { list.append(.vision) }
        return LanguageModelCapabilities(list)
    }

    /// A context policy sized to this model's window.
    public func contextPolicy() -> ContextPolicy? {
        guard let contextLength, contextLength > 0 else { return nil }
        return ContextPolicy(contextTokens: contextLength)
    }
}

/// The OpenRouter model list, fetched once and cached on disk.
///
/// Use it to size a context policy, to declare the right capabilities, and to
/// refuse a reasoning effort a model does not take. The list changes often,
/// so the cache expires after a day.
public actor OpenRouterModelCatalog {
    public let configuration: OpenRouterConfiguration
    public let cacheURL: URL?
    public let cacheLifetime: TimeInterval
    private var models: [String: OpenRouterModelInfo] = [:]
    private var fetchedAt: Date?

    public init(configuration: OpenRouterConfiguration = OpenRouterConfiguration(), cacheURL: URL? = OpenRouterModelCatalog.defaultCacheURL, cacheLifetime: TimeInterval = 24 * 3600) {
        self.configuration = configuration
        self.cacheURL = cacheURL
        self.cacheLifetime = cacheLifetime
    }

    public static var defaultCacheURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Harness/openrouter-models.json")
    }

    /// Every model, from the cache when fresh, else from the network.
    public func all(forceRefresh: Bool = false) async throws -> [OpenRouterModelInfo] {
        if !forceRefresh, !models.isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < cacheLifetime {
            return models.values.sorted { $0.id < $1.id }
        }
        if !forceRefresh, let cached = loadCache() {
            return cached.values.sorted { $0.id < $1.id }
        }
        let fetched = try await fetch()
        return fetched.values.sorted { $0.id < $1.id }
    }

    /// One model's info, or nil when OpenRouter does not list it.
    public func info(for modelID: String) async throws -> OpenRouterModelInfo? {
        _ = try await all()
        return models[modelID]
    }

    /// A model value with capabilities and a sensible default effort taken from the catalog.
    public func makeModel(_ modelID: String, sessionID: String? = nil, defaultReasoningEffort: String? = nil) async throws -> OpenRouterLanguageModel {
        let info = try await info(for: modelID)
        var effort = defaultReasoningEffort
        if let effort, let supported = info?.reasoning?.supportedEfforts, !supported.contains(effort) {
            throw OpenRouterError.unsupportedEffort(model: modelID, effort: effort, supported: supported)
        }
        if effort == nil, info?.supportsReasoning == false { effort = nil }
        return OpenRouterLanguageModel(
            modelID: modelID,
            capabilities: info?.capabilities ?? LanguageModelCapabilities([.toolCalling, .guidedGeneration, .reasoning]),
            configuration: configuration,
            defaultReasoningEffort: effort,
            sessionID: sessionID
        )
    }

    // MARK: Fetching and caching

    static func decode(_ data: Data) throws -> [String: OpenRouterModelInfo] {
        struct Envelope: Decodable { let data: [OpenRouterModelInfo] }
        let list = try JSONDecoder().decode(Envelope.self, from: data).data
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func fetch() async throws -> [String: OpenRouterModelInfo] {
        var request = URLRequest(url: configuration.baseURL.appending(path: "models"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = try? configuration.resolveBearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in configuration.additionalHeaders { request.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OpenRouterErrorMapping.error(status: http.statusCode, body: data)
        }
        let decoded = try Self.decode(data)
        models = decoded
        fetchedAt = Date()
        if let cacheURL {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: [.atomic])
        }
        return decoded
    }

    private func loadCache() -> [String: OpenRouterModelInfo]? {
        guard let cacheURL, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
            let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < cacheLifetime,
            let data = try? Data(contentsOf: cacheURL), let decoded = try? Self.decode(data), !decoded.isEmpty
        else { return nil }
        models = decoded
        fetchedAt = modified
        return decoded
    }
}
