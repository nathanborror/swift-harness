import Foundation
import FoundationModels

/// Receives what an agent run produces as it happens.
public protocol AgentObserver: Sendable {
    func text(_ delta: String) async
    func event(_ event: HarnessEvent) async
}

/// Everything needed to assemble one agent session: the model, the workspace,
/// where sessions and memory live, which skills to load, and how tools are gated.
public struct AgentConfiguration: Sendable {
    public var model: any LanguageModel
    public var workspace: Workspace
    public var sessionRoot: URL
    public var memory: MemoryDirectory?
    public var skillRoots: [URL]
    public var policy: PermissionPolicy
    public var prompter: (any PermissionPrompter)?
    public var contextPolicy: ContextPolicy?
    public var instructions: String
    /// Adds a read-only explorer sub-agent on the same model.
    public var includesExplorer: Bool
    public var sessionID: String?
    /// Further tools the app supplies, gated like the rest.
    public var additionalTools: [any Tool]

    public static let defaultInstructions = """
        You are a coding agent working in a workspace. Use the tools: read before you change anything, keep diffs scoped, and verify your work by running the project's checks where they exist. When you finish, state what you changed and what you did not do.
        """

    public init(
        model: any LanguageModel,
        workspace: Workspace,
        sessionRoot: URL,
        memory: MemoryDirectory? = nil,
        skillRoots: [URL] = [],
        policy: PermissionPolicy = .default,
        prompter: (any PermissionPrompter)? = nil,
        contextPolicy: ContextPolicy? = nil,
        instructions: String = AgentConfiguration.defaultInstructions,
        includesExplorer: Bool = true,
        sessionID: String? = nil,
        additionalTools: [any Tool] = []
    ) {
        self.model = model
        self.workspace = workspace
        self.sessionRoot = sessionRoot
        self.memory = memory
        self.skillRoots = skillRoots
        self.policy = policy
        self.prompter = prompter
        self.contextPolicy = contextPolicy
        self.instructions = instructions
        self.includesExplorer = includesExplorer
        self.sessionID = sessionID
        self.additionalTools = additionalTools
    }
}

public struct AgentRunResult: Sendable {
    public let response: String
    public let directory: SessionDirectory
    public let usage: LanguageModelSession.Usage
    /// Tool names in the order the model called them.
    public let toolCalls: [String]
    public let duration: TimeInterval
    public let transcript: Transcript
}

/// Assembles a session from a configuration and runs one prompt through it.
public struct AgentRunner: Sendable {
    public let configuration: AgentConfiguration

    public init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    /// A session with everything wired, ready for one or many prompts.
    public struct Assembly: Sendable {
        public let session: LanguageModelSession
        public let directory: SessionDirectory
        public let log: SessionLog
        public let gate: ToolGate
    }

    /// Builds the session. Pass a saved history to resume an earlier session.
    public func makeSession(history: Transcript? = nil, observer: (any AgentObserver)? = nil) async throws -> Assembly {
        let configuration = self.configuration
        let directory = try SessionDirectory(root: configuration.sessionRoot, sessionID: configuration.sessionID ?? SessionDirectory.makeSessionID())
        let log = try directory.makeLog()
        let gate = ToolGate(policy: configuration.policy, prompter: configuration.prompter, shaper: ToolResultShaper(outputsDirectory: directory.outputsURL), log: log)
        let coding = CodingTools(workspace: configuration.workspace)
        var tools = coding.gated(by: gate)
        if let memory = configuration.memory {
            tools += try MemoryTools(directory: memory).gated(by: gate)
        }
        if configuration.includesExplorer {
            var explorerTools: [any Tool] = [gate.gate(coding.read)]
            #if os(macOS)
            explorerTools.append(gate.gate(coding.shell))
            #endif
            let explorer = SubagentDefinition(
                name: "explorer",
                description: "Read-only exploration of the workspace: finds files, reads code, answers questions about it.",
                model: configuration.model,
                instructions: "You explore a codebase and report back. You can only read. Be concrete: cite paths and line ranges. Reply with the findings only.",
                tools: explorerTools
            )
            tools.append(gate.gate(TaskTool(agents: [explorer], log: log)))
        }
        tools += configuration.additionalTools

        let profile = AgentProfile(
            configuration: configuration,
            tools: tools,
            instructionFiles: InstructionFiles.load(workspace: configuration.workspace),
            skills: SkillCatalog.discover(in: configuration.skillRoots),
            directory: directory,
            log: log,
            observer: observer
        )
        let modelID = (configuration.model as? OpenRouterLanguageModel)?.modelID
        if directory.loadManifest() == nil {
            try? directory.saveManifest(.init(workspacePath: configuration.workspace.root.path, modelID: modelID))
        }
        await log.record(.sessionStarted(sessionID: directory.sessionID, modelID: modelID))
        await observer?.event(.sessionStarted(sessionID: directory.sessionID, modelID: modelID))
        let session = LanguageModelSession(profile: profile, history: history.map { Array($0.history) } ?? [])
        return Assembly(session: session, directory: directory, log: log, gate: gate)
    }

    public func run(prompt: String, observer: (any AgentObserver)? = nil) async throws -> AgentRunResult {
        let assembly = try await makeSession(observer: observer)
        let started = Date()
        var printed = ""
        var final = ""
        do {
            for try await snapshot in assembly.session.streamResponse(to: prompt) {
                let text = snapshot.content
                if text.hasPrefix(printed) {
                    await observer?.text(String(text.dropFirst(printed.count)))
                } else {
                    await observer?.text("\n" + text)
                }
                printed = text
                final = text
            }
        } catch {
            await assembly.log.record(.note("Run failed: \(error.localizedDescription)"))
            await assembly.log.close()
            throw error
        }
        await assembly.log.close()
        let toolCalls = assembly.session.transcript.flatMap { entry -> [String] in
            if case .toolCalls(let calls) = entry { return calls.map(\.toolName) }
            return []
        }
        return AgentRunResult(response: final, directory: assembly.directory, usage: assembly.session.usage, toolCalls: toolCalls, duration: Date().timeIntervalSince(started), transcript: assembly.session.transcript)
    }
}

struct AgentProfile: LanguageModelSession.DynamicProfile, Sendable {
    let configuration: AgentConfiguration
    let tools: [any Tool]
    let instructionFiles: InstructionFiles
    let skills: SkillCatalog
    let directory: SessionDirectory
    let log: SessionLog
    let observer: (any AgentObserver)?

    var body: some LanguageModelSession.DynamicProfile {
        base
            .model(configuration.model)
            .logging(to: log)
            .persistingTranscript(in: directory, log: log)
            .onPrompt { prompt in await observer?.event(.prompt(Transcript(entries: [.prompt(prompt)]))) }
            .onResponse { response in await observer?.event(.response(Transcript(entries: [.response(response)]))) }
            .onToolCall { call in await observer?.event(.toolCall(Transcript(entries: [.toolCalls(Transcript.ToolCalls([call]))]))) }
            .onToolOutput { _, output in await observer?.event(.toolOutput(Transcript(entries: [.toolOutput(output)]))) }
            .onReasoning { reasoning in await observer?.event(.reasoning(Transcript(entries: [.reasoning(reasoning)]))) }
    }

    private var base: some LanguageModelSession.DynamicProfile {
        let profile = Profile {
            Instructions(configuration.instructions)
            tools
            if let instructions = instructionFiles.instructions {
                instructions
            }
            SkillsInstructions(catalog: skills)
            if let memory = configuration.memory {
                MemoryInstructions(directory: memory)
            }
        }
        if let policy = configuration.contextPolicy {
            return LanguageModelSession.AnyDynamicProfile(profile.managingContext(policy: policy, summarizer: configuration.model, directory: directory, memory: configuration.memory, log: log))
        }
        return LanguageModelSession.AnyDynamicProfile(profile)
    }
}
