import Foundation
import FoundationModels

/// A kind of sub-agent the model may delegate to: a model, instructions, and
/// a tool set, usually narrower than the parent's.
public struct SubagentDefinition: Sendable {
    public let name: String
    /// Shown to the parent model so it can choose the right agent.
    public let description: String
    public let model: any LanguageModel
    public let instructions: String
    public let tools: [any Tool]
    /// Tool calls the sub-agent may make in one run before it is stopped.
    public let maximumToolCalls: Int

    public init(name: String, description: String, model: any LanguageModel, instructions: String, tools: [any Tool], maximumToolCalls: Int = 50) {
        self.name = name
        self.description = description
        self.model = model
        self.instructions = instructions
        self.tools = tools
        self.maximumToolCalls = maximumToolCalls
    }
}

public enum SubagentError: Error, Sendable, LocalizedError, Equatable {
    case toolCallLimit(Int)

    public var errorDescription: String? {
        switch self {
        case .toolCallLimit(let limit): "The sub-agent reached its limit of \(limit) tool calls and was stopped."
        }
    }
}

/// Delegates a task to a sub-agent in a fresh session and returns its final reply.
///
/// The brief is the sub-agent's whole context, so the parent is told to write
/// it as if nothing else were known. Exploration, failed attempts, and raw tool
/// output stay in the sub-agent's window; only the final text comes back.
public struct TaskTool: AnnotatedTool {
    @Generable(description: "Delegate a task to a sub-agent.")
    public struct Arguments {
        @Guide(description: "The sub-agent to use, by name from the tool description")
        public var agent: String
        @Guide(description: "The complete brief: the goal, what is already known, and the shape of the answer wanted. The sub-agent sees nothing else.")
        public var prompt: String
        @Guide(description: "A short label for what this task is, for display")
        public var description: String?
    }

    public let name = "task"
    public let description: String
    public let annotations: ToolAnnotations = .readOnly
    let definitions: [String: SubagentDefinition]
    let log: SessionLog?

    public init(agents: [SubagentDefinition], log: SessionLog? = nil) {
        self.definitions = Dictionary(agents.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        self.log = log
        let catalog = agents.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        self.description = "Runs a task in a separate session with its own context and returns only the final reply. Use it for research or exploration whose intermediate output would crowd this conversation. Write the prompt as the sub-agent's only context. Available agents:\n\(catalog)"
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let definition = definitions[arguments.agent] else {
            return "No sub-agent named \"\(arguments.agent)\". Available: \(definitions.keys.sorted().joined(separator: ", "))."
        }
        let counter = ToolCallCounter(limit: definition.maximumToolCalls)
        let session = LanguageModelSession(profile: SubagentProfile(definition: definition, counter: counter))
        let started = Date()
        do {
            let response = try await session.respond(to: arguments.prompt)
            await log?.record(.subagent(
                name: definition.name,
                description: arguments.description,
                characters: response.content.count,
                inputTokens: session.usage.input.totalTokenCount,
                outputTokens: session.usage.output.totalTokenCount,
                duration: Date().timeIntervalSince(started),
                failed: false
            ))
            return response.content
        } catch {
            // The framework wraps an error thrown from a lifecycle hook in ToolCallError.
            let error = (error as? LanguageModelSession.ToolCallError)?.underlyingError ?? error
            await log?.record(.subagent(
                name: definition.name,
                description: arguments.description,
                characters: 0,
                inputTokens: session.usage.input.totalTokenCount,
                outputTokens: session.usage.output.totalTokenCount,
                duration: Date().timeIntervalSince(started),
                failed: true
            ))
            throw error
        }
    }
}

struct SubagentProfile: LanguageModelSession.DynamicProfile, Sendable {
    let definition: SubagentDefinition
    let counter: ToolCallCounter

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(definition.instructions)
            definition.tools
        }
        .model(definition.model)
        .onToolCall { try await counter.count() }
    }
}

actor ToolCallCounter {
    let limit: Int
    private(set) var calls = 0

    init(limit: Int) {
        self.limit = limit
    }

    func count() throws {
        calls += 1
        if calls > limit { throw SubagentError.toolCallLimit(limit) }
    }
}
