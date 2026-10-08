# Agent Skills, Hooks, and MCP Guide

Oct 3, 2026 · @Nathan Borror

## What the extension surface is

A harness is extended in three ways. Skills add knowledge the model loads when it needs it. Hooks add code the harness runs at fixed points whether the model wants it or not. MCP adds tools that live in other processes. Plugins package the three for distribution.

This guide is a companion to the [Agent Harness Engineering Guide](000_agent_harness_guide.md) and the [Agent Core Tools Guide](003_agent_tools_guide.md). Those cover the loop and the built-in tools. This one covers what other people add to your harness after you ship it.

### The mechanisms compared

| Mechanism | What it adds | Who decides it runs | Context cost when idle | Use it for |
| --- | --- | --- | --- | --- |
| Instruction file | Rules loaded into every session | Nobody. Always on. | The whole file, every turn | Conventions that apply to all work |
| Skill | A folder of instructions and scripts | The model, from a one-line description. Or the user, by name. | About 50 to 100 tokens each | Procedures and domain knowledge needed sometimes |
| Hook | Deterministic code at a lifecycle event | The harness, every time the event fires | None | Rules that must hold, formatting, logging, gates |
| MCP server | Tools, resources, and prompts served by another process | The model, by calling a tool | Each tool definition, unless deferred | Access to external systems |
| Plugin | A bundle of the above | Whoever installs it | The sum of its parts | Distribution |

### The dividing line

The choice between a skill and a hook is the choice between advice and enforcement. Stripe ran about a dozen experiments on steering agents and concluded that "hard steers, such as errors, explicit instructions in loaded context, and blocking responses, work", while warnings, hints, and nearby files often do not ([Stripe](https://stripe.dev/blog/ai-steering-experiments)). Claude Code's own skills documentation says the same thing in practical terms: a rule that must hold every time belongs in a hook.

### A moving target

All three mechanisms changed materially in the year before this guide.

- Agent Skills became an open standard in December 2025, with a specification at [agentskills.io](https://agentskills.io).
- The MCP specification's current revision is dated 2026-07-28. It removed the connection handshake and sessions, so a client written against the 2025 revisions needs real changes.
- Hook systems grew quickly. Claude Code documents 33 events and Codex 12.

The facts below were read from specifications, documentation, and source code on 2026-10-03.

## What the sources agree on

Seven ideas hold across the specifications and the three harnesses read in detail.

1. **Disclose progressively.** Show the model a cheap catalog, and load the full content only when it is chosen. Skills do this with a name and description. Tool search does it for MCP tools.
2. **Budget the catalog and enforce the budget in code.** Claude Code gives skill listings 1% of the context window and Codex 2%. Both shorten descriptions before they drop names.
3. **Model-chosen loading is unreliable, so measure it.** LangChain found a relevant skill was never invoked on one task, and a prompt telling the agent to use skills raised invocation only to 70% ([Evaluating Skills](https://www.langchain.com/blog/evaluating-skills)).
4. **Put must-hold rules in hooks and errors.** Stripe's agents ignored warnings in API responses and reliably acted on errors. Their summary is "errors block progress but warnings don't".
5. **A hook system is one small protocol.** One JSON object goes in. An exit code and an optional JSON object come out. The work is in defining what "block" means for each event and what happens when a hook times out.
6. **Keep external tool definitions out of the cached prompt prefix.** Namespace tools by server, cap what a server can return, and return tools in a stable order. The MCP specification now asks servers for deterministic ordering because it "improves LLM prompt cache hit rates".
7. **Treat everything a repository or a third party supplies as untrusted until someone trusts it.** That covers project skills, project hooks, project MCP servers, and plugins. A February 2026 audit of 3,984 public skills found 534 with at least one critical security issue and 76 confirmed malicious payloads, as cited in the [SkillTester](https://arxiv.org/abs/2603.28815) paper.

## Skills

A skill is a directory with a `SKILL.md` file and optional scripts and reference files. Supporting skills in a harness comes down to a catalog in the prompt and a file read, and the Agent Skills site publishes an implementer's guide that this section follows ([Agent Skills](https://agentskills.io)).

### The format

```text
skill-name/
  SKILL.md        required: frontmatter and instructions
  scripts/        optional: code the agent can run
  references/     optional: documents read on demand
  assets/         optional: templates and data
```

```markdown
---
name: pdf-processing
description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
---

Instructions in Markdown...
```

| Field | Required | Constraint |
| --- | --- | --- |
| `name` | Yes | At most 64 characters, lowercase letters, digits, and hyphens, matching the directory name |
| `description` | Yes | At most 1,024 characters. Says what the skill does and when to use it. |
| `license`, `compatibility`, `metadata` | No | Free text and a string map |
| `allowed-tools` | No | A space-separated list of pre-approved tools. Experimental. |

### Three tiers of loading

| Tier | What is loaded | When | Cost |
| --- | --- | --- | --- |
| Catalog | Name and description | Session start | About 50 to 100 tokens per skill |
| Instructions | The `SKILL.md` body | When the skill is activated | Under 5,000 tokens recommended |
| Resources | Scripts and reference files | When the instructions point to them | Varies |

A script in a skill can run without its source ever entering the context, which is why Anthropic describes the context a skill can bundle as "effectively unbounded" ([Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)).

### Implementing skills in five steps

1. **Discover.** Scan a project directory and a user directory for subdirectories that contain `SKILL.md`. The cross-client convention is `.agents/skills/` in the project and in the home directory, alongside your own client's path. Bound the scan in depth and directory count. Load project skills only after the folder is trusted.
2. **Parse.** Read the frontmatter leniently. The most common breakage is an unquoted description containing a colon, and the guide suggests retrying with the value quoted. Warn on a name mismatch and load anyway. Skip a skill with no description.
3. **Disclose.** Put the catalog in the system prompt with short instructions. Hide skills the user disabled or the model may not invoke, and omit the whole block when there are no skills.
4. **Activate.** Either the model reads `SKILL.md` with its ordinary read tool, or you provide a tool such as `activate_skill(name)` whose `name` is constrained to the valid names. Users activate by typing the name.
5. **Manage.** Protect loaded skill content from compaction, and skip re-injecting a skill that is already loaded.

The guide's catalog example and instruction text can be used as written:

```xml
<available_skills>
  <skill>
    <name>pdf-processing</name>
    <description>Extract PDF text, fill forms, merge files. Use when handling PDFs.</description>
    <location>/home/user/.agents/skills/pdf-processing/SKILL.md</location>
  </skill>
</available_skills>
```

```text
The following skills provide specialized instructions for specific tasks.
When a task matches a skill's description, use your file-read tool to load
the SKILL.md at the listed location before proceeding.
When a skill references relative paths, resolve them against the skill's
directory (the parent of SKILL.md) and use absolute paths in tool calls.
```

On step 5, Claude Code re-attaches the most recent invocation of each skill after compaction, up to 5,000 tokens per skill and 25,000 in total. The guide's reason is that losing skill instructions mid-conversation "silently degrades the agent's performance without any visible error".

### Catalog budgets

| Harness | Budget for the listing | When over budget |
| --- | --- | --- |
| Claude Code | 1% of the context window, and 1,536 characters per entry | Drops descriptions of the least-used skills first |
| Codex | 2% of the context window, or 8,000 characters when the window is unknown | Shortens descriptions, then omits skills with a warning |
| OpenClaw | 18,000 characters and 150 skills by default | Keeps names and locations, and offers a search tool for the rest |

### What the harnesses add to the base format

- **Claude Code** adds frontmatter fields. `disable-model-invocation` makes a skill user-only. `allowed-tools` pre-approves tools for the turn. `context: fork` runs the skill in a fresh sub-agent. `paths` limits automatic loading to matching files. Arguments are substituted with `$ARGUMENTS`.
- **Codex** keeps `SKILL.md` standard and puts extras in a sidecar file, including a switch for implicit invocation and tool dependencies such as an MCP server.
- **OpenClaw** gates skills at load time. A skill can require binaries on the path, environment variables, config keys, or an operating system, and an ineligible skill is left out of the prompt.

They disagree on name collisions. The guide and OpenClaw let a project skill override a user skill. Claude Code documents the reverse. Codex shows both.

### Reliability

The description is the routing logic, and the published tests show where it fails and what helps.

- **Under-triggering.** In LangChain's tests, a prompt nudge reached 70% invocation. Putting the instruction to use skills in the always-loaded instruction file gave consistent invocation.
- **Confusion between similar skills.** With about 20 similar skills, the agent sometimes called the wrong one. With 12, it consistently called the right one.
- **Structure helps.** Stripe found a modular skill that loads sub-skills on demand beat a single large file by roughly 10% on its evals and used fewer tokens.

When they did load, skills mattered a great deal on LangChain's tasks: 82% completion with skills and 9% without. That figure is for their own tasks and skills, with no task count published.

### Testing a skill

OpenAI's method treats a skill as a prompt and tests it as one ([Testing Agent Skills Systematically with Evals](https://developers.openai.com/blog/eval-skills)):

1. Write 10 to 20 prompts, including some that should not trigger the skill.
2. Run each headless and capture a structured trace of tool calls.
3. Check the trace deterministically: was the skill invoked, were the expected commands run, do the expected files exist.
4. Add a rubric graded by a second model run for qualities the trace cannot show.
5. Compare against a run without the skill.

The consequence for your harness is that it needs a headless mode that emits a machine-readable event stream.

## Hooks

A hook is code the harness runs at a named point in its lifecycle. It receives a description of the event and may answer with a decision. Claude Code's guide states the purpose as "deterministic control: certain actions always happen rather than relying on the LLM to choose to run them" ([Claude Code hooks](https://code.claude.com/docs/en/hooks)).

### The events that matter first

Claude Code documents 33 events and Codex 12. A new harness needs about eight, and for each one the important question is what "block" means.

| Event | Fires | Blocking it means |
| --- | --- | --- |
| `SessionStart` | When a session begins or resumes | Cannot block. Can add context. |
| `UserPromptSubmit` | Before the model sees a prompt | The prompt never reaches the model |
| `PreToolUse` | Before a tool call executes | The call does not run, and the model is told why |
| `PermissionRequest` | When a call needs a permission decision | The hook answers allow or deny in place of the user |
| `PostToolUse` | After a tool call succeeds | Cannot undo the call. Feedback goes to the model. |
| `Stop` | When the model finishes responding | The model is not allowed to stop, and continues |
| `PreCompact` | Before context compaction | Compaction does not happen |
| `SessionEnd` | When the session terminates | Cannot block |

### Configuration

Claude Code and Codex both use three levels: an event, a matcher that selects which occurrences, and one or more handlers.

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PROJECT_DIR}/.claude/hooks/block-rm.sh" }
        ]
      }
    ]
  }
}
```

Hooks from user, project, and managed settings merge. Hooks also fire inside sub-agents, with the agent's ID and type added to the input.

### The protocol

**Input.** One JSON object on standard input:

```json
{
  "session_id": "abc123",
  "transcript_path": "/home/user/.claude/projects/.../transcript.jsonl",
  "cwd": "/home/user/my-project",
  "permission_mode": "default",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_input": { "command": "npm test" },
  "tool_use_id": "toolu_01ABC123..."
}
```

**Output by exit code.**

| Exit code | Meaning |
| --- | --- |
| 0 | No decision. The action proceeds through its normal path. Silence is not approval. |
| 2 | Block, on events that can block. Standard error becomes the reason shown to the model. |
| Anything else | A non-blocking error. The action proceeds. |

The third row is the one that surprises people. Exit code 1 is the usual Unix failure code and it does not block. The reference says so directly: "If your hook is meant to enforce a policy, use `exit 2`." A mistyped script path lands in the same non-blocking bucket, which "leaves the gate silently disabled".

**Output by JSON.** For finer control, a hook exits 0 and prints one JSON object.

| Field | Effect |
| --- | --- |
| `continue: false`, `stopReason` | Stops the agent entirely |
| `decision: "block"`, `reason` | Blocks on prompt, post-tool, stop, and compaction events |
| `hookSpecificOutput.permissionDecision` | On `PreToolUse`: `allow`, `deny`, `ask`, or `defer` |
| `hookSpecificOutput.updatedInput` | Rewrites the tool's arguments before it runs |
| `hookSpecificOutput.updatedToolOutput` | Rewrites the tool's result on `PostToolUse` |
| `hookSpecificOutput.additionalContext` | Adds text the model sees at the point where the hook fired |

Claude Code's advice on `additionalContext` is to write facts. Text phrased as system commands can trip the model's prompt-injection defenses.

### Rules for combining and failing

- **Several hooks on one event run in parallel.** For tool decisions the most restrictive answer wins: `deny`, then `defer`, then `ask`, then `allow`. All added context is kept. If two hooks rewrite the same input, the last to finish wins, so avoid that.
- **A hook can tighten permissions and cannot loosen them.** A hook's deny beats every permission mode. A hook's allow does not override a deny or ask rule.
- **Timeouts fail open in Claude Code.** A command hook is cancelled at 600 seconds by default, its output is discarded, and the tool call continues through the normal permission flow. The docs warn not to count on a stalled hook as a gate. SDK callback hooks are the exception and fail closed.
- **Stop hooks need a loop guard.** The input carries a flag saying a stop hook is already active, and Claude Code caps consecutive continuations at 8.
- **Output is capped.** Each string a hook returns is limited to 10,000 characters. Longer output is saved to a file and replaced with a path and a preview.

### Handler types

A shell command is the base case. Claude Code also accepts an HTTP endpoint that receives the JSON as a POST body, an MCP tool call, a single model prompt, and a sub-agent. An HTTP handler cannot block by status code and must return a decision in a JSON body.

### How the harnesses compare

|  | Claude Code | Codex | OpenClaw plugins | LangChain middleware |
| --- | --- | --- | --- | --- |
| Events | 33 | 12 | About 42 typed hooks | 6 |
| Defined in | JSON settings, plugin files, skill frontmatter | JSON or TOML config, plugin files | Code registered by a plugin | Code |
| Handler | Command, HTTP, MCP tool, prompt, agent | Command, MCP tool | In-process function | In-process function |
| Several at once | Parallel, fixed precedence | Concurrent, any deny wins | Sequential by priority for gates | Composed in order |
| On timeout | Mostly fails open | Stated cases fail open | Gates fail closed | Not applicable |
| Trust | Workspace trust | Each hook definition reviewed by hash | Plugin installed and enabled | Your own code |

Two differences are worth a decision in your own design. Codex requires a user to review each hook definition before it runs and re-review when it changes, which is stricter than trusting a folder. OpenClaw declares the failure policy per hook, so gates fail closed, modifiers are skipped, and observers are only logged.

## MCP

The Model Context Protocol lets a harness use tools served by another process, over standard input and output or over HTTP. Your harness is the client. It connects to servers, lists their tools, presents them to the model, and forwards calls ([MCP specification](https://modelcontextprotocol.io/specification)).

### What a server offers

- **Tools.** Functions the model calls. This is the part every harness implements.
- **Resources.** Data the client can read by URI.
- **Prompts.** Templates the user can invoke.

On the client side, a server may ask the user for input during a call, which the protocol calls elicitation. Two older client features, sampling and roots, are deprecated in the current revision.

A tool definition has a `name`, an optional `title` and `description`, an `inputSchema` whose root is a JSON object schema, an optional `outputSchema`, and optional `annotations`. A result carries content blocks and an `isError` flag.

### The 2026-07-28 revision

The current revision made the protocol stateless. A client written against the 2025 revisions has to change in these places:

| Area | 2025-11-25 | 2026-07-28 |
| --- | --- | --- |
| Start-up | Send `initialize`, read the result, send `initialized` | No handshake. Optionally call `server/discover`. |
| Version and capabilities | Negotiated once | Sent in `_meta` on every request |
| Sessions | Store a session ID and send it on every request | None. State travels as handles in tool arguments. |
| HTTP | POST, an optional GET stream, DELETE | POST only, with `Mcp-Method` and `Mcp-Name` headers |
| Server asks for input | The server sends a request on a held-open stream | The call returns `input_required`. The client gathers answers and re-sends the call. |
| Tool list changes | Notifications arrive unprompted | The client opens a `subscriptions/listen` stream, and list results carry a `ttlMs` freshness value |
| Tool schemas | Simple object schemas | Any JSON Schema 2020-12 keyword. Do not fetch remote references. |
| Lost stream | Resume with an event ID | Re-issue the request |

The payoff, in the release notes' words, is that a remote server "can now run behind a plain round-robin load balancer". The cost to client authors is a transition period in which servers of both kinds exist. The specification's guidance is to probe with `server/discover`, fall back to `initialize` for older servers, and cache which kind each server is. Claude Code does this and still speaks both.

The release-candidate blog post's examples differ from the final specification in places, so code against the specification.

### Transports

- **stdio.** The client launches the server as a child process and exchanges JSON-RPC messages over its standard streams. Local and simple.
- **Streamable HTTP.** The client POSTs to a URL. This is the transport for remote servers.
- **HTTP with SSE.** The older remote transport, now deprecated. OpenClaw still treats a bare URL as SSE, and Claude Code falls back to it automatically.

### How harnesses wire it in

|  | Claude Code | Codex | OpenClaw |
| --- | --- | --- | --- |
| Config | JSON `mcpServers`, with user, project, and local scopes | TOML `[mcp_servers.<name>]` tables | JSON5 `mcp.servers.<name>`, one registry per gateway |
| Tool name shown to the model | `mcp__<server>__<tool>` | Not documented | `<server>__<tool>` |
| Start-up timeout | Configurable | 10 seconds | Not stated |
| Tool call timeout | Effectively unbounded, with an idle timeout and automatic backgrounding after 2 minutes | 60 seconds | 60 seconds |
| Output limit | 25,000 tokens, then saved to a file with a path returned | The model's normal truncation budget, or a per-tool limit | Not found |
| Narrowing a server | Tool search and permission rules | `enabled_tools` and `disabled_tools` per server | Include and exclude filters per server |
| Per-tool approval | The general permission system | `auto`, `prompt`, `writes`, or `approve` per server or tool | The same tool policy as built-in tools |

Three behaviors are worth copying:

- **Namespace every tool by its server**, and sanitize names to the characters model APIs accept.
- **Keep the last good tool list.** When a refresh fails, Claude Code keeps the previous lists.
- **Gate by annotation.** Codex's `writes` mode prompts only for tools not marked read-only. Annotations are hints from the server, so apply this only to servers you trust.

### Authorization

Remote servers use OAuth. The client discovers the authorization server from the resource's metadata, registers or identifies itself, and runs a browser flow with a loopback callback. The current revision prefers client ID metadata documents over dynamic registration and requires the client to validate the issuer on the response. Both Claude Code and Codex also accept static headers and a helper command that prints headers.

OpenClaw adds one feature the single-user tools lack. Because it serves chat channels with many senders, a server can be configured so that each requester authenticates with their own account.

## Scaling a large catalog

Every tool definition in the prompt costs tokens on every turn and makes selection harder. Anthropic's figures are that five common servers can consume about 55,000 tokens of definitions before any work starts, and that tool selection accuracy "degrades once you exceed 30-50 available tools" ([tool search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool)). There are four responses, in increasing order of effort.

### Narrow each server

The cheapest fix is to expose fewer tools. Codex and OpenClaw take allow and deny lists per server in config. Stripe's internal server has nearly 500 tools, and each agent receives a curated subset.

### Defer definitions and search for them

Tool search keeps most definitions out of the context until the model asks.

- **Server-side, in Anthropic's API.** The client sends every definition and marks most with `defer_loading: true`. The model calls a search tool, and the API returns references that it expands into full definitions inside the conversation. Anthropic reports this typically cuts definition tokens by over 85%. Because the expansion happens in the conversation and the prefix is unchanged, the prompt cache survives.
- **Client-side, in OpenClaw.** Three tools, `tool_search`, `tool_describe`, and `tool_call`, sit in front of the catalog. The model finds a tool, reads its schema, and calls it through the wrapper. This works with any model API.

Claude Code defers all MCP tools by default and loads only their names and each server's instructions. The advice from the API docs is to keep the three to five most used tools loaded so the model can call them without searching.

### Call tools from code

The model writes a script that calls several tools and returns only the final result. Anthropic's example cut a workflow from 150,000 tokens to 2,000 ([Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp)). Codex now runs most of its models this way for built-in tools as well. This needs a sandboxed runtime for the script.

### Use a CLI

A command-line tool with a help page has no standing cost. The agent reads the help text when it needs the tool and calls it through the shell.

- Pi has no MCP support by choice. Its author measured two popular servers at 13,700 and 18,000 tokens of tool descriptions each, loaded in every session.
- The team behind OpenAI's agent-built product replaced a browser-automation MCP server with a small CLI because the agent needed only two or three of its operations.
- Stripe's observation applies to anything you ship for agents: the `--help` text is "potentially the only thing the agent reads before acting".

The trade is typed arguments, structured results, and a place to attach permissions, against context cost. MCP earns its place when you need those, and when the server is remote and authenticated.

## Plugins and distribution

A plugin is a directory that bundles skills, hooks, and MCP server definitions under one manifest so they install, enable, and update together. The three harnesses differ most in what a plugin is allowed to be.

|  | Claude Code | Codex | OpenClaw |
| --- | --- | --- | --- |
| Manifest | `.claude-plugin/plugin.json`, with only `name` required | A root `plugin.json` in a portable schema, with an older `.codex-plugin/` form | `openclaw.plugin.json`, mandatory, read without executing plugin code |
| Contents | Skills, agents, hooks, MCP servers, and more | Skills, MCP servers, apps, hooks | In-process code that registers tools, hooks, channels, and providers, plus skills and MCP servers |
| Namespacing | `/<plugin>:<skill>`, and `mcp__plugin_<plugin>_<server>__<tool>` | The plugin name is the namespace | Tools declared by name in the manifest |
| Distribution | A `marketplace.json` catalog in a git repository, pointing at git, npm, or archive sources | A marketplace file, plus a reviewed public directory | Package registries: its own, npm, and git |
| Runs where | Hooks and servers run as separate processes with the user's privileges | Under the host's sandbox and approval policy | Native plugins run inside the gateway process, unsandboxed |

### Design points to take

- **A marketplace can be a file in a repository.** Claude Code's is "a catalog, not a hosted store". It lists plugins and where to fetch them, with pinning by commit.
- **Read the manifest without running the plugin.** OpenClaw requires a manifest it can validate before any plugin code executes, so configuration and capabilities are known in advance.
- **Ask for consent on capabilities, and again when they widen.** OpenClaw shows the channels, tools, hooks, servers, and commands a plugin declares before it is enabled. The consent is tied to a hash of that declared surface, so an update that adds a capability needs fresh consent.
- **Namespace everything a plugin contributes.** Two plugins can then ship a skill or a server with the same name.
- **Copy plugins into a versioned cache.** Both Claude Code and Codex install into a per-version cache directory and give each plugin a separate writable data directory.
- **Accept other formats as content.** OpenClaw maps Claude, Codex, and Cursor plugin layouts into its own as content packs, loads their skills and MCP tools, and does not execute their hook files.

For a first harness, a plugin system can wait. Skills in a known directory, hooks in a settings file, and servers in a config file cover the same ground until you need to distribute them.

## Security

Every extension mechanism is a way for someone else's text or code to reach your agent, so each needs a trust decision before it loads and a boundary after.

### The threat by mechanism

| Mechanism | What can go wrong | Evidence |
| --- | --- | --- |
| Skills | Instructions that direct the agent to exfiltrate data or run harmful commands, and bundled scripts that do it directly | An audit of 3,984 public skills found 534 with a critical issue and 76 confirmed malicious payloads |
| Hooks | Arbitrary code with the user's privileges, run automatically | Claude Code's docs say hooks and plugin processes run outside the sandbox |
| MCP servers | Tool descriptions and results that carry injected instructions, and servers that misreport what their tools do | The MCP team says to ignore annotations from untrusted servers |
| Plugins | All of the above, installed in one step | OpenClaw's docs call a malicious native plugin "equivalent to arbitrary code execution" inside its process |

### Trust before load

- **Gate everything a repository supplies on folder trust.** The Agent Skills guide recommends loading project skills only for trusted folders, to stop "untrusted repositories from silently injecting instructions". Claude Code asks before using a project's MCP servers, and a repository cannot approve its own. Codex loads project config only for trusted projects.
- **Review hooks individually.** Codex skips a hook until the user has reviewed its exact definition, and asks again when it changes.
- **Verify sources, and say what you did not verify.** Claude Code checks marketplace names against a known organization and states that it cannot verify plugin contents. OpenClaw treats its own registry and bundled catalog as trusted and requires a force flag for other sources.
- **Give administrators allowlists.** Each harness lets an organization restrict what may load: marketplaces, hooks, and servers in Claude Code and Codex, and plugin IDs and install sources in OpenClaw.

### Boundaries after load

- **Loading a skill grants nothing.** OpenClaw's docs state that an eligible skill does not grant tool access. Claude Code's `allowed-tools` pre-approval applies to the invoking turn only.
- **Keep server-supplied text out of the system prompt.** OpenClaw does not copy MCP tool names and descriptions into its system prompt, because they are untrusted.
- **Run MCP tools through the same permission rules as built-in tools.** A connected server should not bypass policy.
- **Be careful with skills plus open network access.** OpenAI calls that combination a high-risk path for data exfiltration and recommends tight allowlists.
- **Do not fetch remote schema references.** The MCP specification tells clients not to dereference external references in tool schemas and to bound validation cost.
- **Keep credentials out of expansion.** Claude Code never expands credential environment variables into a remote server's URL or headers.

### The human in the loop

The MCP specification says applications should make clear which tools are exposed to the model and should present confirmation prompts so that a human can deny an invocation. That requirement lands on your permission system. The harness guide's safety section and its sandbox are the controls that make third-party extensions tolerable: a skill or server that turns hostile can then do only what the sandbox and the permission rules allow.

## How real harnesses do it

This table condenses the three harnesses across the three mechanisms, as of the documentation and source read on 2026-10-03.

|  | Claude Code | Codex | OpenClaw |
| --- | --- | --- | --- |
| Skill locations | `~/.claude/skills/`, `.claude/skills/` up to the repository root, nested directories loaded lazily, plugins | `.agents/skills` from the working directory up to the repository root, `~/.agents/skills`, system, plugins | The workspace's `skills/` and `.agents/skills`, `~/.agents/skills`, a managed directory, bundled, plugins |
| How a skill is loaded | A dedicated Skill tool, subject to permission rules | The model reads the listed file | The model reads the listed file, or calls a skills tool |
| User invocation | `/skill-name` | `$skill` | `/skill <name>` or `/name` |
| Skill extras | Many frontmatter fields, sub-agent execution, shell-injected context | A sidecar file for display and policy | Load-time gating on binaries, environment, and OS |
| Hook events | 33 | 12 | About 42 in plugin code, plus simple event handlers |
| Hook handlers | Command, HTTP, MCP tool, prompt, agent | Command, MCP tool | In-process functions |
| Hook trust | Folder trust | Review of each definition by hash | Plugin enablement |
| MCP transports | stdio, Streamable HTTP, SSE fallback, WebSocket | stdio, Streamable HTTP | stdio, SSE, Streamable HTTP |
| Large MCP catalogs | Tool search on by default, all MCP tools deferred | Per-server allow and deny lists | Per-server filters and a three-tool search layer |
| MCP revision | Speaks both 2026-07-28 and the older revisions | Not stated | Not stated |

### What is distinctive about each

- **Claude Code** has the widest surface: the most hook events and handler types, the most skill options, and server-side tool search. Its documentation is also the most explicit about edge cases, such as which exit codes block.
- **Codex** is the most conservative about trust. Hooks need per-definition review, project config loads only in trusted projects, and MCP tools have per-tool approval modes.
- **OpenClaw** is built for a long-running multi-user gateway. Skills are gated by what is installed, MCP supports per-requester identity, plugin hooks declare their own failure policy, and plugins declare capabilities for consent.
- **Pi**, covered in the core tools guide, is the counter-example. It has no MCP support and no permission system by design, on the argument that command-line tools with README files give the agent the same capabilities at lower context cost.

## Starter design

Add the three mechanisms in the order of their cost: skills first because they are a prompt block and a file read, hooks second because they are one protocol, and MCP last because it is a network client. This section is my synthesis of the sources, so treat it as a starting design to test.

&#91;embedded content: extension points · hooks, skills, and MCP servers around the agent loop\]

The skill catalog enters the prompt at session start, and a skill's body arrives later as an ordinary file read. MCP tools are reached through tool calls, so the tool hooks and the permission rules apply to them as well.

### Build order

1. **Skill discovery and catalog.** Scan `.agents/skills/` in the project and the home directory. Parse frontmatter leniently. Put names, descriptions, and paths in the system prompt under a character budget, and let the model read `SKILL.md` with its normal read tool.
2. **User invocation and protection.** Let the user load a skill by name. Mark loaded skill content so compaction keeps it, and skip duplicates.
3. **Three hook events.** Implement `PreToolUse`, `PostToolUse`, and `Stop` as shell commands configured in a settings file. Send one JSON object on standard input. Honor exit 0, exit 2, and a small JSON output with a decision and added context.
4. **Hook rules.** Run hooks for an event in parallel, take the most restrictive decision, give each a timeout, and decide per event whether a timeout fails open or closed. Add a loop guard on `Stop`.
5. **Trust.** Load project skills and project hooks only after the user has trusted the folder.
6. **An MCP client over stdio.** Launch configured servers, list their tools, namespace each as `server__tool`, cap their output, and route calls through the same permission rules as built-in tools.
7. **Streamable HTTP and authorization.** Add remote servers with static headers first, then OAuth.
8. **Both protocol eras.** Probe each server for the 2026-07-28 revision and fall back to the handshake. Using an official SDK gets you this without writing it.
9. **Catalog control.** Add per-server allow and deny lists, then tool search when definitions exceed a share of the context.
10. **Plugins.** Add a manifest and an install command once you have something to distribute.

### Defaults to adopt until you have evidence otherwise

| Decision | Default | Reason |
| --- | --- | --- |
| Skill directory | `.agents/skills/`, plus your own | The cross-client convention |
| Skill activation | The model's ordinary read tool | No new tool, and the catalog carries the path |
| Skill catalog budget | 1 to 2% of the context window | Claude Code's and Codex's limits |
| Number of similar skills | A dozen or fewer | LangChain saw wrong-skill calls at about 20 |
| Rules that must hold | A hook | Skills and instruction files are advice |
| Hook block signal | Exit code 2 | The convention Claude Code and Codex share |
| Hook timeout on a gate | Fail closed | A stalled gate that fails open is no gate |
| Hook and permission conflict | A hook may deny and may not override a deny | Claude Code's rule |
| MCP tool names | Prefixed by server | Avoids collisions and enables per-server rules |
| MCP tool definitions | Deferred once they are large | Keeps the cached prefix stable and small |
| MCP library | An official SDK | The protocol changed in 2026 and will again |
| Anything from a repository | Off until the folder is trusted | Stops a cloned repository from configuring your agent |

The hook timeout default departs from Claude Code, which fails open for command hooks. Failing closed is safer for a policy gate and more annoying when a hook is slow, so make it a per-hook setting.

## Open questions and disagreements

The sources agree on progressive disclosure, on hooks for enforcement, and on distrust of third-party content. They disagree on the points below.

- **MCP or a CLI.** Pi's author rejects MCP for its standing context cost. Tool search removes most of that cost in harnesses that have it. No source compares task outcomes between a server and an equivalent CLI.
- **A dedicated skill tool or a file read.** Claude Code loads skills through a tool that permission rules can govern. Codex and OpenClaw let the model read the file. The Agent Skills guide presents both as valid.
- **Whether the model should decide when to load a skill.** Every harness relies on the model's judgment, and LangChain's 70% figure shows the limit. Nobody has published a harness-side trigger that does better.
- **Fail open or fail closed.** Claude Code's command hooks fail open on timeout. OpenClaw's gates fail closed. Each choice breaks something.
- **Folder trust or per-item review.** Claude Code trusts a folder once. Codex reviews each hook definition. The second is safer and adds friction.
- **Whether project skills override user skills.** The guide and OpenClaw say yes, and Claude Code says no.
- **How much of MCP to implement.** Sampling and roots are deprecated, tasks moved to an extension, and elicitation changed shape. A client that implements tools, and elicitation when a server needs it, covers most servers. That is my reading, and the specification does not rank the features.

The evidence is thin on outcomes. The skill results are vendor reports on their own tasks. The hook systems are documented in detail and their effect on agent reliability is not measured anywhere in these sources. The one MCP deployment paper in the list is a position paper with no measurements.

## Sources

All sources were read from full page text or source code on 2026-10-03 unless noted. The hooks, MCP, and plugin sections of the research notes were compiled by parallel readers and spot-checked.

### Skills

- [Agent Skills specification and client implementation guide](https://agentskills.io), and [anthropics/skills](https://github.com/anthropics/skills).
- [Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), Anthropic, Oct 2025.
- [Claude Code skills](https://code.claude.com/docs/en/skills).
- [Codex skills](https://learn.chatgpt.com/docs/build-skills).
- [OpenClaw](https://github.com/openclaw/openclaw) skills documentation, commit `74db989c`.
- [Testing Agent Skills Systematically with Evals](https://developers.openai.com/blog/eval-skills), OpenAI, Jan 2026. It uses skill paths that the current Codex docs have since changed.
- [Evaluating Skills](https://www.langchain.com/blog/evaluating-skills), LangChain, Mar 2026. Results are for the authors' own tasks.
- [You can't whisper at an AI agent](https://stripe.dev/blog/ai-steering-experiments), Stripe, May 2026.
- [SkillTester: Benchmarking Utility and Security of Agent Skills](https://arxiv.org/abs/2603.28815), Mar 2026. It reports no results of its own. The audit numbers are cited from Snyk.

### Hooks

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) and [hooks guide](https://code.claude.com/docs/en/hooks-guide).
- [Codex hooks](https://developers.openai.com/codex/hooks).
- OpenClaw plugin hook documentation, in the repository above.
- [How Middleware Lets You Customize Your Agent Harness](https://www.langchain.com/blog/how-middleware-lets-you-customize-your-agent-harness), LangChain, carried over from the harness guide.

### MCP

- [MCP specification](https://modelcontextprotocol.io/specification), revision 2026-07-28, and the 2025-11-25 revision for comparison.
- MCP blog: [the 2026 roadmap](https://blog.modelcontextprotocol.io/posts/2026-mcp-roadmap/) and [the release candidate](https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/). Some examples in the release-candidate post do not match the final specification.
- [Claude Code MCP](https://code.claude.com/docs/en/mcp).
- [Tool search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool), Claude API.
- Codex MCP configuration, in the Codex docs.
- [Bridging Protocol and Production: Design Patterns for Deploying AI Agents with Model Context Protocol](https://arxiv.org/abs/2603.13417), Mar 2026. A position paper, not used for claims.
- [Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp) and [Tool Annotations as Risk Vocabulary](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/), carried over from the harness guide.

### Plugins

- [Claude Code plugins](https://code.claude.com/docs/en/plugins) and its reference and marketplace pages, some read in part.
- Codex plugin documentation at developers.openai.com.
- OpenClaw plugin documentation, read in part.
- [Codex as a platform](https://developers.openai.com/blog/codex-as-a-platform), OpenAI, Aug 2026. It does not cover skills, hooks, or plugins and is not used for claims here.
