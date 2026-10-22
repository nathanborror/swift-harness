# swift-harness

A dependency-free Swift agent harness for macOS 27 and iOS 27, built on Apple's FoundationModels framework. The framework already supplies the agent loop, the transcript, the `Tool` protocol, and lifecycle hooks. This package adds what the framework leaves to the app: a model executor for OpenRouter, a session log and transcript persistence, a sandboxed workspace with file tools, a permission gate with bounded tool results, memory, skills, a scheduler, and sub-agents. Everything composes onto a `LanguageModelSession` through dynamic profiles and tool wrappers, so an app keeps the framework's API and gains the harness underneath it.

The package ships two libraries. `Harness` is the general agent, with nothing that assumes the agent writes code. `HarnessCoding` builds a coding agent on it: the shell, background processes, shell permission rules, `AGENTS.md` instruction files, an explorer sub-agent, and evals. An app whose agent works on something other than code depends on `Harness` alone.

The design follows the five guides in `Research/`, which survey how production harnesses are built. Where the guides show consensus, this package takes the consensus default: an append-only log, exact-match edits with a stale-read check, read-only tools allowed by default, every denial returned to the model as a tool result, and tool output bounded before it enters the context window.

## Models

`OpenRouterLanguageModel` conforms to the framework's `LanguageModel` protocol and routes requests through OpenRouter's Responses API. Pass it to a session and the session works as it does with Apple's models: tools, streaming, guided generation, and transcripts all carry over. The model value holds the OpenRouter slug, its capabilities, a default reasoning effort, a prompt-cache switch, and a sticky-routing session ID. `OpenRouterConfiguration` holds the base URL and credential and is the executor cache key, so switching models inside a profile keeps the same connection.

The executor resends the full transcript on every request, which is what OpenRouter needs since it stores nothing between calls. Transcript entries map one to one onto Responses items. Reasoning items come back with a signature and are replayed verbatim from a raw copy kept in entry metadata, so provider state survives across tool calls. Usage, cost, and the generation ID land in `session.usage` and entry metadata. Set `usageHandler` on the model to hear each completed generation's cost as it happens, including calls from sub-agents and compaction summaries that share the model and never reach a saved transcript.

`OpenRouterModelCatalog` fetches OpenRouter's model list, caches it for a day, and turns a listing into a model value with the right capabilities, a context policy sized to the model's window, and a check that a requested reasoning effort is one the model accepts. The runner uses it when no context size is given and falls back to defaults offline. `harness models <search>` prints the listing with context size, prices, and capabilities.

`OpenRouterConfiguration.debugDirectory` turns on request dumps: every attempt writes its request body, its raw response stream, and a small metadata file with the status, headers, and timing, which is what you read when a cache stops hitting or a provider rejects a field. The command line exposes it as `--debug-dir`.

A transient failure, meaning a rate limit, a server error, a lost connection, or an error chunk before any output, is retried once after a short delay that honors `Retry-After`. A stream that fails after output has reached the session is not retried. A URLSession timeout surfaces as the framework's timeout error.

The credential comes from the `OPENROUTER_API_KEY` environment variable by default. A literal key is available for development, and a no-token mode is for apps that route through their own proxy.

## Sessions

`SessionDirectory` is the on-disk home of one session: an append-only `events.jsonl`, a saved `transcript.json`, a `session.json` manifest with the model and whatever the toolsets record, such as a coding session's workspace, so a later launch can resume it, and an `outputs/` folder for oversized tool results. `SessionLog` is an actor that appends `HarnessEvent` records to the JSONL file. A logging failure never stops a reply; the last error is kept on the log for the app to surface.

Both attach to a dynamic profile as modifiers. `.logging(to:)` records every prompt, reasoning entry, response, tool call, and tool output as the session produces them. `.persistingTranscript(in:)` saves the history after each response and tool output, so a quit or crashed app resumes by loading the transcript and creating a new session from it.

## Workspace

`Workspace` is the folder the agent may work in. On a sandboxed app it opens from a security-scoped bookmark of a folder the person chose and holds access for its lifetime. Every path a tool receives goes through `url(for:)`, which resolves relative paths from the root and rejects traversal, absolute paths elsewhere, and symlinks that point outside. The same type serves iOS, where a folder from the document picker works the same way.

On macOS, child processes inherit the app's sandbox. There is no nested profile; containment is the App Sandbox, the workspace grant, and the permission rules. The shell cannot be cut off from the network separately, which is a known limit.

## Tools

`ToolGate` wraps any framework tool with `gate(_:)`. The wrapper keeps the tool's name, description, and schema, so the model sees no difference, and every call passes through a `PermissionPolicy`: an ordered rule list with a fallback, where the first matching rule wins. Rules match by tool name, by a predicate on a string argument, or by annotations a tool declares through `AnnotatedTool`: read-only, destructive, or open-world. The default policy allows read-only tools and asks for everything else.

`ShellRules`, in `HarnessCoding`, is the shipped rule set for the shell: a deny list for the dangerous patterns such as privilege escalation, recursive deletes of the root or home, disk writes, piping a download into a shell, and force pushes; an ask list for the hard-to-reverse and network-reaching ones such as recursive deletes, pushes, discarding git work, installs, and infrastructure commands; and allow for the rest. It is a tripwire, not a boundary, since a command can be written to slip past any pattern; the boundary is the sandbox and the workspace. `PermissionPolicy.coding` combines it with read-only allowed and edits asking, and `.unattended` turns the asks into denials for runs with nobody present.

An `ask` goes to a `PermissionPrompter` the app supplies, with allow-once, allow-always, and deny. A denial, and a tool that throws, return to the model as tool output so the loop continues. Only repeated denials escalate, by throwing `ToolGateError.escalation` and ending the turn. Every decision is logged.

Results pass through `ToolResultShaper` before they reach the model. Output over the limit is written to the session's outputs folder and replaced by an excerpt plus a note saying what was cut and where the rest is. Empty output becomes `(no output)` so silence is never ambiguous.

`ReadTool`, `EditTool`, and `WriteTool` work on the files in a workspace through a shared `FileToolContext`, on every platform. Read returns a window of lines with a footer that says how to continue, and lists directories. Edit replaces exact text that must appear once, refuses files the model has not read or that changed since, and preserves line endings and byte-order marks. Write creates parents and refuses to overwrite an unread file. `CodingTools`, in `HarnessCoding`, adds `shell` on macOS: a fresh `/bin/sh` per call with a fixed environment, merged output, and a kill at the time limit.

## Memory

`MemoryDirectory` is the agent's memory on disk, as plain Markdown: `MEMORY.md` holds the index and curated facts, `USER.md` holds preferences as dated directives, `notes/` holds one append-only file per day, and `topics/` holds one subject per file. `MemoryInstructions` renders the index, the user file, and the last two days of notes into the instructions on every request, each under a hard cap. When a file is over its cap the rendering is cut and says so, and the file on disk is left alone; shortening it is the model's job. Recent notes are framed as untrusted background from earlier sessions.

`MemoryConsolidation` promotes recent notes into the index on a schedule. Deterministic code picks the candidates, which are note lines from the last few days that the index does not already contain. A `ConsolidationPlanner` returns one decision per candidate, add, merge, supersede, or drop, and nothing else; the default planner asks a model through guided generation. The harness writes the entries itself with a date and a source, rejects a rewrite that removes more than a quarter of the existing entries or grows past the cap and falls back to appending, keeps the previous index under `archive/` as an undo, and appends a line to `consolidation.md` for a person to review. `Job.memoryConsolidation()` is the nightly job, paired with `MemoryConsolidationRunner` through a `CompositeJobRunner`.

`MemoryTools` gives the model `memory_read`, `memory_edit`, and `memory_write`, which are the file tools rooted at the memory folder with the same stale-read rules, plus `memory_note` for appending to today's note and `memory_search` for keyword search that returns a path and line with every hit. The protocol text in the instructions tells the model what to save, what to skip, and to write before its context is lost.

## Skills

A skill is a folder with a `SKILL.md` whose frontmatter gives a name and a description. `SkillCatalog.discover(in:)` scans the roots an app chooses, parses the frontmatter leniently, and lets a later root override an earlier one on a name collision. Which folders to scan is a trust decision the app makes, since a repository's skills are instructions to the agent.

`SkillsInstructions` puts the catalog into the instructions under a character budget, shortening descriptions before dropping names, together with a `skill` tool that loads a skill's body as tool output. Loading through a tool keeps the cached prefix intact. `InstructionFiles`, in `HarnessCoding`, loads `AGENTS.md` files from the workspace root down to a directory, broadest first, under a size cap; the coding toolset adds them to the instructions.

## Context

`ContextManagement` keeps a long session inside the model's window in two stages, under a `ContextPolicy` expressed as fractions of the window. Past the mask threshold, a stateless `historyTransform` replaces old tool outputs in the model's view with a short pointer that says what was elided; the transcript is untouched, the last few outputs stay verbatim, and the cut point moves in batches so the provider cache invalidates rarely. Past the compaction threshold, an `onResponse` hook rewrites the history: the full history is archived under the session's `archive/` folder, durable facts are flushed to today's memory note by a side session, the older part is summarized under a fixed template, and the recent tail, starting at a prompt boundary, is kept verbatim. The summary names the archive path so the model can recover anything the summary lost. Instructions loaded through the `skill` tool are carried across: the latest output per skill that would otherwise be lost is re-inserted after the summary as a tool call and output pair, under per-skill and total caps, and a skill still in the kept tail is not duplicated. `ContextPolicy.reattachedTools` names the tools this applies to.

Sizes are estimated from characters, since no tokenizer is available for an arbitrary model. Set `contextTokens` from the model you use, or let the model catalog set it.

Two things were checked live through OpenRouter and are re-checked by the verification suite in the tests. Prompt caching holds across the turns of one session: with a stable prefix over the model's minimum cacheable size, the second and third turns read nearly the whole prefix from the cache. A history with a masked tool output was accepted and answered correctly by Claude Haiku 5.5 and Claude Sonnet 4.6 after reasoning turns, so masking does not trip the reasoning-replay check on those models. Other models should be checked the same way before relying on masking with them.

## Scheduler

`Scheduler` is one scheduler in the harness process; the model is never the timer. Jobs live in a `JobStore` as a JSON file, with every tick recorded in a JSONL run log whether it reached the model or was skipped. A `Job` has a schedule, which is a one-time date, an interval, or a five-field cron expression in a time zone, plus a prompt that should point at a runbook, a fixed tool list, optional active hours, a catch-up policy, limits, and a small scratch checklist the job may rewrite each run.

Guards run before any model call and record why they skipped: disabled, expired, paused, outside active hours, still running, or an empty checklist. A run goes through a `JobRunner`; the default `AgentJobRunner` starts a fresh session with a wake message that carries the current and scheduled times, the unattended contract, and the checklist, and gives the model a `job_respond` tool to end in a named outcome, notify or stay quiet, rewrite the checklist, and ask for its next check within bounds. A reply of `NO_REPLY` is silence. Results and alerts go through a `JobDelivery`; `InboxDelivery` appends them to an inbox file so nothing is lost. Recurring jobs back off after errors, alert after two with a cooldown, and are disabled after ten. One-shots run once and are removed. After downtime, missed runs are coalesced to one or skipped to the next occurrence by policy. `Job.heartbeat(every:)` is the periodic check that usually says nothing.

`ScheduleTool` lets the model add, list, run, and remove jobs. A new job runs once as a visible test, agent-created jobs expire after seven days, and inside a scheduled run the tool can only report on or remove its own job.

## Sub-agents

`TaskTool` lets the model delegate to a sub-agent: a `SubagentDefinition` with its own model, instructions, and tool set, usually narrower than the parent's. Each call runs a fresh session from the definition and returns only the final reply, so exploration and raw tool output stay out of the parent's context. The brief is the sub-agent's whole context, and the tool description says so. A cap on tool calls per run stops a sub-agent that loops, and every run is logged with its token usage. Because each call makes its own session, parallel tool calls become parallel sub-agents.

## Runner

`AgentRunner` assembles a session from an `AgentConfiguration`: the model, instructions that say what the agent is for, a list of toolsets, where sessions and memory live, which skill roots to scan, the permission policy and prompter, and an optional context policy. It runs one prompt, reporting text and events to an `AgentObserver`, or hands back the assembled session for many turns. Apps and the command line share this one wiring.

A toolset is an `AgentToolset`: it returns its tools for a session, wrapping each with the session's gate so the call answers to the permission policy, and may add instructions and facts for the session manifest. `CodingToolset`, in `HarnessCoding`, is the coding agent's: the coding tools for one workspace, a read-only explorer sub-agent on the session's model, and the workspace's `AGENTS.md` files. `AgentConfiguration.coding(model:workspace:sessionRoot:)` builds a configuration around it with coding instructions. `ToolList` passes an app's own tools through without the gate. An agent with no workspace, such as one that works on a calendar, lists only its own toolsets. Memory tools come from the configuration's memory directory rather than a toolset.

```swift
struct CalendarToolset: AgentToolset {
    let store: EventStore

    func tools(in context: AgentToolsetContext) -> [any Tool] {
        [context.gate.gate(ListEventsTool(store: store)), context.gate.gate(AddEventTool(store: store))]
    }

    var instructions: String? { "Times are in the person's time zone. Ask before adding an event that overlaps another." }
}

let configuration = AgentConfiguration(
    model: OpenRouterLanguageModel(modelID: "anthropic/claude-sonnet-4.6"),
    instructions: "You manage the person's calendar.",
    toolsets: [CalendarToolset(store: store)],
    sessionRoot: try SessionDirectory.defaultRoot(),
    memory: try MemoryDirectory(root: try MemoryDirectory.defaultRoot(project: "calendar"))
)
let result = try await AgentRunner(configuration: configuration).run(prompt: "What's on Friday?")
```

The `harness` executable is the headless front end for macOS. `run` streams one prompt's reply with tool calls and their first line of output, or every event as a JSON line with `--json`, which is what another process reads. Permission asks go to the terminal, or are denied when stdin is not one; `--approve` allows everything.

`sessions` lists saved sessions, and `resume <id> "<prompt>"` continues one from its transcript, reusing the workspace and model from its manifest unless overridden, and appending to the same log.

```sh
swift run harness run --workspace path/to/project "Fix the failing test."
swift run harness run --workspace . --json --approve "Add a changelog entry."
swift run harness sessions
swift run harness resume 20261008T062728-93d4f136 "Now add a test for it."
```

## In an app

`AgentSession` is the object a SwiftUI app observes. It is a main-actor `@Observable` class that owns the framework session across turns, so views read `session.transcript` and `session.isResponding` from the framework directly, and adds what the framework does not expose: the reply streaming in, recent harness activity, token usage, the last error, and a `cancel()`. It starts from a configuration and can resume from a transcript saved by an earlier session.

`AgentSession.jobRunner` lets the scheduler run the heartbeat in this session, with the conversation as context, rather than in a fresh one. The wake message runs as a turn whose prompt carries the job ID in its metadata, so a view can hide it with `AgentSession.isJobPrompt`, and the response tool is available so the run ends in a named outcome. When a turn is already running the tick is skipped, not failed, and any events it carried wait for the next tick.

`UIPermissionPrompter` turns an ask into state: the gate parks a request on `pending`, the view renders it, and `respond(_:)` resumes the tool call with allow once, allow always, or deny. Asks are served one at a time, and one that nobody answers within the timeout is denied, so a waiting tool call always ends.

On macOS the coding shell tool can run a command in the background when `CodingToolset` is given a `backgroundOutputs` folder. The command's output streams to a file there, `process_status` returns its state and a bounded tail, `process_stop` ends it, and the manager's exit handler lets the app queue an event on the scheduler, which wakes the heartbeat within a rate limit so the agent continues without polling.

## Evals

Evals live in `HarnessCoding`, since their graders read files in a workspace and run commands there. An eval task is a folder with a `task.json`: a prompt, files to seed the workspace, optional setup command, graders, a timeout, and a suite name. `EvalRunner` runs each task for a number of trials, each in a fresh workspace with its own session folder, grades the outcome, and writes `report.json` and `report.txt` under the output root alongside every trial's workspace and session, so a failing trial can be read back in full.

Graders check the outcome, not the path: file contents, file presence, a command's exit code, the response text, which tools were called, and a cap on tool calls. A `judge` grader asks a model against a rubric through guided generation and may answer unknown, which counts against the trial but is reported separately. The `suite` field separates capability tasks, which climb from a low pass rate, from regression tasks, which should stay near full marks. Three regression tasks live in `evals/tasks/`.

```sh
swift run harness eval --tasks evals/tasks --trials 3 --model anthropic/claude-sonnet-4.6
swift run harness eval --only fix-add --judge-model anthropic/claude-haiku-4.5
```

## Layout

```
Sources/Harness/             # the general agent
  OpenRouter/                # LanguageModel and executor for the Responses API, request builder, stream translator
  Session/                   # SessionDirectory, SessionLog, HarnessEvent, logging and persistence modifiers
  Workspace/                 # Workspace: scoped folder and path resolution
  Files/                     # read, edit, and write, and their shared FileToolContext
  Tools/                     # ToolGate, Gated, PermissionPolicy, ToolAnnotations, ToolResultShaper
  Memory/                    # MemoryDirectory, MemoryInstructions, memory tools
  Skills/                    # SkillCatalog, SkillsInstructions, the skill tool
  Subagents/                 # TaskTool and SubagentDefinition
  Context/                   # ContextPolicy, masking, compaction
  Runner/                    # AgentConfiguration, AgentToolset, ToolList, AgentRunner
  Scheduler/                 # Job, JobStore, Scheduler, runners, delivery, cron
  UI/                        # AgentSession and UIPermissionPrompter
  Support/                   # JSONValue, the server-sent events parser, TimeLimitError
Sources/HarnessCoding/       # the coding agent, built on Harness
  CodingTools/               # shell, background processes, ShellRules, CodingTools, CodingToolset
  Instructions/              # InstructionFiles: AGENTS.md discovery
  Evals/                     # EvalTask, graders, EvalRunner
Sources/HarnessCLI/          # the harness executable: run, resume, sessions, eval, models
Tests/HarnessTests/          # tests for Harness
  Fixtures/                  # captured OpenRouter streams and the model listing
Tests/HarnessCodingTests/    # tests for HarnessCoding
Tests/HarnessTestSupport/    # EchoModel, a deterministic model both test targets use
evals/tasks/                 # starter eval tasks
Research/                    # the harness, memory, heartbeats, tools, and skills guides this design follows
```

## Usage

A session with gated coding tools, logging, and persistence:

```swift
import FoundationModels
import Harness
import HarnessCoding

let directory = try SessionDirectory(root: try SessionDirectory.defaultRoot())
let log = try directory.makeLog()
let workspace = try Workspace(bookmark: savedBookmark)
let gate = ToolGate(
    policy: .default,
    prompter: myPrompter,
    shaper: ToolResultShaper(outputsDirectory: directory.outputsURL),
    log: log
)
let tools = CodingTools(workspace: workspace).gated(by: gate)
let model = OpenRouterLanguageModel(modelID: "anthropic/claude-sonnet-4.6", sessionID: directory.sessionID)

struct AgentProfile: LanguageModelSession.DynamicProfile {
    let model: OpenRouterLanguageModel
    let tools: [any Tool]
    let directory: SessionDirectory
    let log: SessionLog

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions("You are a coding agent. Read a file before editing it.")
            tools
        }
        .model(model)
        .logging(to: log)
        .persistingTranscript(in: directory, log: log)
    }
}

let session = LanguageModelSession(profile: AgentProfile(model: model, tools: tools, directory: directory, log: log))
let response = try await session.respond(to: "Rename the greeting in hello.txt.")
```

Build and test:

```sh
swift build
swift test
```

The live suites call OpenRouter and run only when `OPENROUTER_API_KEY` is set. Each costs a fraction of a cent.

## Status

Built and verified: the OpenRouter executor, the session log and persistence, the workspace and file tools, the permission gate and result shaping, memory, skills, the sub-agent tool, context management, the runner and toolsets, and in `HarnessCoding` the shell, instruction files, and evals. Both libraries also build for the iOS simulator; `HarnessCoding` leaves out the shell tool, background processes, and the process runner there. Views are left to the app; the package provides the observable session and prompter they bind to. The `Research/` guides describe each of those.

## TODO

Before first app use:

- [x] Add a Keychain credential to `OpenRouterConfiguration.Credential` (`.keychain(service:account:)`); an iOS app cannot read an environment variable. A token provider is still open.
- [ ] Run the harness inside a sandboxed app and confirm that the scoped workspace bookmark and `/bin/sh` behave as the App Sandbox docs say.
- [x] Ship a default shell rule set that denies known-dangerous patterns such as recursive deletes, pushes, and network fetches.
- [x] Retry transient OpenRouter failures once, and map a URLSession timeout to `LanguageModelError.timeout`.

Soon:

- [x] Let `AgentSession` run the heartbeat in its own session, instead of the scheduler's fresh session.
- [x] Read context size and reasoning support from OpenRouter's models endpoint and set `ContextPolicy` from it.
- [x] Re-attach loaded skill content after compaction so it is not summarized away.
- [x] Add a debug option that dumps raw request bodies, for diagnosing cache misses and rejected fields.
- [x] Verify prompt caching over a long session, and verify that masking old tool outputs passes the newest Claude models' reasoning-replay check through OpenRouter.
- [x] Add a `resume` command to the CLI.

Later:

- [ ] Edit-tool leniency for whitespace and smart quotes, and a syntax check after edits.
- [ ] Provenance tags on memory so untrusted tool output is never promoted, and recall counts to gate consolidation.
- [ ] More eval tasks, a live test of the judge grader, and the regression suite in CI.
- [ ] Mid-conversation system reminders, once the framework has a slot for them.
