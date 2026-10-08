import Foundation
import FoundationModels
import Harness

/// A headless runner: one prompt, the full harness, the event stream on stdout.
///
/// ```sh
/// harness run --workspace . "Summarize this repository."
/// harness run --workspace . --json --approve "Add a README."
/// ```
@main
struct HarnessCLI {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            if options.showsHelp {
                print(Options.usage)
                return
            }
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: options.workspace))
        let sessionRoot: URL
        if let explicit = options.sessionRoot {
            sessionRoot = URL(fileURLWithPath: explicit)
        } else {
            sessionRoot = try SessionDirectory.defaultRoot()
        }
        let directory = try SessionDirectory(root: sessionRoot)
        let log = try directory.makeLog()
        let memoryRoot: URL
        if let explicit = options.memory {
            memoryRoot = URL(fileURLWithPath: explicit)
        } else {
            memoryRoot = try MemoryDirectory.defaultRoot(project: workspace.root.lastPathComponent)
        }
        let memory = try MemoryDirectory(root: memoryRoot)
        var skillRoots = SkillCatalog.conventionalRoots(workspace: workspace)
        if let extra = options.skills { skillRoots.append(URL(fileURLWithPath: extra)) }
        let skills = SkillCatalog.discover(in: skillRoots)

        let policy: PermissionPolicy = options.approve ? .allowAll : .default
        let gate = ToolGate(policy: policy, prompter: options.approve ? nil : ConsolePrompter(), shaper: ToolResultShaper(outputsDirectory: directory.outputsURL), log: log)
        let model = OpenRouterLanguageModel(modelID: options.model, defaultReasoningEffort: options.effort, sessionID: directory.sessionID)
        let coding = CodingTools(workspace: workspace)
        let explorer = SubagentDefinition(
            name: "explorer",
            description: "Read-only exploration of the workspace: finds files, reads code, answers questions about it.",
            model: model,
            instructions: "You explore a codebase and report back. You can only read. Be concrete: cite paths and line ranges. Reply with the findings only.",
            tools: [gate.gate(coding.read), gate.gate(coding.shell)]
        )
        var tools = coding.gated(by: gate)
        tools += try MemoryTools(directory: memory).gated(by: gate)
        tools.append(gate.gate(TaskTool(agents: [explorer], log: log)))

        let printer = ConsolePrinter(json: options.json)
        let profile = RunnerProfile(
            model: model,
            tools: tools,
            instructionFiles: InstructionFiles.load(workspace: workspace),
            skills: skills,
            memory: memory,
            directory: directory,
            log: log,
            printer: printer
        )
        await log.record(.sessionStarted(sessionID: directory.sessionID, modelID: options.model))
        await printer.emit(.sessionStarted(sessionID: directory.sessionID, modelID: options.model))

        let session = LanguageModelSession(profile: profile)
        let stream = session.streamResponse(to: options.prompt)
        var printed = ""
        for try await snapshot in stream {
            let text = snapshot.content
            if text.hasPrefix(printed) {
                await printer.text(String(text.dropFirst(printed.count)))
            } else {
                await printer.text("\n" + text)
            }
            printed = text
        }
        await printer.finish(usage: session.usage, directory: directory)
        await log.close()
    }
}

struct RunnerProfile: LanguageModelSession.DynamicProfile, Sendable {
    let model: OpenRouterLanguageModel
    let tools: [any Tool]
    let instructionFiles: InstructionFiles
    let skills: SkillCatalog
    let memory: MemoryDirectory
    let directory: SessionDirectory
    let log: SessionLog
    let printer: ConsolePrinter

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions("""
                You are a coding agent working in the workspace at \(directory.url.deletingLastPathComponent().path == "" ? "." : "the given folder"). Use the tools to read before you change anything, keep diffs scoped, and verify your work by running the project's checks. When you finish, state what you changed and what you did not do.
                """)
            tools
            if let instructions = instructionFiles.instructions {
                instructions
            }
            SkillsInstructions(catalog: skills)
            MemoryInstructions(directory: memory)
        }
        .model(model)
        .logging(to: log)
        .persistingTranscript(in: directory, log: log)
        .onToolCall { call in await printer.emit(.toolCall(Transcript(entries: [.toolCalls(Transcript.ToolCalls([call]))]))) }
        .onToolOutput { _, output in await printer.emit(.toolOutput(Transcript(entries: [.toolOutput(output)]))) }
        .onReasoning { reasoning in await printer.emit(.reasoning(Transcript(entries: [.reasoning(reasoning)]))) }
    }
}

/// Prints events as readable lines, or as JSON lines for a machine to read.
actor ConsolePrinter {
    let json: Bool
    private var lineOpen = false
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(json: Bool) {
        self.json = json
    }

    func text(_ delta: String) {
        guard !delta.isEmpty else { return }
        if json {
            write(#"{"type":"text","delta":\#(Self.quote(delta))}"# + "\n")
        } else {
            write(delta)
            lineOpen = !delta.hasSuffix("\n")
        }
    }

    func emit(_ event: HarnessEvent) {
        if json {
            if let data = try? encoder.encode(LogRecord(sequence: 0, timestamp: Date(), event: event)) {
                write(String(decoding: data, as: UTF8.self) + "\n")
            }
            return
        }
        if lineOpen { write("\n"); lineOpen = false }
        switch event {
        case .sessionStarted(let sessionID, let modelID):
            write("session \(sessionID) model \(modelID ?? "?")\n")
        case .toolCall(let transcript):
            for case .toolCalls(let calls) in transcript {
                for call in calls { write("▸ \(call.toolName) \(call.arguments.jsonString.prefix(200))\n") }
            }
        case .toolOutput(let transcript):
            for case .toolOutput(let output) in transcript {
                let text = output.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
                let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
                write("  ↳ \(firstLine.prefix(160))\(text.count > 160 ? "…" : "")\n")
            }
        case .reasoning(let transcript):
            for case .reasoning(let reasoning) in transcript {
                let text = reasoning.segments.compactMap { if case .text(let t) = $0 { t.content } else { nil } }.joined()
                if !text.isEmpty { write("· \(text.prefix(200).replacingOccurrences(of: "\n", with: " "))\n") }
            }
        default:
            break
        }
    }

    func finish(usage: LanguageModelSession.Usage, directory: SessionDirectory) {
        if json {
            write(#"{"type":"done","inputTokens":\#(usage.input.totalTokenCount),"cachedTokens":\#(usage.input.cachedTokenCount),"outputTokens":\#(usage.output.totalTokenCount),"session":\#(Self.quote(directory.url.path))}"# + "\n")
        } else {
            if lineOpen { write("\n") }
            write("\n[\(usage.input.totalTokenCount) in, \(usage.input.cachedTokenCount) cached, \(usage.output.totalTokenCount) out · \(directory.url.path)]\n")
        }
    }

    private func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private static func quote(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }
}

/// Asks on the terminal. Denies when stdin is not a terminal.
struct ConsolePrompter: PermissionPrompter {
    func confirm(_ invocation: ToolInvocation) async -> PermissionResponse {
        guard isatty(STDIN_FILENO) != 0 else { return .deny }
        let question = "\nAllow \(invocation.toolName) \(invocation.argumentsJSON.prefix(300))? [y]es / [a]lways / [N]o: "
        let answer = await Task.detached {
            FileHandle.standardOutput.write(Data(question.utf8))
            return readLine()?.lowercased() ?? ""
        }.value
        switch answer {
        case "y", "yes": return .allowOnce
        case "a", "always": return .allowAlways
        default: return .deny
        }
    }
}

struct Options {
    var workspace = FileManager.default.currentDirectoryPath
    var model = "anthropic/claude-sonnet-4.6"
    var effort: String? = nil
    var sessionRoot: String? = nil
    var memory: String? = nil
    var skills: String? = nil
    var approve = false
    var json = false
    var showsHelp = false
    var prompt = ""

    static let usage = """
        usage: harness run [options] "<prompt>"

        options:
          --workspace <dir>      folder the agent may work in (default: current directory)
          --model <id>           OpenRouter model slug (default: anthropic/claude-sonnet-4.6)
          --effort <level>       reasoning effort: none, low, medium, high, xhigh, max
          --session-root <dir>   where session folders are created (default: Application Support)
          --memory <dir>         memory directory (default: Application Support, per workspace name)
          --skills <dir>         an extra skills folder to scan
          --approve              allow every tool call without asking
          --json                 print JSON lines instead of readable text
          --help

        The OpenRouter key is read from OPENROUTER_API_KEY.
        """

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        if rest.first == "run" { rest = rest.dropFirst() }
        var positional: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": options.showsHelp = true
            case "--approve": options.approve = true
            case "--json": options.json = true
            case "--workspace": options.workspace = try value(&rest, for: argument)
            case "--model": options.model = try value(&rest, for: argument)
            case "--effort": options.effort = try value(&rest, for: argument)
            case "--session-root": options.sessionRoot = try value(&rest, for: argument)
            case "--memory": options.memory = try value(&rest, for: argument)
            case "--skills": options.skills = try value(&rest, for: argument)
            default:
                if argument.hasPrefix("--") { throw ParseError(message: "unknown option \(argument)\n\n\(usage)") }
                positional.append(argument)
            }
        }
        options.prompt = positional.joined(separator: " ")
        if !options.showsHelp, options.prompt.isEmpty { throw ParseError(message: "a prompt is required\n\n\(usage)") }
        return options
    }

    private static func value(_ rest: inout ArraySlice<String>, for option: String) throws -> String {
        guard let value = rest.popFirst() else { throw ParseError(message: "\(option) needs a value") }
        return value
    }
}
