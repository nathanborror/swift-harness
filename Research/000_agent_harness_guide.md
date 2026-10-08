# Agent Harness Engineering Guide

Oct 3, 2026 · @Nathan Borror

## What a harness is

A harness is everything around the model that turns text prediction into finished work: the loop that calls the model, the tools it can use, the context it is shown, and the controls on what it may do. LangChain's shorthand is "Agent = Model + Harness", and "if you're not the model, you're the harness" ([The Anatomy of an Agent Harness](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness)).

The word is used in two senses, and it helps to keep them apart. Birgitta Böckeler separates the *builder harness*, which is the system prompt, tools, and orchestration inside a product like Claude Code or Codex, from the *user harness*, which is the rules files, linters, and review steps a team wraps around such a product ([Harness engineering for coding agent users](https://martinfowler.com/articles/harness-engineering.html)). This guide is about the builder harness, the one you write yourself. It borrows from the user-harness literature wherever the ideas transfer.

Harness work has become its own discipline because it moves results while the model stays fixed:

- LangChain raised a coding agent from 52.8% to 66.5% on Terminal-Bench 2.0 by changing only the harness around gpt-5.2-codex ([Improving Deep Agents with Harness Engineering](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering)).
- Anthropic found that container resource limits alone moved Terminal-Bench 2.0 scores by 6 percentage points ([Quantifying Infrastructure Noise](https://www.anthropic.com/engineering/infrastructure-noise)).
- Microsoft's SRE agent and Anthropic's own Claude Code postmortem, both covered below, show the same effect in production in each direction.

After the core principles, each section takes one part of a harness: what the sources agree on, where they differ, and what to build first. The starter blueprint then assembles the parts and gives a build order. Sources are linked where a claim or number comes from one of them, and the full reading list is at the end.

## Core principles

Eight ideas recur across the foundation articles, and the rest of this guide applies them component by component.

1. **Start with the simplest thing that works.** Anthropic's advice since 2024 is to use "simple, composable patterns rather than complex frameworks" and to begin with direct API calls, because agents are "typically just LLMs using tools based on environmental feedback in a loop" ([Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)). Add structure only when a measured failure calls for it.
2. **Every component encodes an assumption about what the model cannot do, and those assumptions expire.** Context resets were essential for Sonnet 4.5 and dead weight by Opus 4.5. Sprint decomposition was needed on Opus 4.5 and removed on 4.6 ([Harness Design for Long-Running Application Development](https://www.anthropic.com/engineering/harness-design-long-running-apps)). On each model upgrade, remove one component at a time and measure.
3. **Fix the harness when the agent fails.** Mitchell Hashimoto's formulation is that each time an agent makes a mistake, you engineer a solution so it never makes that mistake again. Red Hat's version is "Fix the harness, not just the output" ([Red Hat](https://developers.redhat.com/articles/2026/04/07/harness-engineering-structured-workflows-ai-assisted-development)). A failure you only correct by hand will recur.
4. **Context is a finite budget.** Recall degrades as the window fills, so the goal is "the smallest set of high-signal tokens" for the next step ([Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). Most harness features are ways of keeping low-value tokens out of the window.
5. **Give the model general tools it already knows, and add dedicated tools where the harness needs a hook.** A shell and a file editor cover most work. A typed, dedicated tool earns its place when the harness must gate, render, or audit an action ([3 Patterns](https://claude.com/blog/harnessing-claudes-intelligence)).
6. **Enforce in code what must always happen.** Prompts make behavior more likely. Hooks, middleware, and permission rules make it certain. LangChain built its middleware layer because "some things can't live in a prompt", and it puts call caps and retries there ([How Middleware Lets You Customize Your Agent Harness](https://www.langchain.com/blog/how-middleware-lets-you-customize-your-agent-harness)).
7. **Contain the agent with boundaries, then steer it with instructions.** Anthropic's rule is "design for containment at the environment layer first, then steer behavior at the model layer" ([How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude)). A sandbox holds even when a prompt injection succeeds.
8. **Separate the doer from the judge, and measure everything.** Agents grade their own work generously, so verification needs ground truth from the environment or a separately tuned evaluator. Harness changes need traces and evals for the same reason, because a single system-prompt line can cost 3% on a coding eval ([Claude Code postmortem](https://www.anthropic.com/engineering/april-23-postmortem)).

## The agent loop

The loop is the smallest part of a harness: call the model, run the tool calls it asks for, append the results, and repeat until it replies without calling a tool. OpenAI's guide says "this concept of a while loop is central to the functioning of an agent" ([A practical guide to building agents](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf)).

The vocabulary differs slightly by product. In Codex a *thread* is a conversation and a *turn* runs from user input to the assistant's final message, with many model calls inside it ([Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/)). This guide calls each model call inside a turn a *step*.

&#91;embedded content: agent loop · one turn, 7 steps, 1 decision\]

Every pass appends to the history. The turn also ends on a step cap, a budget limit, or a user interrupt.

### A minimal loop

This sketch is mine, assembled from the Codex write-up and the practices below. It is a starting shape and it omits streaming and concurrency.

```python
def run_turn(session, user_message):
    session.append(user(user_message))
    for step in range(MAX_STEPS):
        if session.token_count() > COMPACT_AT:
            session.compact()
        reply = model.call(
            system=session.system,      # static: stays cached
            tools=session.tools,        # static: stays cached
            messages=session.messages,  # append-only
        )
        session.append(reply)           # keep reasoning items too
        if not reply.tool_calls:
            if hooks.before_stop(session) == "continue":
                continue                # e.g. verification not yet run
            return reply.text
        for call in reply.tool_calls:
            decision = permissions.check(call)   # allow | ask | deny
            if decision == "ask":
                decision = ui.confirm(call)
            if decision == "allow":
                result = tools.run(call)         # executes in the sandbox
            else:
                result = denied(call)            # explain why, suggest a safer path
            session.append(tool_result(call.id, bound(result)))
    return escalate("step limit reached")
```

### Rules the loop should keep

- **History is append-only.** In Codex, "the old prompt is an exact prefix of the new prompt", which is what makes prompt caching work. A change of working directory or permission mode is appended as a new message, never edited into an earlier one.
- **Every tool call gets a result.** Errors, timeouts, and denials go back to the model as ordinary tool results. VS Code's team notes that some models break on a tool call left without one.
- **Reasoning stays in the history.** Codex appends the model's reasoning items alongside each call and result. When a Claude Code bug dropped earlier reasoning, users saw "forgetfulness, repetition, and odd tool choices".
- **Stop conditions are explicit.** The normal exit is a reply with no tool calls. Add a step limit, a budget, a user interrupt, and an escalation after repeated denials or failures.
- **Events are streamed.** Codex turns the model's stream into internal event objects, which drive the UI and are later appended to the history.

### Guards inside the loop

These are small pieces of code that LangChain and others found necessary once agents ran unattended:

- A cap on model and tool calls, which ends a looping run before it times out.
- A single automatic retry for a transient tool failure.
- Loop detection, such as counting edits to the same file and suggesting a different approach after several.
- Time or budget warnings injected as messages, because agents estimate elapsed time poorly.
- A pre-completion check that intercepts the agent's attempt to stop and requires verification first.

### Hooks

A harness needs places to attach this kind of logic without rewriting the loop. LangChain's middleware defines six, and they map onto any loop ([How Middleware Lets You Customize Your Agent Harness](https://www.langchain.com/blog/how-middleware-lets-you-customize-your-agent-harness)):

| Hook | Fires | Typical use |
| --- | --- | --- |
| `before_agent` | Once at the start | Load memory, validate input |
| `before_model` | Before each model call | Trim history, redact PII |
| `wrap_model_call` | Around each model call | Retries, fallbacks, dynamic tool selection |
| `after_model` | After the reply, before tools run | Human approval |
| `wrap_tool_call` | Around each tool execution | Permission gates, result rewriting |
| `after_agent` | Once at the end | Save results, notify, clean up |

### Loops around the loop

The turn is one loop. Anthropic describes three more that wrap it ([Getting started with loops](https://claude.com/blog/getting-started-with-loops)). A goal-based loop runs until an evaluator model confirms a stated condition each time the agent tries to stop. A time-based loop re-runs a prompt on an interval. A proactive loop is triggered by an event or schedule with no human present.

The "Ralph loop" is the fresh-context version of a goal loop. The harness intercepts the agent's exit and re-injects the original prompt in a clean context window, and each iteration picks up state from files the previous one wrote ([LangChain](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness)).

## Tools and the agent-computer interface

Tool design deserves as much effort as the system prompt, and usually more. On their SWE-bench agent, Anthropic "spent more time optimizing our tools than the overall prompt" ([Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)).

### Start with a small general set

A shell and a file editor go a long way. Claude 3.5 Sonnet reached 49% on SWE-bench Verified in late 2024 "with only a bash tool and a text editor tool", and Claude Code is still grounded in those two ([3 Patterns](https://claude.com/blog/harnessing-claudes-intelligence)). A practical starter set is:

- `shell`: run a command in the sandbox.
- `read_file`: read a file or a line range.
- `edit_file`: replace an exact string, or apply a patch.
- `search`: find files by name and content.
- `task`: delegate to a sub-agent.
- `update_plan`: maintain a visible task list.

The edit tool is model-specific. VS Code's Copilot harness gives Claude models a string-replace tool and GPT models `apply_patch`, because each family was trained with its own ([VS Code](https://code.visualstudio.com/blogs/2026/05/15/agent-harnesses-github-copilot-vscode)). If you support several model families, plan for a tool profile per family.

### General tools versus dedicated tools

The 2025 advice was to build consolidated, purpose-built tools. The 2026 advice is to default to the shell and code execution, and to promote an action to a dedicated tool when the harness needs something from it. Anthropic states the trade this way: a bash tool "gives the harness only a command string", while a dedicated tool gives it "an action-specific hook with typed arguments it can intercept, gate, render, or audit".

Code execution also lets the model filter its own tool output before it reaches the context window. On BrowseComp, that took Opus 4.6 from 45.3% to 61.6% accuracy.

Make a dedicated tool when you need one of these:

- **A security gate.** Hard-to-reverse actions get a typed tool that can require confirmation.
- **A staleness check.** An edit tool can refuse to overwrite a file that changed since the model last read it.
- **A user interface.** A question to the user can render as a dialog and block the loop until answered.
- **An audit trail.** Typed arguments can be logged, traced, and replayed.

### Rules for each tool

These come from Anthropic's tool-writing guide and hold for either approach ([Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)).

- **Give each tool one clear purpose.** If a human engineer cannot say which of two tools applies, the model cannot either.
- **Design for the task.** One `schedule_event` tool beats `list_users`, `list_events`, and `create_event` chained by the model.
- **Make mistakes hard.** Name parameters unambiguously (`user_id`, not `user`). Requiring absolute paths fixed a class of errors after the agent changed directories.
- **Return what the model can use.** Prefer names over UUIDs. Offer a `response_format` of `concise` or `detailed`; in Anthropic's Slack example the concise form used about a third of the tokens.
- **Bound every response.** Paginate, filter, and truncate with sensible defaults. Claude Code caps tool responses at 25,000 tokens. A truncated response should say so and suggest how to narrow the query.
- **Write errors that explain the fix.** Return what failed, why, and an example of valid input, as a normal tool result.
- **Offload large outputs.** Keep the head and tail in context and write the full output to a file the model can read later ([LangChain](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness)).

Where guidance sits matters as much as what it says. In LangChain's tuning work, a rule placed in the `read_file` description "did nothing", and the same words appended to the tool's result worked ([playbook](https://www.langchain.com/blog/tuning-the-harness-not-the-model-a-nemotron-3-ultra-playbook)). That result is for one model, so treat it as a hypothesis to test: descriptions help the model choose a tool, and results steer what it does next.

### Scaling the catalog: MCP, tool search, and skills

Every tool definition costs context on every turn, and overlapping tools confuse selection. Three techniques keep a large catalog out of the window until it is needed:

- **Tool search.** The agent starts with a search function and loads full definitions only for the tools it needs. This also preserves the prompt cache, because new definitions are appended.
- **Code execution over MCP.** Tools are presented as files of code the agent can browse and call from a script. Anthropic's example cut a workflow from 150,000 tokens to 2,000 ([Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp)).
- **Skills.** A skill is a folder with a `SKILL.md` and optional scripts. Only its name and description are preloaded, and the body is read when the task calls for it.

A skill's description is routing logic. OpenAI recommends writing "use when" and "don't use when" cases into it, and reports that Glean saw skill triggering drop 20% until negative examples were added ([Shell + Skills + Compaction](https://developers.openai.com/blog/skills-shell-tips)). Skills and MCP servers from third parties are also an injection and supply-chain path, so read what you install.

MCP tool annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint`) are a ready-made risk vocabulary for permission rules. They are hints, and the MCP team's guidance is to ignore them from servers you do not trust ([Tool Annotations as Risk Vocabulary](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/)).

### Develop tools with evals

Anthropic's process is to prototype the tools, write a few dozen realistic multi-step tasks, run each in a simple loop, and read the transcripts. Track tool-call counts, tool errors, and tokens per task alongside accuracy. Many redundant calls point at pagination or limits. Many invalid-parameter errors point at descriptions. Then hand the transcripts to a coding agent and let it rewrite the tools, with a held-out task set to catch overfitting.

## Context engineering

Context engineering decides what the model sees at each step, and it is where most harness quality is won or lost. Microsoft's SRE team put it this way after a year of production work: "we thought we were building an SRE agent. In reality, we were building a context engineering system that happens to do Site Reliability Engineering" ([Context Engineering Lessons from Building Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/context-engineering-lessons-from-building-azure-sre-agent/4481200/)).

The constraint is context rot: as the window fills, the model recalls what is in it less accurately. One practitioner report puts tool outputs at 70 to 80% of the context in a typical coding session ([Building Effective AI Coding Agents for the Terminal](https://arxiv.org/abs/2603.05344)), so that is where most of the savings are.

### What goes in the window, and in what order

Codex assembles its prompt in this order ([Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/)):

1. Base instructions for the specific model.
2. Tool definitions.
3. A permissions message describing the sandbox and when to ask for approval.
4. Developer instructions from user configuration.
5. Project instructions: `AGENTS.md` files from the repository root down to the working directory, capped at 32 KiB by default, plus the name and description of each skill.
6. Environment context, such as the working directory and shell.
7. The user's message, followed by everything the loop appends.

Stable content comes first and changing content last. That ordering is what makes caching work.

### Prompt caching is a design constraint

Model APIs are stateless, so the harness resends the whole conversation on every step. Caching makes that affordable. Cached tokens cost 10% of base input tokens on Anthropic's API, and a cache hit requires an exact prefix match. In OpenAI's 25-hour Codex run, cached input was about 268 million tokens against 10.7 million uncached ([Run long horizon tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex)).

Both vendors give the same rules:

- Keep the system prompt and tool list byte-identical for the whole session. Codex once had a bug where MCP tools were listed in an inconsistent order, which caused cache misses.
- Do not switch models mid-session. Use a sub-agent when a cheaper model will do.
- Deliver changes as appended messages. Codex appends a new permissions or environment message, and Anthropic recommends a `<system-reminder>` in the message stream.
- Add tools through tool search, which appends definitions.

Any feature that edits earlier history breaks the cache from that point on. The Claude Code pruning bug degraded behavior and also caused the cache misses that made usage limits drain faster.

### Instruction files are a map

Keep the always-loaded instruction file short and let it point elsewhere. OpenAI's team tried one large `AGENTS.md` and it failed: it crowded out the task, it marked everything as important, and it went stale. Their working version is about 100 lines and acts as a table of contents into a `docs/` directory. Their summary is "give Codex a map, not a 1,000-page instruction manual" ([Harness engineering](https://openai.com/index/harness-engineering/)).

For the system prompt itself, Anthropic's guidance is to start minimal with the best model and add instructions only for failures you have observed. LangChain found broad prompt rewrites "the most overrated" lever, and short single-purpose blocks aimed at one observed failure the ones that survived.

Instructions in the system prompt also fade over a long session. The OpenDev paper reports better compliance from short reminders injected as user-role messages when a detector fires, such as five consecutive reads with no action or a completion attempt with open to-dos. It caps each reminder, because uncapped reminders made the agent loop on the reminder itself.

### Load context just in time

Give the agent identifiers and the means to fetch: file paths, search tools, and links. Claude Code loads its instruction file up front and finds everything else at run time with glob and grep. Runtime exploration is slower than pre-computed retrieval, but it does not go stale and it needs no index.

Microsoft's SRE agent is the strongest case study. Its first version had more than 100 narrow tools "and a prompt that read like a policy manual". The version that worked had a few wide tools (the `az` and `kubectl` CLIs and a code interpreter), with domain knowledge moved out of the system prompt into files the agent reads on demand.

### Keep tool output out of the window

- **Bound and offload.** Cap every tool result, and write anything large to a file with a short preview and the path. Microsoft never puts a large payload in context: the model "sees a reference to a session and a set of tools to interact with that session".
- **Let code do the reading.** Metrics analysis was Microsoft's largest source of tool failures until the model wrote pandas code against the data and saw only the result.
- **Clear old tool results.** Replacing stale results with a pointer is the safest light form of compaction.
- **Delegate.** A sub-agent's exploration stays in its own window.

### Compaction

When the conversation nears the limit, the harness replaces it with a shorter representation and continues. Codex began with a manual `/compact` command that asked the model for a summary and used it as the new history, and now compacts automatically past a configured limit.

The OpenDev paper describes a staged version, with thresholds as a fraction of the window. Its numbers are one author's unreplicated settings, and the structure is the useful part:

| Stage | At | Action |
| --- | --- | --- |
| Warn | 70% | Log only |
| Mask | 80% | Replace older tool results with short reference pointers |
| Prune | 85 to 90% | Shrink the set of recent results kept verbatim |
| Compact | 99% | Save the full history to a file, then summarize the middle and keep recent messages verbatim |

Its summary follows a fixed template: objective, key decisions and rationale, files and commands, user messages preserved nearly verbatim, progress, open issues, and next step. It also includes the path to the archived history and an index of files touched, so the agent can recover anything the summary lost.

Three cautions apply:

- **Summaries lose things.** In a controlled ablation, adding file-backed state helped on both benchmarks tested, and adding context compression hurt on both ([Natural-Language Agent Harnesses](https://arxiv.org/abs/2603.25723)). Write state to files before compacting.
- **Compaction quality depends on the model.** On BrowseComp, Sonnet 4.5 stayed at 43% regardless of compaction budget, while Opus 4.6 reached 84% with the same setup.
- **A full reset is the alternative.** Starting a fresh agent from a structured handoff file was essential for Sonnet 4.5, which wrapped up early as it sensed its limit, and unnecessary from Opus 4.5 on.

### Memory across sessions

The sources converge on plain files. A memory folder the model reads and writes lifted Sonnet 4.5 from 60.4% to 67.2% on BrowseComp-Plus. A project instruction file the agent may edit is reloaded on the next start. A survey of 70 agent systems found hybrid designs (27%) and plain file persistence (23%) to be the most common context strategies, with vector databases at 10% ([Architectural Design Decisions in AI Agent Harnesses](https://arxiv.org/abs/2604.18071)).

Memory quality tracks model quality. After 14,000 steps of Pokémon, Sonnet 3.5 had 31 near-duplicate note files, and Opus 4.6 had 10 organized files including a learnings file distilled from failures.

Treat what the agent writes about itself with care. Ryan Lopopolo's field guide has agents record mistakes, learnings, and wishes, and treats those files as telemetry for the harness builder. It warns against injecting them into later runs unreviewed, because an incorrect learning then reinforces itself as an instruction ([lopopolo/harness-engineering](https://github.com/lopopolo/harness-engineering)).

## Long-running work

Work that outlasts one context window survives on files: a spec, a plan with a check for every milestone, and a status log that the agent re-reads at the start of each session and after each compaction. Lilian Weng states the rule as "a harness should not carry the entire workflow and all logs in context; instead, it should keep durable state in files" ([Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/)).

### How long runs fail

Anthropic observed two failures when an agent was simply looped across sessions ([Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)). The agent tried to build everything at once and ran out of context mid-feature, leaving undocumented half-finished work. Later sessions saw progress and declared the project done.

### The file stack

OpenAI's Codex team ran one task for about 25 hours, 13 million tokens, and 30,000 lines of code on four markdown files ([Run long horizon tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex)). The author calls it an experiment, and it ran with approvals off in a throwaway environment.

| File | Purpose | Contents |
| --- | --- | --- |
| `prompt.md` | Freeze the target | Goals and non-goals, hard constraints, deliverables, and "done when" checks |
| `plans.md` | Turn the work into checkpoints | Milestones small enough to finish in one loop, each with acceptance criteria and validation commands, plus a decision log |
| `implement.md` | Tell the agent how to operate | Follow the plan, keep diffs scoped, validate after each milestone, fix failures before moving on |
| `documentation.md` | Shared memory and audit log | Current status, decisions and reasons, how to run, known issues |

Anthropic's version uses different files for the same jobs. An initializer agent runs once and writes a feature list of more than 200 entries, each with verification steps and a `passes` flag that starts false. It also writes a progress log and an `init.sh` that starts the app and runs a smoke test. Every later session is a coding agent that follows a fixed routine:

1. Confirm the working directory.
2. Read the progress log and recent git history.
3. Pick the highest-priority feature that does not pass.
4. Start the app and run the smoke test, and fix anything broken before new work.
5. Implement one feature, verify it end to end, then commit and update the log.

The agent may change only the `passes` flag in the feature list. Editing or removing a test is forbidden, because otherwise it will.

### Rules that make it work

- **One milestone at a time, verified.** A stop-and-fix rule says a failed validation is repaired before the next milestone starts.
- **Record decisions.** A decision log stops the agent from oscillating between approaches across compactions. OpenAI's runbook says to make a reasonable decision when something is ambiguous and write it in the plan before coding.
- **Leave a clean state.** Each session ends with code that could be merged, a commit, and an updated log.
- **Keep plans in the repository.** OpenAI's product team checks execution plans into `docs/exec-plans/active/` and `completed/`, so plans are versioned next to the code they describe.

### Plan before the run, and review the plan

A plan is the cheapest place for a human to intervene. Red Hat has the agent produce a short map of which repositories and files a change will touch, and a person reviews it before any task exists. Their reasoning is that "catching a wrong assumption in a three-line impact map costs far less than catching it in a pull request" ([Red Hat](https://developers.redhat.com/articles/2026/04/07/harness-engineering-structured-workflows-ai-assisted-development)). Meta's ranking agent proposes its experiment plan with an estimated GPU cost and waits for an engineer to confirm before it runs for days ([Meta](https://engineering.fb.com/2026/03/17/developer-tools/ranking-engineer-agent-rea-autonomous-ai-system-accelerating-meta-ads-ranking-innovation/)).

Keep the plan at the right level. Anthropic's planner agent writes product scope and high-level design and leaves implementation detail to the builder, because a wrong detail in the spec cascades into everything built on it.

Inside a session, a to-do tool does the same job at small scale. Codex ships an `update_plan` tool, and Microsoft keeps the plan "as an explicit checklist outside the model's context" that the model updates instead of re-deriving.

### Runs that outlive the process

Multi-day work also needs the harness itself to stop and resume.

- **Make the session log the source of truth.** Anthropic's Managed Agents keeps an append-only event log outside both the harness and the sandbox. A crashed harness is restarted with `wake(sessionId)` and rebuilds its context from the log ([Scaling Managed Agents](https://www.anthropic.com/engineering/managed-agents)).
- **Hibernate while waiting.** Meta's agent hands a multi-hour training job to a background system, shuts down, and resumes when the job completes. The post does not describe the checkpoint format.
- **Give background jobs a process manager.** Weng's list is launch, inspect logs, cancel, and merge results, with outputs stored as files and status records so the agent can recover after an interruption.

### Entropy

Agents copy the patterns they find, including bad ones, so a long-lived codebase drifts. OpenAI's team spent every Friday cleaning up before they automated it. They now encode "golden principles" in the repository and run recurring background agents that scan for deviations and open small refactoring pull requests. Budget for this once your harness is producing most of the code.

## Sub-agents and multi-agent orchestration

A single agent with good tools is the default, and sub-agents are worth adding for two reasons: isolating context and running work in parallel. LangChain's ordering is "add tools before adding agents. Graduate to multi-agent patterns only when you hit clear limits" ([Choosing the Right Multi-Agent Architecture](https://www.langchain.com/blog/choosing-the-right-multi-agent-architecture)).

### What a sub-agent buys

A sub-agent is a fresh context window that does a focused job and returns only its result. It may use tens of thousands of tokens exploring and hand back a 1,000 to 2,000 token summary ([Effective Context Engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)). HumanLayer calls this a "context firewall": the failed attempts and raw search results never reach the parent. With Opus 4.6, spawning sub-agents improved BrowseComp results by 2.8% over the best single-agent runs ([3 Patterns](https://claude.com/blog/harnessing-claudes-intelligence)).

The costs are real. Each delegation adds model calls, the parent sees a summary instead of the evidence, and the sub-agent knows only what its brief says. Anthropic's three-agent app-building harness cost about 20 times the solo run.

### Patterns

| Pattern | How it works | Use it when |
| --- | --- | --- |
| Sub-agent as a tool | The main agent calls a sub-agent like any tool. The sub-agent is stateless and returns one result. | Research, codebase exploration, any task whose intermediate output would flood the parent |
| Orchestrator and workers | A lead agent decides the subtasks at run time, delegates, and synthesizes | You cannot predict the subtasks in advance, such as which files a change touches |
| Planner, generator, evaluator | One agent writes the spec, one builds, one tests the running result against agreed criteria | Long builds at the edge of what the model does reliably alone |
| Parallel peers | Many identical agents share a repository and claim tasks | A large backlog of independent, well-tested work items |
| Blueprint | A state machine mixes fixed code steps with agent steps | Unattended runs where lint, push, and CI must always happen |
| Handoffs and routers | The active agent changes, or a classifier dispatches to specialists | Conversational products with distinct stages or domains |

Two of these come with useful detail. Carlini ran 16 parallel Claude instances that claimed work by writing lock files to a `current_tasks/` directory, with git push conflicts providing mutual exclusion and no central orchestrator ([Building a C compiler](https://www.anthropic.com/engineering/building-c-compiler)). Stripe's blueprints run deterministic nodes for linting and pushing around agent nodes such as "implement task" and "fix CI failures", and allow at most two CI rounds before a human takes over ([Minions, part 2](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2)).

### Rules for your own harness

- **Expose delegation as one tool.** A `task(description, prompt, agent_type)` tool that runs a nested loop in a fresh context and returns the final message is enough for a first version.
- **Write the brief as if it were the only context, because it is.** State the goal, what is already known, and the shape of the answer you want back.
- **Give each sub-agent the narrowest tool set that does the job.** A planning or research agent needs read-only tools. OpenDev removes write tools from its planner's schema entirely, because "the model cannot reason about capabilities it does not know exist".
- **Use sub-agents for cheaper models.** Switching models in the main thread breaks the prompt cache, and a sub-agent has its own.
- **Pass large artifacts through files.** In Anthropic's harness, "one agent would write a file, another agent would read it and respond".
- **Give parallel agents separable work.** When all 16 compiler agents hit the same bug, parallelism stalled until the tests were restructured so each agent could work on a different failure.

## Safety and control

Put the boundary in the environment first, then decide which actions still need a human. Instructions and approval prompts are the weakest controls a harness has.

### Why prompts are not enough

Claude Code users approve 93% of permission prompts, which means most prompts train people to click through ([Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode)). Written rules fare no better. A study of 481 public CLAUDE.md files found that only about 4 to 16% of their security rules had a matching built-in control ([When "Do Not" Is Not Deny](https://arxiv.org/abs/2608.23550)). A "do not" in a prompt is a request to the model. A deny rule in the harness is enforcement.

### The layers

| Layer | What it does | How the sources build it |
| --- | --- | --- |
| Sandbox | Limits what any command can touch, including every subprocess | Seatbelt on macOS, bubblewrap or Landlock with seccomp on Linux, gVisor containers or full VMs when hosted |
| Network egress | Stops exfiltration and unapproved downloads | All traffic goes through a proxy outside the sandbox that enforces a domain allowlist |
| Credential isolation | Keeps secrets out of reach of generated code | A proxy holds the real token and attaches it after validating the request |
| Permission rules | Decides allow, ask, or deny per tool call | Read-only tools allowed, mutations ask, known-dangerous patterns denied |
| Action classifier | Replaces most prompts with a second model's judgment | A fast filter, then a reasoning pass on flagged actions only |
| Human confirmation | Covers what cannot be undone | Gate on reversibility: external API calls, pushes, deletions |
| Hooks | Enforces team policy deterministically | Scripts at lifecycle events that can block a tool call |

The sandbox needs both filesystem and network isolation. Anthropic's reasoning is that without network isolation a compromised agent can exfiltrate SSH keys, and without filesystem isolation it can escape and gain network access ([Beyond permission prompts](https://www.anthropic.com/engineering/claude-code-sandboxing)). Claude Code's sandbox lets commands write only inside the working directory and reach the network only through the proxy. Anthropic reports 84% fewer permission prompts in internal use, and Cursor reports that sandboxed agents stop 40% less often ([Cursor](https://cursor.com/blog/agent-sandboxing)).

Tell the agent about the boundary. Cursor rewrote its shell tool description to explain the sandbox and made failures name the constraint that fired, so the agent requests escalation instead of retrying the same command.

For credentials, Claude Code on the web gives the sandbox a scoped credential for a git proxy. The proxy checks the branch and repository, then attaches the real token. OpenAI's equivalent shows the model a placeholder such as `$API_KEY` and injects the secret only for approved destinations ([Shell + Skills + Compaction](https://developers.openai.com/blog/skills-shell-tips)).

The classifier layer has measured limits. Claude Code's auto mode shows its classifier only user messages and tool-call payloads, so the agent's own prose cannot argue it into approval. On real traffic it wrongly blocked 0.4% of actions and missed 17% of real overeager actions. A denial returns to the agent as a tool result, and 3 consecutive or 20 total denials escalate to the human.

### Prompt injection

Treat everything a tool returns as untrusted data. The dangerous combination is Simon Willison's "lethal trifecta": access to private data, exposure to untrusted content, and a way to communicate externally. A harness is safe from exfiltration when it removes any one of the three, and egress control is usually the easiest to remove.

Anthropic's containment write-up records what went wrong in practice ([How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude)):

- Project configuration files were parsed before the trust dialog, so opening a repository could run its settings. Defer all parsing until after consent.
- An allowlisted domain was used for exfiltration with an attacker's own API key. An allowed domain is a capability grant.
- Their advice on isolation code is to "be wary of custom components" and to use hypervisors, syscall filters, and container runtimes that have survived adversarial attention.

### Where the loop runs

Run the agent loop outside the sandbox and reach in through a narrow tool interface. Andrea Luzzardi's argument is that the loop holds the model API keys and user tokens, so keeping it outside means generated code never sees them, and the sandbox becomes disposable ([The Agent Harness Belongs Outside the Sandbox](https://www.mendral.com/blog/agent-harness-belongs-outside-sandbox)). Anthropic reached the same design for Managed Agents and for Cowork.

### The human's place

Kief Morris distinguishes humans *in* the loop, who approve each step, from humans *on* the loop, who build and tune the harness that controls the agent ([Humans and Agents in Software Engineering Loops](https://martinfowler.com/articles/exploring-gen-ai/humans-and-agents.html)). In-the-loop review becomes the bottleneck because agents generate faster than people can inspect. Design the harness so that a human is asked rarely and each ask matters: crossing the sandbox boundary, an irreversible action, or a plan review before a long run.

### A first version

- [ ] Run shell commands in an OS sandbox with writes limited to the workspace and network denied by default.
- [ ] Keep model and service credentials in the harness process, outside the sandbox.
- [ ] Implement allow, ask, and deny rules, with read-only tools allowed by default.
- [ ] Require confirmation for actions that cannot be undone.
- [ ] Return every denial to the model as a tool result that says why, and stop the run after repeated denials.

## Verification, evals, and observability

A harness needs two feedback loops. Inside a run, the agent checks its work against ground truth. Across runs, you check the harness against traces and evals.

### Inside a run: verification

Agents do not verify by default. LangChain found that agents "don't have a natural tendency to enter this build-verify loop", so its harness intercepts the agent's attempt to finish and forces a verification pass against the task spec ([Improving Deep Agents](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering)).

Böckeler's grid is the clearest way to plan the controls ([Harness engineering for coding agent users](https://martinfowler.com/articles/harness-engineering.html)). Guides act before the agent does, sensors act after, and each is either deterministic or model-based.

|  | Computational (deterministic, cheap) | Inferential (model-based, costly) |
| --- | --- | --- |
| Guides (before) | Language servers, scripts, codemods | Instruction files, skills, how-to docs |
| Sensors (after) | Tests, linters, type checkers, structural tests | Review agents, LLM-as-judge |

Run computational sensors on every change, and run inferential ones selectively. Three practices make sensors work:

- **Write sensor output for the model.** A linter message that includes the fix instruction lets the agent self-correct without a human.
- **Keep feedback context-efficient.** Swallow passing output and surface only failures. A full test log floods the window and the agent loses the task ([HumanLayer](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents)). Nicholas Carlini's compiler project logged each error as `ERROR` plus the reason on one line and offered a sampled `--fast` test mode ([Building a C compiler](https://www.anthropic.com/engineering/building-c-compiler)).
- **Test the way a user would.** Giving agents browser automation to exercise the running app found bugs that unit tests and code reading missed ([Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)).

A separate evaluator agent is the expensive option. Agents asked to judge their own work respond by "confidently praising" it, and Claude out of the box is "a poor QA agent" that talks itself out of real findings. Anthropic's fix was a skeptical evaluator with hard pass thresholds, few-shot calibration, and a browser to click through the app. That harness produced a working app where the solo run's core feature was broken, at $200 and 6 hours against $9 and 20 minutes. It is worth the cost only "when the task sits beyond what the current model does reliably solo" ([Harness Design for Long-Running Application Development](https://www.anthropic.com/engineering/harness-design-long-running-apps)).

### Across runs: traces and the improvement loop

Record every model call, tool call, token count, and decision from day one. The transcript is the full message array at the end of the run, and a JSONL file per session is enough to start. Without it, deepset says, "failure classification is guesswork" ([deepset](https://www.deepset.ai/blog/harness-engineering)).

Three independent sources describe the same improvement loop: run real tasks, read the failing traces, classify the failure, change one thing, re-evaluate. deepset's classification tells you where the fix belongs:

| Failure class | What happened | Where the fix lives |
| --- | --- | --- |
| Context | The agent lacked the right information at the right time | Retrieval, memory, what the model sees each step |
| Constraint | It had the information and did something it should not | Permissions, linters, scope limits |
| Verification | Plausible but wrong output, and nothing caught it | Tests, validators, a reviewer before output is final |
| Planning | Wrong approach, or looping on a dead end | Decomposition, delegation, loop detection |

LangChain adds two disciplines from tuning a harness for Nemotron 3 Ultra ([playbook](https://www.langchain.com/blog/tuning-the-harness-not-the-model-a-nemotron-3-ultra-playbook)). Keep a change only if the win repeats across trials and regresses nothing else. Screen changes on a small representative sample before paying for the full suite. Their candid result is that "most of what we tried didn't survive". When no harness change moves a failure, it lives in the model's weights.

### Evals

Anthropic's vocabulary is worth adopting ([Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)). A *task* is one test with inputs and success criteria. A *trial* is one attempt. A *grader* scores some aspect of a trial. The *outcome* is the final state of the environment, which is different from what the agent says it did.

- **Start early and small.** "20-50 simple tasks drawn from real failures is a great start."
- **Grade the outcome and leave the path open.** Checking an exact tool-call sequence is too rigid, because several paths can be valid.
- **Use deterministic graders where possible and model graders where necessary.** Calibrate model graders against human judgment, and give them an "Unknown" option.
- **Run several trials from a clean environment.** At 75% per-trial success, the chance that three trials all pass is about 42%. Shared state between trials inflates scores.
- **Keep two suites.** Capability evals start at a low pass rate and give you a hill to climb. Regression evals should sit near 100%.
- **Suspect the task first.** With frontier models, a 0% pass rate across many trials usually means a broken task.
- **Read the transcripts.** Anthropic does not take a score at face value until someone has read them.

Evals are necessary and they are not sufficient. In March and April 2026, three harness-only changes degraded Claude Code: a lower default reasoning effort, a context-pruning bug that cleared prior thinking on every turn, and one system-prompt line limiting response length. They passed evals, code review, and internal use, and users found them ([postmortem](https://www.anthropic.com/engineering/april-23-postmortem)). The process changes that followed are a good checklist for any harness: run a broad per-model eval suite on every system prompt change, ablate prompts line by line, add soak periods and gradual rollouts for anything that trades against intelligence, and test on the exact build your users run.

## Starter blueprint

Build the harness as a few small modules around an append-only session log, in the order below. Each step leaves you with something usable and each later step answers a failure you will have seen by then. This section is my synthesis of the sources, so treat it as a starting design to test.

&#91;embedded content: reference architecture · harness process, sandbox, model API, frontend, eval runner\]

The loop appends every event to the session log, and the context builder assembles each prompt from it. Tools reach the sandbox through a single call of the form `execute(name, input)`.

### Modules

| Module | Responsibility | First version | Later |
| --- | --- | --- | --- |
| Session store | The record of everything that happened | One JSONL file per session, append-only | Resume, fork, replay for evals |
| Model client | Talk to the provider | Streaming, retries, token counts from the API's own usage numbers | Per-model profiles, cache breakpoints, fallback |
| Context builder | Decide what the model sees | System prompt, tool list, instruction files, environment block | Output offloading, reminders, compaction |
| Tool runtime | Register and run tools | Shell, read, edit, search, with bounded output | Plan tool, sub-agent tool, skills, MCP, tool search |
| Permission engine | Allow, ask, or deny each call | Rule list, first match wins, read-only allowed | Hooks, persisted approvals, classifier |
| Sandbox | Bound what commands can touch | OS sandbox with workspace-only writes and no network | Egress proxy with allowlist, credential proxy |
| Loop | Drive a turn to completion | The minimal loop shown earlier, with a step cap | Before-stop verification, loop detection, budgets |
| Frontend | Show events, collect input and approvals | A CLI that prints the event stream | TUI, editor, or web client on the same events |
| Eval runner | Measure the harness | Run a task in a clean workspace and grade the outcome | Multiple trials, regression suite in CI |

Three interface decisions are cheap now and expensive later:

- **One tool interface.** Anthropic's Managed Agents reduces every tool, sandbox, and MCP server to `execute(name, input) -> string`. The loop then does not care where a tool runs.
- **One event stream.** The loop emits typed events and every frontend consumes them. OpenDev's terminal and web UIs share a single callback contract, and Google's ADK puts a CLI, a web UI, and an API server over one agent core.
- **The log is the source of truth.** The context window is a view built from the session log. Compaction changes the view and never deletes from the log.

### A layout to start from

```text
harness/
  loop          run_turn, stop conditions, guards
  model         provider adapter, streaming, retries, usage
  context       prompt assembly, instruction files, compaction
  session       append-only event log, resume
  tools/        registry, shell, read, edit, search, plan, task
  permissions   allow / ask / deny rules, hooks
  sandbox/      OS sandbox profiles, egress proxy
  ui/           CLI or TUI that consumes events
evals/
  tasks/        one folder per task: prompt, setup, graders
  run           trials, grading, report
AGENTS.md       a short map for agents working on this repo
docs/           design notes, plans, decisions
```

### Build order

1. **Loop, model client, session log, and three tools.** Shell, read, and edit are enough to do real work. Run it in a container or a throwaway directory, and log every request and response from the first day.
2. **Sandbox and permission rules.** Do this before you point the agent at anything you care about. Keep credentials in the harness process.
3. **Context hygiene.** Bound every tool result, offload large output to files, load a short instruction file, and fix the prompt order so the prefix caches.
4. **A small eval set.** Write 20 tasks from failures you have already seen, grade the end state, and run them on every harness change from here on.
5. **Verification.** Add a plan tool and a before-stop hook that requires the agent to run the project's checks.
6. **Compaction and long-run files.** Archive the full history to a file, summarize to a fixed template, and adopt the spec, plan, and status files described under long-running work.
7. **Delegation and extension.** Add the sub-agent tool, then skills, then MCP with tool search.
8. **Durability.** Resume from the session log, background jobs with a process manager, and outer loops for scheduled or goal-driven runs.

After step 2 the harness should pass the four-question test from a 2026 definitional paper ([What makes a harness a harness](https://arxiv.org/abs/2606.10106)): it runs an adaptive loop, its tools can change the environment, it decides what enters the context based on content, and it has at least one control whose "effectiveness does not depend on the model choosing to cooperate".

### Defaults to adopt until you have evidence otherwise

| Decision | Default | Reason |
| --- | --- | --- |
| Framework or direct API | Write the loop against the API yourself | It is small, and Anthropic warns that framework abstractions hide the prompts you need to debug |
| Where the loop runs | Outside the sandbox | Credentials stay out of reach of generated code |
| State | Files and a JSONL log | In the one controlled ablation, file-backed state helped on both benchmarks |
| Edit tool | Exact string replacement with a stale-read check, tolerant matching | OpenDev found strict matching the largest source of edit errors |
| Stop condition | A reply with no tool calls, plus a step cap | A two-step completion protocol tuned for one model made another time out on tasks it had solved |
| Sub-agents | None at first, then one delegation tool | Peer handoffs failed at scale for Microsoft, and parent-to-child delegation worked |
| Memory | An instruction file and a notes folder | No retrieval infrastructure to maintain |
| Read-only tools | Run in parallel | OpenDev's rule, with writes run one at a time |

### Improving it afterward

Every later change follows the improvement loop described under verification: find a failure in the traces, classify it, change one thing, and re-run the evals. Lopopolo's playbook adds a useful discipline, which is to write the hypothesis down first: if this intervention is added here, the agent will do this observable thing on this task, because of this mechanism. Then run a fresh session and confirm that the change was the reason.

## Open questions and disagreements

The sources agree on the loop, on files as durable state, and on enforcing controls outside the model. They disagree on the points below, and each is something to settle with your own evals.

- **Few general tools or many typed ones.** Microsoft replaced more than 100 narrow tools with two CLIs and a code interpreter. OpenDev ships about 35 typed tools and argues that structured edit and symbol tools add checks a raw shell cannot. The two fit together if the shell is the default and a typed tool is added where the harness needs a check or a gate, but no source tests that directly.
- **Whether compaction helps.** OpenDev and Microsoft rely on it. The one controlled ablation found compression lowered scores on both benchmarks while file-backed state raised them. Anthropic's numbers suggest the answer depends on the model.
- **How much multi-agent structure.** In the 70-system survey, 70% of projects had some sub-agent mechanism. Microsoft's 50-plus specialist agents "fell apart", and problems needing more than four handoffs almost always failed. The NLAH study measured information recall across a parent-child handoff at 0.32 and 0.55. My reading is that bounded delegation from a parent works and transfer of control between peers does not, and the sources do not state it that plainly.
- **How portable a harness is across models.** Models are trained with their vendor's harness in the loop and can overfit to its tools. LangChain and HumanLayer both report Opus 4.6 ranking far higher on Terminal-Bench 2.0 in a third-party harness than in Claude Code. A harness discovered for Claude scored 32 of 89 under a GPT model largely because of one stopping convention. Plan to requalify the harness on every model change.
- **Whether harnesses will matter less.** LangChain expects models to absorb planning and self-verification. Anthropic's view is that "the space of interesting harness combinations doesn't shrink as models improve. Instead, it moves." Weng expects fewer heuristic rules and more general mechanisms, with the interface to tools and context remaining.
- **How to verify behavior.** Böckeler calls functional correctness "the elephant in the room", because current practice trusts tests the agent wrote. Lopopolo's version is "a green check proves only its assertion". Nobody has a general answer.
- **Whether the agent should edit its own harness.** Weng surveys systems that search over harness code automatically. Her condition is that the evaluator and the permission controls sit outside the loop being optimized, with held-out tests and human review.

The evidence is uneven. Most numbers in this guide are vendor or practitioner reports without published methods. The controlled results come from a handful of papers, usually on one model and without variance reported. Anthropic's own advice is to treat leaderboard differences under 3 points with skepticism.

## Sources

All 32 entries in the Foundations section of [awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) were read from the full page text, except three that were read in part, as noted below. The supplementary sources were read through a summarizing fetch, so their quotations are less certain. Three links in the list are out of date, and the working URLs are given here.

### Foundations: OpenAI and the Codex team

- [Harness engineering: leveraging Codex in an agent-first world](https://openai.com/index/harness-engineering/), Ryan Lopopolo, Feb 2026. Read through a reader proxy because openai.com blocks direct fetches.
- [Unrolling the Codex agent loop](https://openai.com/index/unrolling-the-codex-agent-loop/), Michael Bolin, Jan 2026. Same route.
- [Run long horizon tasks with Codex](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex), Derrick Choi, Feb 2026.
- [A practical guide to building agents](https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf), OpenAI, about Apr 2025. Its code samples contain errors.
- [lopopolo/harness-engineering](https://github.com/lopopolo/harness-engineering), Ryan Lopopolo's personal field guide, Jul 2026, read in part. Its playbooks are self-described as untested syntheses.
- [Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/), Lilian Weng, Jul 2026.

### Foundations: Anthropic

- [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents), Dec 2024, edited since.
- [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps), Mar 2026.
- [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents), Sep 2025. The list's URL returns 404.
- [Beyond permission prompts](https://www.anthropic.com/engineering/claude-code-sandboxing), Oct 2025. The list's URL returns 404.
- [Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents), Jan 2026.
- [An update on recent Claude Code quality reports](https://www.anthropic.com/engineering/april-23-postmortem), Apr 2026.
- [Agent Harness Design: 3 Patterns for Harnessing Claude's Intelligence](https://claude.com/blog/harnessing-claudes-intelligence), Apr 2026.
- [2026 Agentic Coding Trends Report](https://resources.anthropic.com/hubfs/2026%20Agentic%20Coding%20Trends%20Report.pdf?hsLang=en). Little buildable detail.

### Foundations: other industry writing

- [Harness engineering for coding agent users](https://martinfowler.com/articles/harness-engineering.html), Birgitta Böckeler, Apr 2026. It supersedes her Feb 2026 [first-thoughts memo](https://martinfowler.com/articles/exploring-gen-ai/harness-engineering-memo.html), which the list's second Fowler link now redirects away from.
- [The Anatomy of an Agent Harness](https://www.langchain.com/blog/the-anatomy-of-an-agent-harness), LangChain, Mar 2026.
- [Tuning the harness, not the model](https://www.langchain.com/blog/tuning-the-harness-not-the-model-a-nemotron-3-ultra-playbook), LangChain, Jul 2026. Partner content.
- [Harness Engineering](https://www.deepset.ai/blog/harness-engineering), deepset, May 2026.
- [Harness engineering: Structured workflows for AI-assisted development](https://developers.redhat.com/articles/2026/04/07/harness-engineering-structured-workflows-ai-assisted-development), Red Hat, Apr 2026.
- [What are AI agents?](https://www.ibm.com/think/topics/ai-agents), IBM.
- [Agent Development Kit announcement](https://developers.googleblog.com/en/agent-development-kit-easy-to-build-multi-agent-applications/), Google, Apr 2025, and [ADK integrations](https://developers.googleblog.com/en/supercharge-your-ai-agents-adk-integrations-ecosystem/), Feb 2026.

### Foundations: papers and production case studies

- [Building Effective AI Coding Agents for the Terminal](https://arxiv.org/abs/2603.05344), Bui, Mar 2026. No benchmark evaluation, and several internal inconsistencies.
- [Natural-Language Agent Harnesses](https://arxiv.org/abs/2603.25723), Pan et al., Mar 2026. The only controlled ablations in the set.
- [Code as Agent Harness](https://arxiv.org/abs/2605.18747), Ning et al., May 2026. A long survey, read in part.
- [What makes a harness a harness](https://arxiv.org/abs/2606.10106), de Macedo, Jun 2026.
- [Architectural Design Decisions in AI Agent Harnesses](https://arxiv.org/abs/2604.18071), Wei, Apr 2026. Its dataset is unpublished.
- [RUCAIBox/awesome-agent-harness](https://github.com/RUCAIBox/awesome-agent-harness), a survey and reading list, read in part.
- [Ranking Engineer Agent](https://engineering.fb.com/2026/03/17/developer-tools/ranking-engineer-agent-rea-autonomous-ai-system-accelerating-meta-ads-ranking-innovation/), Meta, Mar 2026.
- [How we build and use Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/how-we-build-azure-sre-agent-with-agentic-workflows/4508753), Microsoft, Apr 2026, and [Context Engineering Lessons from Building Azure SRE Agent](https://techcommunity.microsoft.com/blog/appsonazureblog/context-engineering-lessons-from-building-azure-sre-agent/4481200/), Dec 2025.

### Supplementary reading used

- Context: [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents), [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), [Code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp), [Shell + Skills + Compaction](https://developers.openai.com/blog/skills-shell-tips).
- Loop and architecture: [Scaling Managed Agents](https://www.anthropic.com/engineering/managed-agents), [How Middleware Lets You Customize Your Agent Harness](https://www.langchain.com/blog/how-middleware-lets-you-customize-your-agent-harness), [Improving Deep Agents with Harness Engineering](https://www.langchain.com/blog/improving-deep-agents-with-harness-engineering), [The Coding Harness Behind GitHub Copilot in VS Code](https://code.visualstudio.com/blogs/2026/05/15/agent-harnesses-github-copilot-vscode), [Getting started with loops](https://claude.com/blog/getting-started-with-loops).
- Safety: [Claude Code auto mode](https://www.anthropic.com/engineering/claude-code-auto-mode), [How we contain Claude across products](https://www.anthropic.com/engineering/how-we-contain-claude), [Implementing a Secure Sandbox for Local Agents](https://cursor.com/blog/agent-sandboxing), [The Agent Harness Belongs Outside the Sandbox](https://www.mendral.com/blog/agent-harness-belongs-outside-sandbox), [Tool Annotations as Risk Vocabulary](https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/), [When "Do Not" Is Not Deny](https://arxiv.org/abs/2608.23550) (abstract only).
- Multi-agent and operations: [Choosing the Right Multi-Agent Architecture](https://www.langchain.com/blog/choosing-the-right-multi-agent-architecture), [Building a C compiler with a team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler), [Minions, part 2](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2), [Humans and Agents in Software Engineering Loops](https://martinfowler.com/articles/exploring-gen-ai/humans-and-agents.html), [Skill Issue: Harness Engineering for Coding Agents](https://www.humanlayer.dev/blog/skill-issue-harness-engineering-for-coding-agents).
- Evals: [Quantifying Infrastructure Noise in Agentic Coding Evals](https://www.anthropic.com/engineering/infrastructure-noise).
