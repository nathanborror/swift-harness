import Foundation
import FoundationModels
import Harness
import HarnessCoding

/// A headless runner: one prompt or an eval suite, the full harness, the event stream on stdout.
///
/// ```sh
/// harness run --workspace . "Summarize this repository."
/// harness run --workspace . --json --approve "Add a README."
/// harness eval --tasks evals/tasks --trials 3
/// ```
@main
struct HarnessCLI {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            switch options.command {
            case .help: print(Options.usage)
            case .run: try await run(options)
            case .eval: try await eval(options)
            case .models: try await models(options)
            case .resume: try await resume(options)
            case .sessions: try sessions(options)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        try await run(options, resuming: nil)
    }

    static func resume(_ options: Options) async throws {
        let sessionRoot = try options.sessionRoot.map { URL(fileURLWithPath: $0) } ?? SessionDirectory.defaultRoot()
        let parts = options.prompt.split(separator: " ", maxSplits: 1).map(String.init)
        guard let reference = parts.first, let directory = SessionDirectory.find(reference, in: sessionRoot) else {
            throw Options.ParseError(message: "usage: harness resume <session id or path> \"<prompt>\"\nNo session found. List them with: harness sessions")
        }
        guard parts.count == 2, !parts[1].isEmpty else { throw Options.ParseError(message: "a prompt is required after the session id") }
        var options = options
        options.prompt = parts[1]
        if let manifest = directory.loadManifest() {
            if !options.workspaceWasSet, let workspace = manifest.metadata[CodingToolset.workspaceMetadataKey] { options.workspace = workspace }
            if !options.modelWasSet, let modelID = manifest.modelID { options.model = modelID }
        }
        try await run(options, resuming: directory)
    }

    static func sessions(_ options: Options) throws {
        let sessionRoot = try options.sessionRoot.map { URL(fileURLWithPath: $0) } ?? SessionDirectory.defaultRoot()
        let list = try SessionDirectory.list(in: sessionRoot)
        guard !list.isEmpty else { print("No sessions under \(sessionRoot.path)"); return }
        for directory in list.prefix(50) {
            let manifest = directory.loadManifest()
            let entries = (try? directory.loadTranscript())?.count ?? 0
            print("\(directory.sessionID)  \(manifest?.modelID ?? "-")  \(entries) entries  \(manifest?.metadata[CodingToolset.workspaceMetadataKey] ?? "")")
        }
    }

    static func run(_ options: Options, resuming existing: SessionDirectory?) async throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: options.workspace))
        let sessionRoot = try options.sessionRoot.map { URL(fileURLWithPath: $0) } ?? SessionDirectory.defaultRoot()
        let memoryRoot = try options.memory.map { URL(fileURLWithPath: $0) } ?? MemoryDirectory.defaultRoot(project: workspace.root.lastPathComponent)
        var skillRoots = SkillCatalog.conventionalRoots(workspace: workspace)
        if let extra = options.skills { skillRoots.append(URL(fileURLWithPath: extra)) }

        let resolved = try await resolveModel(options)
        var model = resolved.model
        model.sessionID = existing?.sessionID
        if let debug = options.debugDirectory { model.executorConfiguration.debugDirectory = URL(fileURLWithPath: debug) }
        let configuration = AgentConfiguration.coding(
            model: model,
            workspace: workspace,
            sessionRoot: existing?.url.deletingLastPathComponent() ?? sessionRoot,
            memory: try MemoryDirectory(root: memoryRoot),
            skillRoots: skillRoots,
            policy: options.approve ? .allowAll : .coding,
            prompter: options.approve ? nil : ConsolePrompter(),
            contextPolicy: resolved.contextPolicy,
            sessionID: existing?.sessionID
        )
        let printer = ConsolePrinter(json: options.json)
        let history = try existing?.loadTranscript()
        let assembly = try await AgentRunner(configuration: configuration).makeSession(history: history, observer: printer)
        var printed = ""
        for try await snapshot in assembly.session.streamResponse(to: options.prompt) {
            let text = snapshot.content
            await printer.text(text.hasPrefix(printed) ? String(text.dropFirst(printed.count)) : "\n" + text)
            printed = text
        }
        await assembly.log.close()
        await printer.finish(usage: assembly.session.usage, directory: assembly.directory)
    }

    static func eval(_ options: Options) async throws {
        let tasksRoot = URL(fileURLWithPath: options.tasks ?? "evals/tasks")
        let loaded = try EvalTask.loadAll(in: tasksRoot)
        let selected = options.only.map { only in loaded.filter { only.contains($0.task.name) } } ?? loaded
        guard !selected.isEmpty else { throw Options.ParseError(message: "no tasks found under \(tasksRoot.path)") }
        let outputRoot = URL(fileURLWithPath: options.output ?? "evals/results")
        let judge: (any LanguageModel)? = options.judgeModel.map { OpenRouterLanguageModel(modelID: $0, defaultReasoningEffort: "low") }
        let resolved = try await resolveModel(options)
        let runner = EvalRunner(outputRoot: outputRoot, judge: judge) { workspace, sessionRoot in
            AgentConfiguration.coding(
                model: resolved.model,
                workspace: workspace,
                sessionRoot: sessionRoot,
                memory: nil,
                skillRoots: [],
                policy: .allowAll,
                prompter: nil,
                contextPolicy: resolved.contextPolicy
            )
        }
        let json = options.json
        let report = try await runner.run(tasks: selected.map { ($0.task, $0.directory) }, trials: options.trials, model: options.model) { trial in
            if json {
                if let data = try? JSONEncoder().encode(trial) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                let mark = trial.passed ? "pass" : "FAIL"
                print("\(mark)  \(trial.task) #\(trial.trial)  \(String(format: "%.1fs", trial.duration))  \(trial.inputTokens) in / \(trial.outputTokens) out\(trial.error.map { "  \($0)" } ?? "")")
            }
        }
        if !json {
            print("")
            print(report.rendered())
        }
    }

    /// Builds the model from OpenRouter's catalog when it can be reached, so
    /// capabilities and the context window come from the listing. Offline, it
    /// falls back to defaults and says so.
    static func resolveModel(_ options: Options) async throws -> (model: OpenRouterLanguageModel, contextPolicy: ContextPolicy?) {
        let catalog = OpenRouterModelCatalog()
        let info: OpenRouterModelInfo?
        do {
            info = try await catalog.info(for: options.model)
        } catch {
            // Offline or the listing failed: run with defaults rather than refuse.
            FileHandle.standardError.write(Data("note: could not read OpenRouter's model list (\(error.localizedDescription)); using defaults\n".utf8))
            return (OpenRouterLanguageModel(modelID: options.model, defaultReasoningEffort: options.effort), options.contextTokens.map { ContextPolicy(contextTokens: $0) })
        }
        if info == nil {
            FileHandle.standardError.write(Data("note: \(options.model) is not in OpenRouter's model list; using default capabilities\n".utf8))
        }
        // A listed model that rejects the requested effort is a hard error with a clear message.
        let model = try await catalog.makeModel(options.model, defaultReasoningEffort: options.effort)
        let policy = options.contextTokens.map { ContextPolicy(contextTokens: $0) } ?? info?.contextPolicy()
        return (model, policy)
    }

    static func models(_ options: Options) async throws {
        let catalog = OpenRouterModelCatalog()
        let all = try await catalog.all(forceRefresh: options.refresh)
        let needle = options.prompt.lowercased()
        let matching = all.filter { needle.isEmpty || $0.id.lowercased().contains(needle) || ($0.name ?? "").lowercased().contains(needle) }
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for model in matching {
                if let data = try? encoder.encode(model) { print(String(decoding: data, as: UTF8.self)) }
            }
            return
        }
        print("model                                        context    in $/M   out $/M  tools  json  reason  image  efforts")
        for model in matching {
            let id = model.id.padding(toLength: 44, withPad: " ", startingAt: 0)
            let context = String(model.contextLength ?? 0).padding(toLength: 10, withPad: " ", startingAt: 0)
            let input = model.pricing?.promptPerMillion.map { String(format: "%7.2f", $0) } ?? "      -"
            let output = model.pricing?.completionPerMillion.map { String(format: "%8.2f", $0) } ?? "       -"
            func flag(_ value: Bool) -> String { value ? "yes  " : "no   " }
            let efforts = model.reasoning?.supportedEfforts?.joined(separator: ",") ?? "-"
            print("\(id) \(context) \(input) \(output)  \(flag(model.supportsTools)) \(flag(model.supportsStructuredOutputs)) \(flag(model.supportsReasoning))  \(flag(model.supportsImages)) \(efforts)")
        }
        print("\n\(matching.count) of \(all.count) models")
    }
}

/// Prints events as readable lines, or as JSON lines for a machine to read.
actor ConsolePrinter: AgentObserver {
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

    func event(_ event: HarnessEvent) {
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
    enum Command { case help, run, resume, sessions, eval, models }

    var command: Command = .run
    var workspace = FileManager.default.currentDirectoryPath
    var model = "anthropic/claude-sonnet-4.6"
    var effort: String? = nil
    var sessionRoot: String? = nil
    var memory: String? = nil
    var skills: String? = nil
    var contextTokens: Int? = nil
    var approve = false
    var json = false
    var prompt = ""
    var tasks: String? = nil
    var only: [String]? = nil
    var trials = 1
    var output: String? = nil
    var judgeModel: String? = nil
    var refresh = false
    var debugDirectory: String? = nil
    var workspaceWasSet = false
    var modelWasSet = false

    static let usage = """
        usage: harness run [options] "<prompt>"
               harness resume <session id or path> "<prompt>"
               harness sessions [--session-root <dir>]
               harness eval [options]
               harness models [search] [--refresh] [--json]

        run options:
          --workspace <dir>      folder the agent may work in (default: current directory)
          --session-root <dir>   where session folders are created (default: Application Support)
          --memory <dir>         memory directory (default: Application Support, per workspace name)
          --skills <dir>         an extra skills folder to scan
          --approve              allow every tool call without asking

        eval options:
          --tasks <dir>          task folders, each with task.json (default: evals/tasks)
          --only <a,b>           run only the named tasks
          --trials <n>           trials per task (default: 1)
          --output <dir>         where reports and trial workspaces go (default: evals/results)
          --judge-model <id>     model for judge graders

        shared options:
          --model <id>           OpenRouter model slug (default: anthropic/claude-sonnet-4.6)
          --effort <level>       reasoning effort: none, low, medium, high, xhigh, max
          --context-tokens <n>   window for masking and compaction (default: from OpenRouter's model list)
          --debug-dir <dir>      write every request body and raw response there
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
        switch rest.first {
        case "run": rest = rest.dropFirst()
        case "eval": options.command = .eval; rest = rest.dropFirst()
        case "models": options.command = .models; rest = rest.dropFirst()
        case "resume": options.command = .resume; rest = rest.dropFirst()
        case "sessions": options.command = .sessions; rest = rest.dropFirst()
        case "help": options.command = .help; return options
        default: break
        }
        var positional: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": options.command = .help
            case "--approve": options.approve = true
            case "--json": options.json = true
            case "--workspace": options.workspace = try value(&rest, for: argument); options.workspaceWasSet = true
            case "--model": options.model = try value(&rest, for: argument); options.modelWasSet = true
            case "--debug-dir": options.debugDirectory = try value(&rest, for: argument)
            case "--effort": options.effort = try value(&rest, for: argument)
            case "--session-root": options.sessionRoot = try value(&rest, for: argument)
            case "--memory": options.memory = try value(&rest, for: argument)
            case "--skills": options.skills = try value(&rest, for: argument)
            case "--context-tokens": options.contextTokens = Int(try value(&rest, for: argument))
            case "--tasks": options.tasks = try value(&rest, for: argument)
            case "--only": options.only = try value(&rest, for: argument).split(separator: ",").map(String.init)
            case "--trials": options.trials = Int(try value(&rest, for: argument)) ?? 1
            case "--output": options.output = try value(&rest, for: argument)
            case "--judge-model": options.judgeModel = try value(&rest, for: argument)
            case "--refresh": options.refresh = true
            default:
                if argument.hasPrefix("--") { throw ParseError(message: "unknown option \(argument)\n\n\(usage)") }
                positional.append(argument)
            }
        }
        options.prompt = positional.joined(separator: " ")
        if options.command == .run || options.command == .resume, options.prompt.isEmpty { throw ParseError(message: "a prompt is required\n\n\(usage)") }
        return options
    }

    private static func value(_ rest: inout ArraySlice<String>, for option: String) throws -> String {
        guard let value = rest.popFirst() else { throw ParseError(message: "\(option) needs a value") }
        return value
    }
}
