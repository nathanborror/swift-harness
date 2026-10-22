import Foundation
import FoundationModels

/// What a tool does to the world. Mirrors the MCP annotation vocabulary so
/// permission rules can reason about a tool without knowing its name.
public struct ToolAnnotations: Sendable, Equatable, Codable {
    /// The tool changes nothing. Read-only tools are allowed by default.
    public var isReadOnly: Bool
    /// The tool can delete or overwrite in a way that is hard to reverse.
    public var isDestructive: Bool
    /// The tool reaches the outside world: network, other apps, other devices.
    public var isOpenWorld: Bool

    public init(isReadOnly: Bool = false, isDestructive: Bool = false, isOpenWorld: Bool = false) {
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
        self.isOpenWorld = isOpenWorld
    }

    public static let readOnly = ToolAnnotations(isReadOnly: true)
    public static let mutating = ToolAnnotations()
    public static let destructive = ToolAnnotations(isDestructive: true)
}

/// A tool that describes its side effects. The gate reads these when it has no
/// rule naming the tool.
public protocol AnnotatedTool: Tool {
    var annotations: ToolAnnotations { get }
}

/// One tool call as the permission layer sees it.
public struct ToolInvocation: Sendable {
    public let toolName: String
    public let arguments: GeneratedContent
    public let annotations: ToolAnnotations?

    public init(toolName: String, arguments: GeneratedContent, annotations: ToolAnnotations?) {
        self.toolName = toolName
        self.arguments = arguments
        self.annotations = annotations
    }

    public var argumentsJSON: String { arguments.jsonString }

    /// A string argument by name, for rules that inspect commands or paths.
    public func string(_ property: String) -> String? {
        try? arguments.value(String.self, forProperty: property)
    }
}

public enum PermissionDecision: String, Sendable, Codable, Equatable {
    case allow
    case ask
    case deny
}

/// A predicate and the decision it produces. First matching rule wins.
public struct PermissionRule: Sendable {
    public let name: String
    public let decision: PermissionDecision
    public let reason: String?
    let matcher: @Sendable (ToolInvocation) -> Bool

    public init(name: String, decision: PermissionDecision, reason: String? = nil, matches matcher: @escaping @Sendable (ToolInvocation) -> Bool) {
        self.name = name
        self.decision = decision
        self.reason = reason
        self.matcher = matcher
    }

    public func matches(_ invocation: ToolInvocation) -> Bool {
        matcher(invocation)
    }

    /// Matches a tool by name.
    public static func tool(_ toolName: String, _ decision: PermissionDecision, reason: String? = nil) -> PermissionRule {
        PermissionRule(name: "tool:\(toolName)", decision: decision, reason: reason) { $0.toolName == toolName }
    }

    /// Matches a tool by name when a string argument satisfies a predicate.
    public static func tool(_ toolName: String, where property: String, satisfies predicate: @escaping @Sendable (String) -> Bool, _ decision: PermissionDecision, reason: String? = nil) -> PermissionRule {
        PermissionRule(name: "tool:\(toolName)[\(property)]", decision: decision, reason: reason) {
            guard $0.toolName == toolName, let value = $0.string(property) else { return false }
            return predicate(value)
        }
    }

    /// Matches tools annotated as read-only.
    public static func readOnly(_ decision: PermissionDecision) -> PermissionRule {
        PermissionRule(name: "annotation:readOnly", decision: decision) { $0.annotations?.isReadOnly == true }
    }

    /// Matches tools annotated as destructive.
    public static func destructive(_ decision: PermissionDecision, reason: String? = nil) -> PermissionRule {
        PermissionRule(name: "annotation:destructive", decision: decision, reason: reason) { $0.annotations?.isDestructive == true }
    }

    /// Matches tools annotated as reaching the outside world.
    public static func openWorld(_ decision: PermissionDecision, reason: String? = nil) -> PermissionRule {
        PermissionRule(name: "annotation:openWorld", decision: decision, reason: reason) { $0.annotations?.isOpenWorld == true }
    }
}

/// An ordered rule list with a fallback. Read-only tools are allowed and
/// everything else asks, until you say otherwise.
public struct PermissionPolicy: Sendable {
    public var rules: [PermissionRule]
    public var fallback: PermissionDecision

    public init(rules: [PermissionRule] = [], fallback: PermissionDecision = .ask) {
        self.rules = rules
        self.fallback = fallback
    }

    public static let `default` = PermissionPolicy(rules: [.readOnly(.allow)], fallback: .ask)
    public static let allowAll = PermissionPolicy(rules: [], fallback: .allow)
    public static let readOnlyOnly = PermissionPolicy(rules: [.readOnly(.allow)], fallback: .deny)

    public struct Evaluation: Sendable, Equatable {
        public let decision: PermissionDecision
        public let rule: String?
        public let reason: String?
    }

    public func evaluate(_ invocation: ToolInvocation) -> Evaluation {
        if let rule = rules.first(where: { $0.matches(invocation) }) {
            return Evaluation(decision: rule.decision, rule: rule.name, reason: rule.reason)
        }
        return Evaluation(decision: fallback, rule: nil, reason: nil)
    }
}

/// Answers an `ask` decision, normally by showing the person a dialog.
public protocol PermissionPrompter: Sendable {
    func confirm(_ invocation: ToolInvocation) async -> PermissionResponse
}

public enum PermissionResponse: Sendable, Equatable {
    case allowOnce
    /// Allow this tool for the rest of the session.
    case allowAlways
    case deny
}
