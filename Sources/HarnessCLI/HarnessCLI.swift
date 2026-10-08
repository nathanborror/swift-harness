import Foundation
import FoundationModels
import Harness

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
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ options: Options) async throws {
        let workspace = try Workspace(root: URL(fileURLWithPath: options.workspace))
        let sessionRoot = try options.sessionRoot.map { URL(fileURLWithPath: $0) } ?? SessionDirectory.defaultRoot()
        let memoryRoot = try options.memory.map { URL(fileURLWithPath: $0) } ?? MemoryDirectory.defaultRoot(project: workspace.root.lastPathComponent)
        var skillRoots = SkillCatalog.conventionalRoots(workspace: workspace)
        if let extra = options.skills { skillRoots.append(URL(fileURLWithPath: extra)) }

        let configuration = AgentConfiguration(
            model: model(options, sessionID: nil),
            workspace: workspace,
            sessionRoot: sessionRoot,
            memory: try MemoryDirectory(root: memoryRoot),
            skillRoots: skillRoots,
            policy: options.approve ? .allowAll : .default,
            prompter: options.approve ? nil : ConsolePrompter(),
            contextPolicy: options.contextTokens.map { ContextPolicy(contextTokens: $0) }
        )
        let printer = ConsolePrinter(json: options.json)
        let result = try await AgentRunner(configuration: configuration).run(prompt: options.prompt, observer: printer)
        await printer.finish(usage: result.usage, directory: result.directory)
    }

    static func eval(_ options: Options) async throws {
        let tasksRoot = URL(fileURLWithPath: options.tasks ?? "evals/tasks")
        let loaded = try EvalTask.loadAll(in: tasksRoot)
        let selected = options.only.map { only in loaded.filter { only.contains($0.task.name) } } ?? loaded
        guard !selected.isEmpty else { throw Options.ParseError(message: "no tasks found under \(tasksRoot.path)") }
        let outputRoot = URL(fileURLWithPath: options.output ?? "evals/results")
        let judge: (any LanguageModel)? = options.judgeModel.map { OpenRouterLanguageModel(modelID: $0, defaultReasoningEffort: "low") }
        let modelID = options.model
        let effort = options.effort
        let contextTokens = options.contextTokens
        let runner = EvalRunner(outputRoot: outputRoot, judge: judge) { workspace, sessionRoot in
            AgentConfiguration(
                model: OpenRouterLanguageModel(modelID: modelID, defaultReasoningEffort: effort),
                workspace: workspace,
                sessionRoot: sessionRoot,
                memory: nil,
                skillRoots: [],
                policy: .allowAll,
                prompter: nil,
                contextPolicy: contextTokens.map { ContextPolicy(contextTokens: $0) }
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

    private static func model(_ options: Options, sessionID: String?) -> OpenRouterLanguageModel {
        OpenRouterLanguageModel(modelID: options.model, defaultReasoningEffort: options.effort, sessionID: sessionID)
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
    enum Command { case help, run, eval }

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

    static let usage = """
        usage: harness run [options] "<prompt>"
               harness eval [options]

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
          --context-tokens <n>   enable masking and compaction for a window of n tokens
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
        case "help": options.command = .help; return options
        default: break
        }
        var positional: [String] = []
        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h": options.command = .help
            case "--approve": options.approve = true
            case "--json": options.json = true
            case "--workspace": options.workspace = try value(&rest, for: argument)
            case "--model": options.model = try value(&rest, for: argument)
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
            default:
                if argument.hasPrefix("--") { throw ParseError(message: "unknown option \(argument)\n\n\(usage)") }
                positional.append(argument)
            }
        }
        options.prompt = positional.joined(separator: " ")
        if options.command == .run, options.prompt.isEmpty { throw ParseError(message: "a prompt is required\n\n\(usage)") }
        return options
    }

    private static func value(_ rest: inout ArraySlice<String>, for option: String) throws -> String {
        guard let value = rest.popFirst() else { throw ParseError(message: "\(option) needs a value") }
        return value
    }
}
