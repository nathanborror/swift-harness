import Foundation
import FoundationModels

/// A coding agent's toolset for one workspace: read, edit, and write, the
/// shell on macOS, a read-only explorer sub-agent, and the workspace's
/// instruction files such as `AGENTS.md`.
public struct CodingToolset: AgentToolset {
    public let workspace: Workspace
    public var limits: CodingToolContext.Limits
    /// Where background shell output goes. Background commands are off without it.
    public var backgroundOutputs: URL?
    /// Adds a read-only explorer sub-agent on the session's model.
    public var includesExplorer: Bool

    /// The manifest key holding the workspace path, so a later launch can resume in the same folder.
    public static let workspaceMetadataKey = "workspace"

    public init(workspace: Workspace, limits: CodingToolContext.Limits = CodingToolContext.Limits(), backgroundOutputs: URL? = nil, includesExplorer: Bool = true) {
        self.workspace = workspace
        self.limits = limits
        self.backgroundOutputs = backgroundOutputs
        self.includesExplorer = includesExplorer
    }

    public func tools(in context: AgentToolsetContext) -> [any Tool] {
        let coding = CodingTools(workspace: workspace, limits: limits, backgroundOutputs: backgroundOutputs)
        var tools = coding.gated(by: context.gate)
        if includesExplorer {
            var explorerTools: [any Tool] = [context.gate.gate(coding.read)]
            #if os(macOS)
            explorerTools.append(context.gate.gate(coding.shell))
            #endif
            let explorer = SubagentDefinition(
                name: "explorer",
                description: "Read-only exploration of the workspace: finds files, reads code, answers questions about it.",
                model: context.model,
                instructions: "You explore a codebase and report back. You can only read. Be concrete: cite paths and line ranges. Reply with the findings only.",
                tools: explorerTools
            )
            tools.append(context.gate.gate(TaskTool(agents: [explorer], log: context.log)))
        }
        return tools
    }

    public var instructions: String? {
        let files = InstructionFiles.load(workspace: workspace)
        return files.isEmpty ? nil : files.rendered()
    }

    public var manifestMetadata: [String: String] {
        [Self.workspaceMetadataKey: workspace.root.path]
    }
}

extension AgentConfiguration {
    public static let codingInstructions = """
        You are a coding agent working in a workspace. Use the tools: read before you change anything, keep diffs scoped, and verify your work by running the project's checks where they exist. When you finish, state what you changed and what you did not do.
        """

    /// A coding agent in one workspace: the coding toolset first, then any others.
    public static func coding(
        model: any LanguageModel,
        workspace: Workspace,
        sessionRoot: URL,
        memory: MemoryDirectory? = nil,
        skillRoots: [URL] = [],
        policy: PermissionPolicy = .default,
        prompter: (any PermissionPrompter)? = nil,
        contextPolicy: ContextPolicy? = nil,
        instructions: String = AgentConfiguration.codingInstructions,
        includesExplorer: Bool = true,
        sessionID: String? = nil,
        toolsets: [any AgentToolset] = []
    ) -> AgentConfiguration {
        AgentConfiguration(
            model: model,
            instructions: instructions,
            toolsets: [CodingToolset(workspace: workspace, includesExplorer: includesExplorer)] + toolsets,
            sessionRoot: sessionRoot,
            memory: memory,
            skillRoots: skillRoots,
            policy: policy,
            prompter: prompter,
            contextPolicy: contextPolicy,
            sessionID: sessionID
        )
    }
}
