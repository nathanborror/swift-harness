# swift-harness

A dependency-free Swift agent harness for macOS 27 and iOS 27, built on Apple's FoundationModels framework. The framework already supplies the agent loop, the transcript, the `Tool` protocol, and lifecycle hooks. This package adds what the framework leaves to the app: a model executor for OpenRouter, a session log and transcript persistence, a sandboxed workspace, a permission gate with bounded tool results, and a set of coding tools. Everything composes onto a `LanguageModelSession` through dynamic profiles and tool wrappers, so an app keeps the framework's API and gains the harness underneath it.

The design follows the five guides in `Research/`, which survey how production harnesses are built. Where the guides show consensus, this package takes the consensus default: an append-only log, exact-match edits with a stale-read check, read-only tools allowed by default, every denial returned to the model as a tool result, and tool output bounded before it enters the context window.

## Models

`OpenRouterLanguageModel` conforms to the framework's `LanguageModel` protocol and routes requests through OpenRouter's Responses API. Pass it to a session and the session works as it does with Apple's models: tools, streaming, guided generation, and transcripts all carry over. The model value holds the OpenRouter slug, its capabilities, a default reasoning effort, a prompt-cache switch, and a sticky-routing session ID. `OpenRouterConfiguration` holds the base URL and credential and is the executor cache key, so switching models inside a profile keeps the same connection.

The executor resends the full transcript on every request, which is what OpenRouter needs since it stores nothing between calls. Transcript entries map one to one onto Responses items. Reasoning items come back with a signature and are replayed verbatim from a raw copy kept in entry metadata, so provider state survives across tool calls. Usage, cost, and the generation ID land in `session.usage` and entry metadata.

The credential comes from the `OPENROUTER_API_KEY` environment variable by default. A literal key is available for development, and a no-token mode is for apps that route through their own proxy.

## Sessions

`SessionDirectory` is the on-disk home of one session: an append-only `events.jsonl`, a saved `transcript.json`, and an `outputs/` folder for oversized tool results. `SessionLog` is an actor that appends `HarnessEvent` records to the JSONL file. A logging failure never stops a reply; the last error is kept on the log for the app to surface.

Both attach to a dynamic profile as modifiers. `.logging(to:)` records every prompt, reasoning entry, response, tool call, and tool output as the session produces them. `.persistingTranscript(in:)` saves the history after each response and tool output, so a quit or crashed app resumes by loading the transcript and creating a new session from it.

## Workspace

`Workspace` is the folder the agent may work in. On a sandboxed app it opens from a security-scoped bookmark of a folder the person chose and holds access for its lifetime. Every path a tool receives goes through `url(for:)`, which resolves relative paths from the root and rejects traversal, absolute paths elsewhere, and symlinks that point outside. The same type serves iOS, where a folder from the document picker works the same way.

On macOS, child processes inherit the app's sandbox. There is no nested profile; containment is the App Sandbox, the workspace grant, and the permission rules. The shell cannot be cut off from the network separately, which is a known limit.

## Tools

`ToolGate` wraps any framework tool with `gate(_:)`. The wrapper keeps the tool's name, description, and schema, so the model sees no difference, and every call passes through a `PermissionPolicy`: an ordered rule list with a fallback, where the first matching rule wins. Rules match by tool name, by a predicate on a string argument, or by annotations a tool declares through `AnnotatedTool`: read-only, destructive, or open-world. The default policy allows read-only tools and asks for everything else.

An `ask` goes to a `PermissionPrompter` the app supplies, with allow-once, allow-always, and deny. A denial, and a tool that throws, return to the model as tool output so the loop continues. Only repeated denials escalate, by throwing `ToolGateError.escalation` and ending the turn. Every decision is logged.

Results pass through `ToolResultShaper` before they reach the model. Output over the limit is written to the session's outputs folder and replaced by an excerpt plus a note saying what was cut and where the rest is. Empty output becomes `(no output)` so silence is never ambiguous.

`CodingTools` provides the built-in set for a workspace: `read`, `edit`, and `write` on every platform, and `shell` on macOS. Read returns a window of lines with a footer that says how to continue, and lists directories. Edit replaces exact text that must appear once, refuses files the model has not read or that changed since, and preserves line endings and byte-order marks. Write creates parents and refuses to overwrite an unread file. Shell runs a fresh `/bin/sh` per call with a fixed environment, merged output, and a kill at the time limit.

## Layout

```
Sources/Harness/
  OpenRouter/        # LanguageModel and executor for the Responses API, request builder, stream translator
  Session/           # SessionDirectory, SessionLog, HarnessEvent, logging and persistence modifiers
  Workspace/         # Workspace: scoped folder and path resolution
  Tools/             # ToolGate, Gated, PermissionPolicy, ToolAnnotations, ToolResultShaper
  CodingTools/       # read, edit, write, shell, and their shared context
  Support/           # JSONValue and the server-sent events parser
Tests/HarnessTests/
  Fixtures/          # captured OpenRouter streams used by the translator tests
Research/            # the harness, memory, heartbeats, tools, and skills guides this design follows
```

## Usage

A session with gated coding tools, logging, and persistence:

```swift
import FoundationModels
import Harness

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

Built and verified: the OpenRouter executor, the session log and persistence, the workspace, the permission gate and result shaping, and the coding tools. Not yet built: memory files and their index, skill discovery, a scheduler for heartbeats, a sub-agent tool, and a headless runner for evals. The `Research/` guides describe each of those.

**Open question:** whether to keep one `Harness` product or split the macOS-only shell and future coding additions into a separate product once an iOS app consumes the package.
