import Foundation
import FoundationModels

/// What a toolset receives when a session is built.
public struct AgentToolsetContext: Sendable {
    /// The session's model, for toolsets that run sub-agents.
    public let model: any LanguageModel
    /// The session's gate. Wrap each tool with it to put the tool under the permission policy.
    public let gate: ToolGate
    public let log: SessionLog
    public let directory: SessionDirectory
}

/// A group of tools an agent works with, and the instructions that go with them.
///
/// The runner asks every toolset in the configuration for its tools when it
/// builds a session. A coding agent adds `CodingToolset`; an app adds toolsets
/// for whatever its agent works on. A toolset gates its own tools through
/// `context.gate`, so it decides which calls answer to the permission policy.
public protocol AgentToolset: Sendable {
    func tools(in context: AgentToolsetContext) throws -> [any Tool]
    /// Text placed in the instructions after the tool definitions. Read once, when the session is built.
    var instructions: String? { get }
    /// Facts saved in the session manifest so a later launch can resume, such as the folder the session worked in.
    var manifestMetadata: [String: String] { get }
}

extension AgentToolset {
    public var instructions: String? { nil }
    public var manifestMetadata: [String: String] { [:] }
}

/// Tools the app supplies, passed to the session as they are, without the gate.
public struct ToolList: AgentToolset {
    public let list: [any Tool]

    public init(_ list: [any Tool]) {
        self.list = list
    }

    public func tools(in context: AgentToolsetContext) -> [any Tool] {
        list
    }
}
