import Foundation
import FoundationModels

public enum ToolGateError: Error, Sendable, LocalizedError, Equatable {
    /// Too many denials in a row, or in total. The turn stops so a person can look.
    case escalation(reason: String)

    public var errorDescription: String? {
        switch self {
        case .escalation(let reason): "Tool use was stopped: \(reason)"
        }
    }
}

/// The permission and result-shaping layer for tools.
///
/// Wrap any tool with `gate(_:)`. Each call is checked against the policy, an
/// `ask` goes to the prompter, and a denial comes back to the model as tool
/// output rather than an error, so the loop keeps going. Repeated denials
/// escalate by throwing, which ends the turn.
public actor ToolGate {
    public struct Limits: Sendable, Equatable {
        public var maxConsecutiveDenials: Int
        public var maxTotalDenials: Int

        public init(maxConsecutiveDenials: Int = 3, maxTotalDenials: Int = 20) {
            self.maxConsecutiveDenials = maxConsecutiveDenials
            self.maxTotalDenials = maxTotalDenials
        }
    }

    public private(set) var policy: PermissionPolicy
    public var shaper: ToolResultShaper
    public var limits: Limits
    private let prompter: (any PermissionPrompter)?
    private let log: SessionLog?
    private var consecutiveDenials = 0
    private var totalDenials = 0

    public init(
        policy: PermissionPolicy = .default,
        prompter: (any PermissionPrompter)? = nil,
        shaper: ToolResultShaper = ToolResultShaper(),
        limits: Limits = Limits(),
        log: SessionLog? = nil
    ) {
        self.policy = policy
        self.prompter = prompter
        self.shaper = shaper
        self.limits = limits
        self.log = log
    }

    /// Wraps a tool so every call passes through this gate.
    public nonisolated func gate<Base: Tool>(_ tool: Base) -> Gated<Base> where Base.Arguments: ConvertibleToGeneratedContent, Base.Output: ConvertibleToGeneratedContent {
        Gated(base: tool, gate: self)
    }

    /// Adds a rule at the front of the policy, ahead of existing rules.
    public func prepend(_ rule: PermissionRule) {
        policy.rules.insert(rule, at: 0)
    }

    public enum Authorization: Sendable, Equatable {
        case allowed
        case denied(reason: String)
    }

    public func authorize(_ invocation: ToolInvocation) async throws -> Authorization {
        let evaluation = policy.evaluate(invocation)
        var decision = evaluation.decision
        var reason = evaluation.reason
        var rule = evaluation.rule

        if decision == .ask {
            if let prompter {
                switch await prompter.confirm(invocation) {
                case .allowOnce:
                    decision = .allow
                    rule = "prompt"
                case .allowAlways:
                    decision = .allow
                    rule = "prompt:always"
                    prepend(.tool(invocation.toolName, .allow, reason: "approved for this session"))
                case .deny:
                    decision = .deny
                    rule = "prompt"
                    reason = "the person declined"
                }
            } else {
                decision = .deny
                reason = "this action needs confirmation and no one is available to give it"
            }
        }

        await log?.record(.permission(
            tool: invocation.toolName,
            decision: decision,
            rule: rule,
            reason: reason,
            arguments: String(invocation.argumentsJSON.prefix(2_000))
        ))

        switch decision {
        case .allow, .ask:
            consecutiveDenials = 0
            return .allowed
        case .deny:
            consecutiveDenials += 1
            totalDenials += 1
            if consecutiveDenials >= limits.maxConsecutiveDenials || totalDenials >= limits.maxTotalDenials {
                let why = "\(consecutiveDenials) consecutive and \(totalDenials) total denied tool calls"
                await log?.record(.escalation(reason: why))
                throw ToolGateError.escalation(reason: why)
            }
            return .denied(reason: reason ?? "not permitted by policy")
        }
    }

    func shapeResult(_ output: String, toolName: String, callID: String, duration: TimeInterval, failed: Bool) async -> String {
        let shaped = shaper.shape(output, toolName: toolName, callID: callID)
        await log?.record(.toolResult(
            tool: toolName,
            characters: shaped.originalCharacters,
            truncated: shaped.truncated,
            offloadedTo: shaped.offloadedTo?.path,
            duration: duration,
            failed: failed
        ))
        return shaped.text
    }
}

/// A tool whose calls go through a `ToolGate`. Same name, description, and
/// schema as the wrapped tool, so the model sees no difference.
public struct Gated<Base: Tool>: Tool where Base.Arguments: ConvertibleToGeneratedContent, Base.Output: ConvertibleToGeneratedContent {
    public typealias Arguments = Base.Arguments
    public typealias Output = String

    public let base: Base
    let gate: ToolGate

    public var name: String { base.name }
    public var description: String { base.description }
    public var parameters: GenerationSchema { base.parameters }
    public var includesSchemaInInstructions: Bool { base.includesSchemaInInstructions }

    @concurrent public func call(arguments: Base.Arguments) async throws -> String {
        let annotations = (base as? any AnnotatedTool)?.annotations
        let invocation = ToolInvocation(toolName: base.name, arguments: arguments.generatedContent, annotations: annotations)
        let callID = UUID().uuidString

        switch try await gate.authorize(invocation) {
        case .denied(let reason):
            return "Denied: \(base.name) was not run because \(reason). Do not retry the same call. Explain what you needed, or choose a different approach."
        case .allowed:
            break
        }

        let started = Date()
        do {
            let output = try await base.call(arguments: arguments)
            let text = Self.text(from: output)
            return await gate.shapeResult(text, toolName: base.name, callID: callID, duration: Date().timeIntervalSince(started), failed: false)
        } catch {
            let text = "Error: \(base.name) failed: \(error.localizedDescription)"
            return await gate.shapeResult(text, toolName: base.name, callID: callID, duration: Date().timeIntervalSince(started), failed: true)
        }
    }

    private static func text(from output: Base.Output) -> String {
        if let string = output as? String { return string }
        let content = output.generatedContent
        if let string = try? content.value(String.self) { return string }
        return content.jsonString
    }
}
