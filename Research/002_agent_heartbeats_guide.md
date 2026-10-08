# Agent Heartbeats and Periodic Execution Guide

Oct 3, 2026 · @Nathan Borror

## What periodic execution is

Periodic execution is any way an agent turn starts without a person typing: a timer, an external event, or a background job finishing. A heartbeat is the simplest form, a recurring turn in which the agent checks whether anything needs attention and usually says nothing. OpenClaw defines its heartbeat as an automation that "runs periodic agent turns in the main session so the model can surface anything that needs attention without spamming you" ([OpenClaw](https://github.com/openclaw/openclaw)).

This guide is a companion to the [Agent Harness Engineering Guide](000_agent_harness_guide.md) and the [Agent Memory Guide](001_agent_memory_guide.md). The harness guide covers the loop inside one turn. This one covers what starts a turn when nobody is there.

### Why a harness needs it

- **Recurring work.** Anthropic's description is work where "the task stays the same and only the inputs change", such as a morning summary or a weekly dependency check ([Getting started with loops](https://claude.com/blog/getting-started-with-loops)).
- **Watching something outside the agent.** A pull request, a deploy, an inbox, a queue.
- **Following up on the agent's own background work.** A long build or training job finishes, and the agent should continue without a new prompt.
- **Maintenance.** Memory consolidation, documentation repair, and cleanup run on a schedule.

LangChain's framing of the motivation is that chat makes the human start every piece of work and limits them to one conversation at a time ([Introducing ambient agents](https://www.langchain.com/blog/introducing-ambient-agents)).

### The three design problems

A timer is trivial to build. The engineering is in three decisions that every system in this guide answers differently:

1. **Whether to call the model at all.** Most ticks have nothing to do, and each model call costs a full turn.
2. **What context the run gets.** The whole conversation, a fresh session, or explicit state.
3. **What happens with nobody present.** Who approves a risky action, where the result goes, and what stops a run that has gone wrong.

### A note on OpenClaw

OpenClaw is the system most associated with the heartbeat, and its design changed substantially in version 2026.8.1. The `HEARTBEAT.md` checklist file and the separate heartbeat timer that many write-ups describe are gone. The heartbeat is now one job in a unified scheduler. The nanobot project still uses the older file-based design, so both are described below.

## Kinds of trigger

A harness needs a handful of trigger types, and they differ in what starts a run and what ends the series.

| Trigger | Starts a run when | The series ends when | Examples | Best for |
| --- | --- | --- | --- | --- |
| Heartbeat | A fixed interval elapses, in the main session | It is disabled | OpenClaw, 30 minutes by default. nanobot, 1,800 seconds. | Ambient monitoring and follow-up |
| Schedule | An interval or cron expression matches | It is cancelled or expires | Claude Code `CronCreate` and routines, OpenClaw automations, Codex scheduled tasks | Reports and recurring chores |
| One-shot | A timestamp arrives | It has fired | "Remind me at 3pm" | Reminders and delayed work |
| Self-paced loop | The delay the agent chose last time elapses | The agent stops it | Claude Code `ScheduleWakeup`, OpenClaw `next_check` | Polling something whose pace changes |
| External event | A webhook, message, or repository event arrives | The trigger is removed | Claude Code routines' API and GitHub triggers, OpenClaw hooks | Reacting to other systems |
| Job completion | A background command or sub-agent finishes | The job is done | OpenClaw's exec exit wake, Claude Code delivering a result as a new turn | Long builds and training runs |
| Goal loop | The agent tries to stop and the condition is not met | The condition is met or a cap is reached | Claude Code `/goal` | Work with a verifiable end state |

Ryan Lopopolo compresses the list to three: "cron, event triggers, and tail calls", where a tail call is a completed run scheduling its successor ([lopopolo/harness-engineering](https://github.com/lopopolo/harness-engineering)).

### Choosing between them

- **Prefer an event to a poll.** Claude Code's docs say a monitor that streams output from a background script "avoids polling altogether and is often more token-efficient and responsive". Google's ADK tutorial is blunter: "Active polling wastes compute."
- **Match the interval to how often the thing changes.** Anthropic's guidance is not to run a routine more often than you need to.
- **Give known work a schedule and unknown work a heartbeat.** OpenClaw's rule is to create a scheduled job for work that has its own instructions or timing, and to keep the heartbeat for periodic awareness in the main session.
- **Use a goal loop when done is checkable.** A fresh evaluator model judges the condition each time the agent tries to stop, which works best with deterministic criteria such as a count of passing tests.

### What Anthropic calls a proactive loop

The four types compose. Anthropic's "proactive loop" is a schedule that wakes the agent, a goal that defines done for each wake, sub-agents that fan out the work, and a permission mode that does not stop to ask. Their example runs every hour, checks a feedback channel for bug reports, and does not stop until each report found in that run is triaged and answered.

## How OpenClaw does it

OpenClaw runs one scheduler, called Automations, inside its long-running gateway process. Timed jobs, event triggers, and the heartbeat all go through it. The details below were read from the repository at version 2026.9.8 on 2026-10-03, with constants and prompts checked in source.

### The heartbeat

The heartbeat is a system-owned interval job, one per agent, that runs a turn in the agent's main session.

| Setting | Default | Notes |
| --- | --- | --- |
| Interval | 30 minutes | 1 hour under subscription authentication. `0m` disables the timer and leaves event wakes working. |
| Session | The main session, with full history | `isolatedSession` gives a fresh session, and `lightContext` skips the workspace files |
| Model | The agent's model | Can be overridden per heartbeat |
| Active hours | All day | A start, an end, and a time zone. Ticks outside the window are skipped. |
| Delivery | The owner's direct message | Or the last conversation, a named channel, or nowhere |
| Timeout | The interval, capped at 600 seconds |  |

The default prompt is sent as the user message, word for word:

```text
Follow the heartbeat monitor scratch context when provided. Recurring tasks are
automations; create or change their schedules with the automations tool, not
heartbeat scratch. Do not infer or repeat old tasks from prior chats. If nothing
needs attention, reply NO_REPLY.
```

The third sentence is deliberate. The source comment says to keep the prompt tight and to avoid encouraging the model to "invent/rehash" open loops from earlier conversation.

**The checklist.** Each heartbeat job owns a small block of text called monitor scratch, stored in the state database and appended to the prompt. The docs call it "small, stable, and safe to consider every 30 minutes". It replaced the `HEARTBEAT.md` workspace file.

**Skipping.** The run is skipped with no model call when the scratch exists and is effectively empty, when the tick falls outside active hours, when no delivery route exists, or when the session is busy. A plain poll that finds the session busy is dropped until the next tick. A wake that carries an event is retried.

**Staying quiet.** The model either replies with the exact token `NO_REPLY`, which the delivery layer drops, or calls a `heartbeat_respond` tool:

```text
heartbeat_respond(
  outcome:  no_change | progress | done | blocked | needs_attention,
  notify:   boolean,
  summary:  string,
  notificationText?, reason?, priority?, nextCheck?,
  scratch?  a full replacement for the checklist text
)
```

A silent result is kept as bounded context for the next real user turn, so the agent remembers what it noticed.

**Cost.** A heartbeat is a full agent turn. The one figure the docs give is that an isolated session cuts a run from about 100,000 tokens of history to 2,000 to 5,000.

**Event wakes.** A background command that exits queues a system event and requests an immediate heartbeat, so the agent continues its work without a new message. Event wakes are rate-limited to one per 30 seconds, with a flood guard after five starts in 60 seconds. The source comment gives the reason: to prevent feedback loops between tool exits and wakes.

### Automations

A job combines a schedule, a payload, a session target, and a delivery rule.

| Part | Options |
| --- | --- |
| Schedule | `at` (one-shot), `every` (interval), `cron` (expression with time zone), `on-exit` (a watched command exits), `stream` (lines from a long-lived command) |
| Payload | A system event queued for the main session, an agent turn, a shell command, or a headless script |
| Session | `main`, `isolated` (a fresh session per run), `current` (a bounded tail of the conversation that created it), or a named persistent session |
| Delivery | Announce to a channel, post to a webhook, or none |

**Condition triggers.** A job can carry a small script that runs on each tick with no model call. The agent turn runs only when the script returns `fire: true`. The script receives its previous state and returns new state, which is how a poll detects a change:

```text
schedule: every 30 seconds
trigger:  run `gh pr checks 123`, compare the result with trigger.state.status,
          return { fire: changed, message: "CI: old -> new", state: { status } }
payload:  agent turn, "Investigate the CI status change."
```

The docs' advice is to fire on failures and timeouts as well, because "a watcher that goes quiet when its check fails or times out looks healthy while broken".

**The unattended contract.** Every isolated scheduled turn has this text injected:

```text
This is an unattended scheduled run. Nobody is present to clarify or approve, so
complete the task with what you have. Your final reply is the deliverable — not a
plan, an acknowledgement, or a request for input. If nothing needs doing, reply
exactly NO_REPLY. If something failed, start with AUTOMATION_FAILED on its own
line, then state what failed and what you tried — the scheduler owns retries and
failure alerts.
```

**Failure handling.** Recurring jobs back off after consecutive errors at 30 seconds, 60 seconds, 5 minutes, 15 minutes, and 60 minutes. A job is disabled after 10 consecutive failures and the owner is told. Failure alerts go out after 2 consecutive failures with a one-hour cooldown. If the job was created from a conversation, that conversation's agent receives a repair request and may fix the problem itself.

**After a restart.** Missed recurring jobs catch up by default, with at most five run immediately and agent turns deferred so that model calls stay out of startup.

### How the agent schedules its own work

The agent has an `automations` tool with actions to add, update, remove, list, run, and wake. Its description opens with "Never exec sleep/poll as timer." Three rules in the design are worth copying:

- **A scheduled run cannot create other schedules.** Inside an automation run the tool is restricted to the run's own status, its own removal, and its own next check.
- **A stored tool list cannot widen.** A job created with a finite tool list is capped to the tools available to the turn that created it.
- **New jobs start enabled and are tested at once.** When the agent turns a repeated request into a schedule, it confirms the schedule in plain words, runs the job once as a visible test, and removes it if the test fails. The reasoning is that "nothing supervises a disabled job".

### Heartbeat or automation

|  | Automation | Heartbeat |
| --- | --- | --- |
| Timing | One-shot, interval, or cron expression | Scheduler-owned interval |
| Context | Isolated, current, named, or main session | Main session, optionally isolated |
| Delivery | Channel, webhook, or silent | Alerts to the owner, or silent |
| Best for | Reports, reminders, recurring work | Ambient monitoring and event follow-up |

In the current docs even "check inbox every 30 minutes" is assigned to an automation. Version 2026.8.1 moved recurring checks out of the heartbeat into separate jobs, and removed a feature that inferred follow-ups from conversations and delivered them through the heartbeat.

## How other harnesses do it

The other systems differ mainly in where a scheduled run executes and what it starts with.

| System | Runs on | Context for each run | Shortest interval | Missed runs | Approval prompts |
| --- | --- | --- | --- | --- | --- |
| Claude Code `/loop` | Your machine, in an open session | The same session and its history | 1 minute | Fires once when idle, no catch-up | Inherits from the session |
| Claude Code Desktop tasks | Your machine, app open | A fresh local session | 1 minute | One catch-up run within 7 days | A permission mode per task. A run stalls until answered. |
| Claude Code routines | Anthropic's cloud | A fresh session and a fresh clone | 1 hour | Runs over the hourly cap wait | None. Runs autonomously inside its sandbox. |
| Codex scheduled tasks | Your machine, app open, or the web | A new chat, or an existing chat's context | Minutes, inside a chat | Not documented | None where policy allows, under your default sandbox |
| nanobot heartbeat | Its gateway process | A dedicated heartbeat session, trimmed to 8 messages | 1 second for jobs | Not documented | Not documented |
| eve schedules | A platform cron job | A new session on every fire | 1 minute | Not documented | A tool that needs approval fails the session |

Sources: [Claude Code scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks), [routines](https://code.claude.com/docs/en/routines), [Codex scheduled tasks](https://learn.chatgpt.com/docs/automations), [nanobot](https://github.com/HKUDS/nanobot), [eve](https://github.com/vercel/eve).

### Claude Code

**`/loop`.** A fixed interval is converted to a cron expression. With no interval, the agent picks its own delay after each iteration, between one minute and one hour, by calling a `ScheduleWakeup` tool. If an iteration neither reschedules nor stops, the harness schedules one fallback wakeup about 20 minutes later and then ends the loop. A scheduled prompt "fires between your turns, not while Claude is mid-response". Recurring tasks expire 7 days after creation, which "bounds how long a forgotten loop can run", and a session holds at most 50.

**Desktop tasks.** Each task stores its prompt as a skill file and starts a fresh session. The docs draw the practical consequence of catch-up: a task scheduled for 9am might run at 11pm if the computer was asleep, so the prompt should carry its own time guardrails.

**Routines.** A routine is a saved prompt, repositories, and connectors. It can be fired by a schedule, an HTTP call, or GitHub events. Text arriving through the API is wrapped as untrusted, and the saved prompt must opt in to acting on it. The docs warn that a green status means the session started and exited without an infrastructure error. It "does not mean the task in your prompt succeeded".

**`/goal`.** After each turn a small fast model checks a condition against the transcript and returns not yet met, met, or impossible. It cannot call tools, so the condition must be provable from what the agent has already shown. A stall guard ends the loop when the agent keeps answering without using tools. While a background job is running, evaluation is skipped and the harness checks in after 30 minutes, then at doubling intervals, at most three times.

### Codex

A scheduled task is a saved prompt with a recurrence rule. A standalone task starts a new chat for each run and reports to a Scheduled view that works as an inbox. A task inside a chat reuses that chat's context for follow-up loops. In a git repository a run can use the local project or a new worktree, and the docs note that frequent schedules create many worktrees. Scheduled tasks use an approval policy of never where the organization allows it.

### nanobot

nanobot keeps the file-based heartbeat. A system job fires every 30 minutes and reads `HEARTBEAT.md`. If the file has no line under its `## Active Tasks` heading, the model is not called. Otherwise the agent performs the tasks in a dedicated session.

Its distinctive feature is a second model call that decides whether to notify. During the run the message tool is suppressed. The response then goes to an evaluator with one forced tool, `evaluate_notification(should_notify, reason)`. The evaluator is told to suppress routine status checks and any "meta-reasoning about the task itself". If the evaluator fails, the default is silence.

### eve

In Vercel's eve a schedule is a file. The path is its name, and each one compiles to a platform cron job:

```text
agent/schedules/cleanup.md
---
cron: "0 0 * * 0"
---
(the prompt, as plain Markdown)
```

For schedules the agent creates at run time, eve's documented pattern is one authored schedule that fires every minute and dispatches rows from your own store. The store must lease due rows atomically so overlapping ticks do not claim the same work. Delivery is at least once, so tasks with side effects need idempotency.

### Durable execution platforms

Temporal's case study runs each agent as a long-lived workflow that holds state and waits for signals, with a durable schedule sending a nudge every 25 seconds ([Orchestrating ambient agents with Temporal](https://temporal.io/blog/orchestrating-ambient-agents-with-temporal)). The schedule survives worker restarts. Temporal's schedule options are a useful vocabulary for any scheduler: an overlap policy, a catch-up window, pause on failure, jitter, and access to the last successful run's result.

Google's ADK tutorial handles the idle case without a timer ([ADK](https://developers.googleblog.com/build-long-running-ai-agents-that-pause-resume-and-never-lose-context-with-adk/)). The agent's position is stored as an explicit step in session state. A webhook resumes the session and applies a state change before the next model call, and the container scales to zero in between.

## Designing a tick

A tick is one wakeup. A good one decides cheaply whether to run, gives the model only the context it needs, and ends in a recorded outcome.

### Decide before calling the model

The cheapest quiet run is one that never reaches the model. The systems stack their checks in roughly this order:

1. **Scheduler guards.** The job is disabled, the tick is outside active hours, the session is busy, or there is nowhere to deliver.
2. **An empty checklist.** OpenClaw skips when the scratch has only headings and comments. nanobot skips when no active task is listed.
3. **A condition script.** Code checks the outside world and compares it with saved state. OpenClaw's condition triggers and eve's schedule handlers do this.
4. **A statistical or rule gate.** LangChain's deploy monitor flags an error signature only when its count significantly exceeds a 7-day baseline, and only then involves an agent ([How My Agents Self-Heal in Production](https://www.langchain.com/blog/how-my-agents-self-heal-in-production)).
5. **The model, with a way to say nothing.** A sentinel reply, or a tool such as `heartbeat_respond` or eve's `no_reply`.
6. **A second model as a notification gate.** nanobot's evaluator, which fails closed to silence.

OpenClaw's authoring advice for recurring jobs applies generally: "every fire re-runs the same instructions; keep the model for judgment only". Put listing, diffing, deduplication, and checkpoints in a script.

### Choose the context

| Context | What the run sees | Cost and risk | Used by |
| --- | --- | --- | --- |
| Main session | The whole conversation | Most expensive per run, and the model may act on stale conversation | OpenClaw heartbeat, Claude Code `/loop`, Codex in-chat tasks |
| Fresh session | Instructions and the job prompt only | Cheapest, and needs state from elsewhere | OpenClaw isolated jobs, Desktop tasks, routines, eve |
| Named session | Its own accumulating history | Grows over time unless trimmed | OpenClaw named sessions, nanobot's heartbeat session |
| Bounded tail | The last part of the creating conversation | A middle course | OpenClaw `current` |

State that must survive between runs belongs outside the transcript. The options in the sources are a small state object returned by the trigger script, a checklist the run can rewrite, the previous run's result, and files in the repository.

Google's ADK tutorial explains why replaying history across a long pause fails. After three idle days and a large context dump, "the model frequently hallucinates intermediate steps that never happened", such as approvals that were not given. Their fix is to store the current step explicitly and inject it into the system instruction on every run.

### Keep the scheduled prompt short and point to a runbook

Lopopolo's weekly upgrade check for a home device has this as its entire scheduled prompt:

```text
Run the homelab Valetudo Tailscale upgrade assessment. Read
docs/automations/README.md and docs/automations/valetudo-tailscale-upgrades.md,
follow their guardrails, and open an inbox item with the required summary.
```

The instructions live in a checked-in runbook, so they are versioned and reviewed like code. His list of what a runbook tells the agent:

- Which external and repository state to inspect.
- How to decide whether work is needed.
- Which changes fall inside the standing mandate.
- Which checks establish a safe candidate.
- Which mutations require human approval.
- How to prove the real outcome.
- What to record when the run changes nothing.
- How to recover after partial progress.
- When the runbook or the loop itself should be retired.

### Tell the model what time it is

Models do not reliably track elapsed time. In a negotiation experiment with a wall-clock deadline, one model closed 4% of deals when told the time limit once and 32% when each message carried the remaining time ([Real-Time Deadlines](https://arxiv.org/abs/2601.13206)). The effect varied by model.

Put the current time, the scheduled time, and any remaining budget in the wake message. State times as wall-clock time in a named zone. OpenClaw's tool schema tells the model never to convert a cron time to UTC itself.

### End in a named outcome

Lopopolo's rule is that a loop "should finish in one of a small number of durable states": nothing needed, candidate proposed, change proved, approval requested, recovery required, or policy obsolete. OpenClaw's heartbeat tool has a similar list. His test for whether state is missing is practical: "Quiet no-op runs are healthy. Repeated rediscovery of the same facts signals missing state."

### Do not let the tick invent work

A heartbeat in the main session sees old conversation and may decide to revive it. OpenClaw's default prompt forbids this in so many words, and the project removed its feature for inferring follow-ups from chats. Claude Code's built-in loop prompt limits itself to unfinished work from the conversation, the current pull request, and cleanup, and says the agent "does not start new initiatives outside that scope".

## Scheduling mechanics

The scheduler is ordinary software that lives in the harness process, outside the model. OpenClaw's tool description tells the model "Never exec sleep/poll as timer", and its docs say automations "run inside the Gateway process, not inside the model".

### One scheduler, persisted jobs

OpenClaw and nanobot both converged on a single scheduler in which the heartbeat is one job. Jobs are stored durably: OpenClaw moved from JSON files to SQLite, and nanobot uses a JSON file with a lock. A job record needs a schedule, a payload, a session target, a delivery rule, and run state such as the next run time, the last status, and a count of consecutive errors.

### Missed runs

The systems disagree, so treat this as a policy you set per job.

| System | After downtime |
| --- | --- |
| OpenClaw | Catches up by default. A setting skips to the next future occurrence. One-shots always catch up. |
| Claude Code `/loop` | No catch-up. A task that came due while busy fires once when idle. |
| Claude Code Desktop | Exactly one catch-up run for the most recent miss within 7 days |
| Temporal | A catch-up window you choose, one year by default and ten seconds at minimum |

Whatever the policy, coalesce. A job that missed six intervals should run once.

### Overlap

Temporal's overlap policies name the choices when a run is due and the previous one is still going: skip (its default), buffer one, buffer all, cancel the other, terminate the other, or allow all.

- OpenClaw drops a plain heartbeat poll when the session is busy and retries a wake that carries an event.
- Claude Code enqueues a due prompt and fires it between turns.
- Desktop tasks skip a run when the previous one is still in progress and record why.
- eve's dispatcher pattern leases rows atomically so two ticks cannot claim the same job.

### Jitter

Schedules written by people cluster on the hour. OpenClaw staggers top-of-hour cron jobs by up to 5 minutes. Claude Code delays recurring tasks by up to 30 minutes, or half the interval for frequent ones, with an offset derived from the task ID so it is the same every time. If exact timing matters, the job must say so.

### Expiry and stopping

- Claude Code's recurring tasks expire after 7 days.
- One-shot jobs delete themselves after firing.
- OpenClaw disables a job after 10 consecutive failures.
- Lopopolo asks every standing loop to carry "an explicit retirement condition".
- A scheduler-theory paper adds that any wait for a human needs a finite timeout, or termination cannot be guaranteed ([From Agent Loops to Structured Graphs](https://arxiv.org/abs/2604.11378)).

### Retries and idempotency

- **Back off.** OpenClaw's schedule for a recurring job is 30 seconds, 60 seconds, 5 minutes, 15 minutes, then 60 minutes, reset on the next success.
- **Distinguish transient from permanent.** A rate limit or timeout is retried. A permanent error disables a one-shot job at once.
- **Do not retry what may not be idempotent.** OpenClaw does not retry stream-triggered payloads. Temporal's example sets a single attempt on the tool that places an order.
- **Assume at-least-once.** eve's docs say a crash between sending and marking complete can dispatch again. OpenClaw records a durable delivery attempt before sending, so an interrupted one-shot reminder is left disabled instead of being sent twice. That protection covers message sends only.

### Self-pacing

A fixed interval is wrong for something that is busy now and quiet later. Both Claude Code and OpenClaw let the running agent propose its next delay, clamped to bounds, and both use one minute to one hour as the range for a loop with no stated interval. OpenClaw discards the proposal if the run failed, so backoff takes precedence.

### Waking on completion

Polling for a long job wastes turns. The alternatives in the sources:

- **A completion event.** OpenClaw queues a system event when a background command exits and wakes the owning session.
- **A new turn.** Claude Code delivers a finished background task's result to the agent as a new turn.
- **A webhook and a state change.** ADK resumes the session and applies the new step before the model runs.
- **Hibernate and resume.** Meta's ranking agent hands a multi-hour training job to a background system, shuts down, and resumes when it completes.

All four depend on the session being resumable from stored state, which the harness guide covers under long-running work.

### Time zones

Be explicit. OpenClaw treats a timestamp with no zone as UTC and a cron expression with no zone as the host's local time. Claude Code interprets all times in the local zone. eve on Vercel evaluates cron in UTC. Have the agent confirm the user's zone before it creates a schedule.

## Cost

A scheduled run costs a full agent turn whether or not it finds anything, so the cost of a heartbeat is set by how often it runs, how much context it carries, and how often it can skip the model.

### Where the tokens go

A heartbeat in the main session resends the whole conversation. OpenClaw's figure is about 100,000 tokens per run in a long session against 2,000 to 5,000 in an isolated one. At a 30-minute interval that is 48 runs a day.

The prompt cache does not rescue a slow heartbeat. Anthropic's cache entries last about five minutes by default, with a one-hour option, so a tick every 30 minutes on the default setting finds the cache expired and pays full input price. This figure is from the API documentation and was not re-read for this guide. That is one more reason to run slow ticks in a small fresh session.

### Levers, cheapest first

- **Skip the model.** An empty checklist, a condition script, or a rule gate costs nothing.
- **Use a script for deterministic work.** Anthropic's guidance is that "running a script is cheaper than reasoning through the steps".
- **Run in a fresh, light session.** Drop the history and the workspace files the tick does not need.
- **Use a smaller model for routine checks.** OpenClaw's docs say summaries, triage, and status checks run well on a lighter model. Anthropic routes routines to smaller models and keeps the most capable model for judgment calls.
- **Lengthen the interval.** Match it to how often the watched thing changes.
- **Replace polling with an event.**

One caveat from OpenClaw: a heartbeat that switches a shared session to a small-context model can leave that model selected for the next real turn. Isolate the session when you override the model.

### Budgets

An unattended run needs hard limits enforced outside the model. An InfoWorld piece on agent cost control lists five, to be enforced at the gateway every call passes through ([FinOps for agents](https://www.infoworld.com/article/4138748/finops-for-agents-loop-limits-tool-call-caps-and-the-new-unit-economics-of-agentic-saas.html)):

- A step limit on planning and verification cycles.
- A cap on tool calls, with tighter caps for expensive tools.
- A token ceiling per run.
- A wall-clock timeout.
- Per-tenant budgets and concurrency limits.

The concrete limits in the systems read:

| System | Limit |
| --- | --- |
| OpenClaw | 60-minute watchdog on an isolated agent turn, 8 concurrent runs, 30-second floor on condition triggers |
| Claude Code headless | `--max-turns` and `--max-budget-usd` |
| Claude Code `/goal` | A turn or time clause written into the condition, and three automatic retries |
| Claude Code routines | 100 scheduled runs per hour per account |

### Measure cost per useful run

The same article proposes cost per accepted outcome: total spend on a workflow, including failed and abandoned runs, divided by accepted outcomes only. For a heartbeat this means the quiet runs are part of the price of the few useful ones. Tag every run with an outcome and watch the 95th and 99th percentiles, which is where loops and retry storms show up.

## Safety for unattended runs

An unattended run has no one to approve an action, notice a mistake, or press stop, so each of those needs a mechanical substitute.

### When a tool needs approval and nobody is there

The systems take three positions.

| Policy | Systems | Behavior |
| --- | --- | --- |
| No prompts, inside a sandbox | Claude Code routines, Codex scheduled tasks | The run never asks. Its reach is bounded by the sandbox, the selected repositories, and the network policy. |
| Stall and wait | Claude Code Desktop, OpenClaw | The run pauses until someone answers. "Always allow" creates a standing grant for later runs. |
| Fail | eve | A tool that needs approval fails the session. |

For the first policy, the sandbox is the control, which is the harness guide's point about containing with boundaries first. For the second, test the job once while watching, approve what it needs, and expect later runs to pass.

### Narrow the authority of scheduled runs

- **Propose, and leave the irreversible step to a person.** Lopopolo's scheduled run "can research, build, and propose" and "cannot deploy". Deployment is a separate runbook with a canary and two human approvals.
- **Cap the tool list at creation.** In OpenClaw a job's stored tools cannot exceed those of the turn that created it.
- **Stop scheduled runs from scheduling.** OpenClaw's scheduled runs can remove themselves and cannot create or edit other jobs.
- **Give scheduled work its own identity.** eve runs schedules as an app principal so tools and hooks can treat the agent's own work differently from a user's.

### Treat trigger input as untrusted

An event trigger carries text written by someone else.

- Claude Code routines wrap text sent to the API trigger in a block labeled untrusted, and the saved prompt must opt in to acting on it. The saved prompt is the task, and it "can't act as approval or consent for actions during the run".
- OpenClaw wraps webhook content and warns that wrapping "does not remove tools or workspace access", so untrusted inputs should go to a restricted agent.
- Scripts attached to triggers run with the owning agent's full tool policy in OpenClaw, which its docs flag as a risk and provide a switch to disable.

### Keep scheduled runs out of long-term memory

OpenClaw's scheduled, heartbeat, and sub-agent sessions do not produce memory candidates, and scheduled sessions are not given the curated memory file. A tick that could write to memory would turn a one-time bad input into a standing instruction.

### Notify with discipline

LangChain names three reasons for an ambient agent to reach a person: to notify, to ask a question, and to request review of an action. Each maps to a different response the person can give. Their experience was that Slack messages were easy to lose, which led to an inbox that lists every open request.

- Send alerts to one place the owner controls. OpenClaw's default target never sends to a group.
- Fail toward silence for routine results and toward noise for failures.
- Make the first alert explain what the heartbeat is and how to turn it off.

### Stop controls

- A global switch for all scheduling, and one for trigger scripts.
- Expiry on forgotten loops.
- Automatic disable after repeated failure.
- Rate limits on event wakes, so a tool exit cannot trigger a wake that triggers another tool exit.
- A cap on runs per hour.

## Observability and evaluation

Nobody watches a scheduled run, so the record of what happened has to stand in for the watcher.

### What to record for every run

- **A run ID, the job, the trigger, and the times** it was scheduled and actually started.
- **Execution status and delivery status as separate fields.** OpenClaw records `ok`, `error`, or `skipped` for the run and a separate completion status for delivery, so a failed send does not count as a failed job.
- **The skip reason.** Busy, outside hours, empty checklist, no route, condition not met. A skipped run with a reason is information. A missing run is a mystery.
- **The outcome.** One of a small fixed set, as described under designing a tick.
- **Tokens, tool calls, and duration.**

### Three ways a scheduled job lies

- **Green does not mean done.** Claude Code's routine docs say a green status means the session ran without an infrastructure error and "does not mean the task in your prompt succeeded". Have the run state its outcome, and treat a first line of `AUTOMATION_FAILED`, or your equivalent, as a failure.
- **Quiet does not mean healthy.** A watcher that only reports success goes silent when its own check breaks. Fire on failures and timeouts too.
- **Disabled does not mean safe.** OpenClaw's observation is that a disabled job waiting for a confirmation that never comes is "a silent non-outcome", which is worse than a job that runs and complains.

### Alerting

Send failure alerts through a separate path from results. OpenClaw alerts after 2 consecutive failures, applies a one-hour cooldown, and groups repeated failures with the same cause into one incident. Temporal can pause a schedule automatically when a run fails.

### Testing

- **Run the prompt by hand first.** Codex's docs say to test it in a regular chat, then review the first few scheduled outputs.
- **Fire once immediately.** OpenClaw's agent runs a new job as a visible test and removes it if the test fails. eve has a development endpoint that fires a schedule by name.
- **Simulate the wait.** Google's ADK tutorial seeds session state to stand in for a 48-hour pause, because "you can't wait two weeks to find out your agent skips a step". One of its tests asserts that the agent refuses to skip a gate when asked.
- **Judge with a different model.** Claude Code's goal loop uses a separate small model to decide whether the condition is met, and nanobot uses a separate call to decide whether to notify.

### What to track over time

- Runs per day, and the share skipped before the model, by reason.
- The share of model runs that ended silent, which shows whether a cheaper gate is possible.
- Notifications sent, and how many the owner acted on.
- Cost per useful outcome, with the 95th percentile of run cost and duration.
- Consecutive failures per job, and jobs disabled automatically.

## Starter design

Build one scheduler in the harness process, make the heartbeat a job in it, and put a gate in front of every model call. This section is my synthesis of the sources, so treat it as a starting design to test.

&#91;embedded content: one tick · trigger, scheduler, gate, agent turn, outcome, run log\]

Every tick ends in the run log, whether it reached the model or was skipped at the gate.

### A job record to start from

```text
job
  id, name, enabled
  schedule    at | every | cron, with a time zone
  payload     prompt | command | script
  condition   optional script that returns { fire, message, state }
  session     main | fresh | named
  tools       the allowed tool list, fixed at creation
  delivery    channel | inbox | none
  limits      timeout, max steps, budget
  state       next_run, last_run, last_status, consecutive_errors, scratch
```

### Build order

1. **A job store and one timer.** Persist jobs in a file or SQLite. Support a one-shot time and a fixed interval first. On start, compute what is due and coalesce missed runs to one.
2. **The run path.** Build a wake message from the job prompt, the current time and zone, and the scheduled time. Run a turn in a fresh session under a timeout and a step cap. Write a run record with a status.
3. **A way to say nothing.** Accept a sentinel reply or a small response tool, suppress delivery for it, and record the outcome.
4. **Guards before the model.** Check enabled, active hours, session busy, and overlap. Skip when a checklist is empty. Record each skip with its reason.
5. **The heartbeat.** Add it as an interval job that targets the main session and reads a short checklist. Add a queue of system events that the next heartbeat drains, with an option to wake at once.
6. **Wake on completion.** When a background command exits, queue an event for the session that owns it. Rate-limit event wakes.
7. **A scheduling tool for the agent.** Let it add, list, and remove jobs. Have it confirm the time zone, run a new job once as a test, and restrict the tool inside scheduled runs.
8. **Condition scripts and self-pacing.** Let a job carry a check that runs without the model and keeps state. Let a running job propose its next delay within bounds.
9. **Failure handling.** Back off on consecutive errors, disable after repeated failure, alert through a separate path, add jitter, and expire jobs the agent created unless they are renewed.
10. **Unattended permissions.** Choose one policy for approvals, cap each job's tools, and run commands in the sandbox.

### Defaults to adopt until you have evidence otherwise

| Decision | Default | Reason |
| --- | --- | --- |
| Where the scheduler runs | In the harness process, with a persisted store | The model should never be the timer |
| Context for a scheduled job | A fresh session | Cheapest per run and not confused by old conversation |
| Context for the heartbeat | The main session, moved to an isolated one if cost grows | It exists to notice things in the main session |
| Heartbeat interval | 30 minutes, within active hours | OpenClaw's and nanobot's default |
| Quiet runs | Skip on an empty checklist, and a sentinel reply otherwise | Both cost nothing to build |
| Missed runs | Run once, coalesced. One-shots always run. | A stale reminder repeated six times helps nobody |
| Overlap | Skip the new run | Temporal's default |
| Instructions | A runbook file in the repository, with the job prompt as a pointer | Versioned and reviewable |
| Wake message | Includes current time, zone, and scheduled time | Models do not track elapsed time reliably |
| Failures | Back off, alert after 2, disable after 10 | OpenClaw's defaults |
| Agent-created loops | Expire after 7 days | Claude Code's bound on forgotten loops |
| Scheduled runs and memory | No writes to the curated core | A bad tick should not become a standing instruction |

Memory consolidation is a natural first job to schedule. The [Agent Memory Guide](001_agent_memory_guide.md) covers what that job should do.

## Open questions and disagreements

The sources agree that the scheduler belongs outside the model, that most ticks should not reach the model, and that state must live outside the transcript. They disagree on the points below.

- **What a heartbeat is for.** nanobot uses it as the home for quiet recurring checks. OpenClaw moved those checks into separate jobs during 2026 and kept the heartbeat as a narrow monitor and event follow-up lane.
- **Whether to catch up after downtime.** OpenClaw catches up by default, Claude Code's `/loop` never does, Desktop runs exactly once, and Temporal makes it a window.
- **Who decides to stay silent.** OpenClaw and eve trust the acting model to emit a sentinel or call a tool. nanobot adds a second model as a gate. No source compares the two on false alarms or missed alerts.
- **Where instructions live.** Lopopolo puts them in a checked-in runbook and keeps the scheduled prompt as a pointer. Codex puts them in the task prompt or a skill. Claude Code Desktop stores them as a skill file outside the repository.
- **What to do about approvals.** Run without prompts in a sandbox, stall until answered, or fail.
- **How proactive an agent should be.** OpenClaw removed its feature for inferring follow-ups from conversation, and its docs cite research that proactive systems frequently overact. LangChain's ambient agents and Anthropic's proactive loops push toward more autonomy with human review at defined points.

The evidence is thin. The only cost figure is OpenClaw's token comparison. No source reports how often a heartbeat produces something useful, or what a notification gate does to missed alerts. The one failure account of a running loop is LangChain's, and it is about limits of attribution, not runaway cost. The deadline paper is the only controlled experiment, and its effect varies by model.

## Sources

All sources were read from full page text or source code on 2026-10-03 unless noted. Scheduling features are changing quickly, and OpenClaw and Codex both renamed or restructured theirs during 2026.

### OpenClaw and similar personal agents

- [openclaw/openclaw](https://github.com/openclaw/openclaw), version 2026.9.8. Read from the repository's `docs/` tree (the source of [docs.openclaw.ai](https://docs.openclaw.ai)), with defaults, prompts, and tool schemas checked in source. Two of its docs pages disagree on model-override precedence.
- [HKUDS/nanobot](https://github.com/HKUDS/nanobot), version 0.3.5. Docs, templates, and the heartbeat, evaluator, and cron tool source.
- [vercel/eve](https://github.com/vercel/eve). Schedule and dynamic-scheduling docs. Implementation not read.

### Vendor documentation

- [Loop engineering: Getting started with loops](https://claude.com/blog/getting-started-with-loops), Anthropic, Jun 2026.
- Claude Code: [scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks), [routines](https://code.claude.com/docs/en/routines), [desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks), and [goal](https://code.claude.com/docs/en/goal). Headless mode was searched, not read in full.
- [Scheduled tasks](https://learn.chatgpt.com/docs/automations), Codex, formerly called automations. The page gives no numeric limits.
- [Temporal Schedules](https://docs.temporal.io/schedule), for overlap and catch-up policies.

### Articles and field guides

- [lopopolo/harness-engineering](https://github.com/lopopolo/harness-engineering), the thesis "Run Known Work as a Continuous Loop" and two source essays.
- [Orchestrating ambient agents with Temporal](https://temporal.io/blog/orchestrating-ambient-agents-with-temporal), Sep 2025.
- [Build long-running AI agents that pause, resume, and never lose context with ADK](https://developers.googleblog.com/build-long-running-ai-agents-that-pause-resume-and-never-lose-context-with-adk/), Google, May 2026.
- [How My Agents Self-Heal in Production](https://www.langchain.com/blog/how-my-agents-self-heal-in-production), LangChain, Apr 2026.
- [Introducing ambient agents](https://www.langchain.com/blog/introducing-ambient-agents), LangChain, Jan 2025, and the [agent-inbox](https://github.com/langchain-ai/agent-inbox) README.
- [FinOps for agents](https://www.infoworld.com/article/4138748/finops-for-agents-loop-limits-tool-call-caps-and-the-new-unit-economics-of-agentic-saas.html), InfoWorld, Mar 2026. An opinion piece, used as a checklist.

### Papers

- [Real-Time Deadlines Reveal Fragile Temporal Adaptation in LLM Strategic Dialogues](https://arxiv.org/abs/2601.13206), Sehgal et al. The list gives an earlier title.
- [From Agent Loops to Structured Graphs: A Scheduler-Theoretic Framework for LLM Agent Execution](https://arxiv.org/abs/2604.11378), Wei, Apr 2026, read in part. A position paper with no empirical results.

### Carried over from the harness guide

- [Ranking Engineer Agent](https://engineering.fb.com/2026/03/17/developer-tools/ranking-engineer-agent-rea-autonomous-ai-system-accelerating-meta-ads-ranking-innovation/), Meta, for hibernate and wake.
- [Scaling Managed Agents](https://www.anthropic.com/engineering/managed-agents), Anthropic, for resuming from a session log.
