import Foundation
import FoundationModels

/// A model served through OpenRouter's Responses API.
///
/// Pass one to `LanguageModelSession(model:)` and the session works exactly as
/// it does with Apple's models. Keep this value light: the executor does the work.
public struct OpenRouterLanguageModel: LanguageModel {
    public typealias Executor = OpenRouterExecutor

    /// The OpenRouter model slug, such as `anthropic/claude-sonnet-4.6`.
    public var modelID: String
    public var capabilities: LanguageModelCapabilities
    public var executorConfiguration: OpenRouterConfiguration

    /// Reasoning effort to send when a request carries no reasoning level.
    /// OpenRouter accepts `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`.
    public var defaultReasoningEffort: String?
    /// Sends a top-level `cache_control` marker so providers with explicit
    /// caching, such as Anthropic, cache the stable prefix. Verified to produce
    /// cache reads on the second call; the per-block form did not.
    public var usesPromptCache: Bool
    /// Sticky-routing key. Set it per session so follow-up turns reach the same
    /// provider and find its cache warm.
    public var sessionID: String?
    /// OpenRouter `provider` routing preferences, sent as is.
    public var providerPreferences: [String: JSONValue]
    /// Any further request fields, merged last. Use for plugins or experiments.
    public var additionalParameters: [String: JSONValue]
    /// Called once for every generation that completes, with what OpenRouter
    /// charged for it. Every session on this model reports here, including
    /// sub-agents and compaction summaries that share it, which is what lets
    /// an app account for calls that never reach a saved transcript. Called
    /// off the main actor, possibly from several requests at once.
    public var usageHandler: (@Sendable (OpenRouterUsage) -> Void)?

    public init(
        modelID: String,
        capabilities: LanguageModelCapabilities = LanguageModelCapabilities([.toolCalling, .guidedGeneration, .reasoning]),
        configuration: OpenRouterConfiguration = OpenRouterConfiguration(),
        defaultReasoningEffort: String? = nil,
        usesPromptCache: Bool = true,
        sessionID: String? = nil,
        providerPreferences: [String: JSONValue] = [:],
        additionalParameters: [String: JSONValue] = [:],
        usageHandler: (@Sendable (OpenRouterUsage) -> Void)? = nil
    ) {
        self.modelID = modelID
        self.capabilities = capabilities
        self.executorConfiguration = configuration
        self.defaultReasoningEffort = defaultReasoningEffort
        self.usesPromptCache = usesPromptCache
        self.sessionID = sessionID
        self.providerPreferences = providerPreferences
        self.additionalParameters = additionalParameters
        self.usageHandler = usageHandler
    }
}

/// One completed generation's usage, as OpenRouter reports it at the end of
/// the stream.
public struct OpenRouterUsage: Sendable, Equatable {
    /// OpenRouter's id for the generation, unique across requests.
    public var generationID: String?
    /// The model that answered, which may differ from the one asked for.
    public var model: String?
    /// Dollars. Nil when OpenRouter sent no cost.
    public var cost: Double?
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var reasoningTokens: Int

    public init(generationID: String?, model: String?, cost: Double?, inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0, reasoningTokens: Int = 0) {
        self.generationID = generationID
        self.model = model
        self.cost = cost
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }
}

/// Keys under which the executor stores opaque provider state in transcript metadata.
///
/// The Responses API asks clients to echo reasoning and tool-call items back
/// unmodified, and some providers attach encrypted state to them. The raw item is
/// kept here so replay is exact even after the harness has rendered the entry.
public enum OpenRouterMetadataKey {
    /// The full output item as JSON text.
    public static let item = "openrouter.item"
    /// The provider's item ID, on tool calls where the entry ID is the call ID.
    public static let itemID = "openrouter.item_id"
    /// The reasoning format tag, such as `anthropic-claude-v1`.
    public static let reasoningFormat = "openrouter.reasoning_format"
    public static let responseID = "openrouter.response_id"
    public static let generationID = "openrouter.generation_id"
    public static let model = "openrouter.model"
    public static let cost = "openrouter.cost"
    public static let cacheWriteTokens = "openrouter.cache_write_tokens"
    public static let incompleteReason = "openrouter.incomplete_reason"
}
