import Foundation
import FoundationModels

/// Receives what an agent run produces as it happens.
public protocol AgentObserver: Sendable {
    func text(_ delta: String) async
    func event(_ event: HarnessEvent) async
}

/// Everything needed to assemble one agent session: the model, what the agent
/// is for, the toolsets it works with, where sessions and memory live, which
/// skills to load, and how tools are gated.
public struct AgentConfiguration: Sendable {
    public var model: any LanguageModel
    /// What the agent is for. Placed first in the instructions.
    public var instructions: String
    /// The tools the agent works with, in order. Memory tools are added from `memory`.
    public var toolsets: [any AgentToolset]
    public var sessionRoot: URL
    public var memory: MemoryDirectory?
    public var skillRoots: [URL]
    public var policy: PermissionPolicy
    public var prompter: (any PermissionPrompter)?
    public var contextPolicy: ContextPolicy?
    public var sessionID: String?

    public init(
        model: any LanguageModel,
        instructions: String,
        toolsets: [any AgentToolset] = [],
        sessionRoot: URL,
        memory: MemoryDirectory? = nil,
        skillRoots: [URL] = [],
        policy: PermissionPolicy = .default,
        prompter: (any PermissionPrompter)? = nil,
        contextPolicy: ContextPolicy? = nil,
        sessionID: String? = nil
    ) {
        self.model = model
        self.instructions = instructions
        self.toolsets = toolsets
        self.sessionRoot = sessionRoot
        self.memory = memory
        self.skillRoots = skillRoots
        self.policy = policy
        self.prompter = prompter
        self.contextPolicy = contextPolicy
        self.sessionID = sessionID
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
        let context = AgentToolsetContext(model: configuration.model, gate: gate, log: log, directory: directory)
        var tools: [any Tool] = []
        for toolset in configuration.toolsets {
            tools += try toolset.tools(in: context)
        }
        if let memory = configuration.memory {
            tools += try MemoryTools(directory: memory).gated(by: gate)
        }
        let toolsetInstructions = configuration.toolsets.compactMap(\.instructions)

        let profile = AgentProfile(
            configuration: configuration,
            tools: tools,
            toolsetInstructions: toolsetInstructions.isEmpty ? nil : toolsetInstructions.joined(separator: "\n\n"),
            skills: SkillCatalog.discover(in: configuration.skillRoots),
            directory: directory,
            log: log,
            observer: observer
        )
        let modelID = (configuration.model as? OpenRouterLanguageModel)?.modelID
        if directory.loadManifest() == nil {
            let metadata = configuration.toolsets.reduce(into: [String: String]()) { merged, toolset in
                merged.merge(toolset.manifestMetadata) { _, later in later }
            }
            try? directory.saveManifest(.init(modelID: modelID, metadata: metadata))
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
    let toolsetInstructions: String?
    let skills: SkillCatalog
    let directory: SessionDirectory
    let log: SessionLog
    let observer: (any AgentObserver)?

    var body: some LanguageModelSession.DynamicProfile {
        base
            .model(configuration.model)
            // A turn that throws keeps its prompt and whatever it produced,
            // instead of being reverted as if it never happened; the
            // request builder closes any tool call left without an output.
            .transcriptErrorHandlingPolicy(.preserveTranscript)
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
            if let toolsetInstructions {
                Instructions(toolsetInstructions)
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
