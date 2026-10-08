# Agent Core Tools Guide

Oct 3, 2026 · @Nathan Borror

## What the core tool set is

Every coding harness has converged on the same few jobs: run a command, read a file, edit a file, write a file, and search. The names and schemas differ between products, and the jobs do not. Lilian Weng's survey puts it as "the core interface of mainstream coding agents has become stabilized" ([Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/)).

This guide is a companion to the [Agent Harness Engineering Guide](000_agent_harness_guide.md). That guide covers tool design principles in general. This one covers the built-in tools themselves: what real harnesses expose, how they behave at the edges, and what to copy.

### How small the set can be

- **Pi**, the agent OpenClaw is built on, enables four tools by default: `read`, `bash`, `edit`, and `write`. Its author's claim is that "these four tools are all you need for an effective coding agent", and its system prompt and tool definitions together come in under 1,000 tokens ([Mario Zechner](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)).
- **Codex** registers no file read or search tool at all. The model reads and searches through the shell and edits with `apply_patch`.
- **Claude Code** leaves its Glob and Grep tools out by default on macOS and Linux and searches through Bash.

### Why the details matter

The SWE-agent paper measured the interface directly. With the same model, an agent with a purpose-built file viewer, search commands, and edit command resolved 18.0% of SWE-bench Lite against 11.0% for a shell-only agent, a 64% relative increase ([SWE-agent](https://arxiv.org/abs/2405.15793)). Its ablations put numbers on individual choices, and they appear throughout this guide. The models are from 2024, so read the numbers as direction.

### Where the facts come from

Tool names, schemas, limits, and description text below were read from source code and official references on 2026-10-03: Codex, OpenCode, Pi, and Cline from their repositories, Claude Code and the Anthropic API tools from their documentation. Claude Code's docs give schemas and behavior and do not publish the description text shown to the model. Several of these tools changed during 2026, so older write-ups describe names that no longer exist.

## What the sources agree on

Eight ideas hold across the harnesses and the two measurement sources, SWE-agent and Aider.

1. **Keep the set small and lean on what models already know.** Models have been trained on bash and on read, write, and edit tools with similar schemas. SWE-agent's first principle is that actions "should be simple and easy to understand".
2. **Edits identify text by content, never by line number.** Aider's benchmarks found models "terrible at working with source code line numbers" ([Aider](https://aider.chat/docs/unified-diffs.html)). Every current harness matches on the text to be replaced and requires the match to be unique.
3. **Every action returns concise, informative feedback.** After an edit, say what changed or what broke. After a command, return the output and the exit status.
4. **Put guardrails in the tool.** SWE-agent's edit command ran a linter and discarded edits that introduced syntax errors. Removing that check cost 3.0 points.
5. **Bound every result, and say what was cut and how to get the rest.** The common pattern is to save the full output to a file and return a slice plus the path.
6. **Write errors as instructions.** A good error names what failed and the next action. Pi's read tool, on a line too long to return, replies with the exact `sed` command to use.
7. **Tolerate approximately correct input.** Cline's read tool accepts several shapes for its file list. Codex's patch parser strips a heredoc wrapper the model sometimes adds. OpenCode routes malformed calls to an `invalid` tool that explains the schema error.
8. **Tool definitions depend on the model family.** OpenCode and Cline both give GPT-family models `apply_patch` and everyone else string replacement. Claude Code leaves its to-do tools off for newer models.

## The shell tool

The shell tool takes a command string and returns its output, and almost all of its design is in four decisions: how state carries between calls, what happens at the time limit, how output is cut, and how long-running work is handled.

### The schemas in use

| Harness | Tool and parameters | Time limit | Output cap | Long-running commands |
| --- | --- | --- | --- | --- |
| Claude Code | `Bash(command, timeout?, description?, run_in_background?)` | 2 minutes by default, 10 at most | About 30,000 characters inline | Background flag. A command that hits its limit moves to the background. |
| Codex | `exec_command(cmd, workdir?, tty?, yield_time_ms?, max_output_tokens?)` and `write_stdin(session_id, chars?)` | No kill. Yields after 10 seconds by default. | 10,000 tokens | Built in. An unfinished command becomes a session the model polls. |
| OpenCode | `bash(command, timeout?, workdir?)` | 2 minutes by default | 2,000 lines or 50 KB | None on this tool |
| Pi | `bash(command, timeout?)`, timeout in seconds | None by default | 2,000 lines or 50 KB | None, by design |
| Cline | `run_commands(commands[])` | 30 seconds by default | About 48,000 characters | None. The description says to background in the shell. |
| Anthropic API tool | `bash(command)` or `bash(restart: true)` | Yours to set. The example uses 30 seconds. | Yours to implement | None |

### State between calls

Every harness except Anthropic's reference implementation starts a new process for each command.

- **Carry only the working directory.** In Claude Code a `cd` carries over to later commands while it stays inside the project, and environment variables do not. If a `cd` lands outside, the directory is reset and the result says `Shell cwd was reset to <dir>`.
- **Or pass the directory as a parameter.** Codex and OpenCode take a `workdir`. OpenCode's description tells the model to "use `workdir` instead" of `cd <directory> && <command>` patterns.
- **A persistent shell is the alternative.** Anthropic's reference keeps one bash process alive and prints a unique sentinel line after each command to find where its output ends. The cost appears at the time limit: the example kills the process group and restarts the session, and all state is lost.

Codex also fixes the environment for every command so that nothing waits on a pager or emits color codes: `TERM=dumb`, `NO_COLOR=1`, `PAGER=cat`, `GIT_PAGER=cat`, and a UTF-8 locale.

### What the time limit does

Killing the process is the weakest choice, because a long build or test run is then lost. The harnesses take three positions.

| Policy | Harness | What the model receives |
| --- | --- | --- |
| Kill, and say how to retry | OpenCode, Pi, the Anthropic example | OpenCode appends: "If this command is expected to take longer and is not waiting for interactive input, retry with a larger timeout value" |
| Move to the background | Claude Code | "Command did not complete within its 120s timeout and was moved to the background", with a task ID and the path of the output file |
| Never kill, yield a handle | Codex | Whatever output exists, plus a session ID. The model polls or sends input with `write_stdin`. |

Pi takes a fourth position, which is to have no background support at all. Its author's argument is that process tracking, output buffering, and cleanup add complexity, and that the model can use tmux.

### Output

Claude Code, OpenCode, and Anthropic's example merge stdout and stderr into one stream in the order produced. They differ on which part survives a cap.

- **Keep the tail for command output.** OpenCode and Pi return the last 2,000 lines or 50 KB, because errors and summaries come at the end.
- **Keep the head and tail and cut the middle.** Codex and Cline do this, with a marker such as `…N tokens truncated…`.
- **Save everything to a file.** Claude Code, OpenCode, and Pi write the full output to disk and return the path, so the model can read or search the rest.

Claude Code treats success and failure differently. A successful command over the cap returns the file path and the first 2,000 characters. A failed one returns a head-and-tail excerpt of about 10,000 characters. It also knows that an exit code of 1 from `grep`, `find`, `diff`, or `test` is an ordinary answer and does not count it as a failure.

Empty output should be stated. OpenCode and Pi return `(no output)`.

### Interactive programs

A plain shell tool cannot drive an editor, a pager, or a password prompt. Claude Code's and Anthropic's docs say so, and Cline's description tells the model to use non-interactive flags. Two approaches go further:

- Codex's `exec_command` accepts `tty: true` to allocate a terminal, and `write_stdin` sends keystrokes, including an interrupt.
- The tui-use project runs a program in a terminal emulator and gives the agent a plain-text snapshot of the screen. Its key feature is a `wait` command that blocks until the screen has been stable for a short window, which solves the problem of knowing when the program has finished responding ([tui-use](https://github.com/onesuper/tui-use)).

### Validation is a tripwire

Anthropic's bash tool documentation shows a command allowlist and then explains why it is weak: its tokenizer misses an operator glued to a word, as in `cat data.txt|grep x`. Its conclusion is "the real control is isolation". Google's agent-shell-tools takes the same position and adds a useful rule for the allowlist you do write: "write rules per operation, not per binary", because allowing a command that can use the user's credentials grants that capability ([agent-shell-tools](https://github.com/google/agent-shell-tools)).

## Reading and searching

A read tool returns a bounded window of a file with enough information to ask for the next window. Search is either a pair of dedicated tools or the shell, and the trend in 2026 is toward the shell.

### Read

| Harness | Parameters | Default window | Line numbers |
| --- | --- | --- | --- |
| Claude Code | `file_path`, `offset?`, `limit?`, `pages?` | A token cap. Over it, the first page with a `PARTIAL view` notice. | Yes |
| OpenCode | `filePath`, `offset?`, `limit?` | 2,000 lines, 2,000 characters per line, 50 KB | `N: content` |
| Pi | `path`, `offset?`, `limit?` | 2,000 lines or 50 KB | None |
| Cline | A list of files, each with `start_line?` and `end_line?` | 2,000 lines or about 47,000 characters | Not checked |
| Anthropic text editor | `view` with `path` and `view_range?` | An optional character cap | `N: text` in the example |
| Codex | No read tool. The model uses `cat`, `sed -n`, and `rg`. | The shell's output budget | None |

Details worth copying:

- **A footer that gives the next call.** OpenCode ends a partial read with `(Showing lines 1-2000 of 5321. Use offset=2001 to continue.)`. Pi does the same.
- **A window that is neither tiny nor the whole file.** In SWE-agent's ablation a 100-line viewer scored 18.0%, a 30-line viewer 14.3%, and the full file 12.7%. OpenCode's description tells the model to avoid "tiny repeated slices".
- **Useful not-found errors.** OpenCode adds "Did you mean one of these?" with up to three similar names.
- **Deduplication.** Claude Code returns a short unchanged-file result when the file has not changed since an earlier read.
- **Images and PDFs through the same tool.** Claude Code, OpenCode, and Pi return images as attachments. Claude Code reads long PDFs in page ranges of up to 20.

Line numbers are a real trade-off. They help the model refer to places and are required for any line-based insert. They also leak into edits: OpenCode's edit description has to tell the model never to include the line-number prefix in the text to replace. Pi returns raw text and avoids the problem.

### Search

Claude Code now leaves its Glob and Grep tools out by default on macOS and Linux. The model runs `find` and `grep` through Bash, and the harness substitutes fast embedded versions. Codex has never had search tools and tells the model to prefer `rg`. OpenCode and Cline keep dedicated tools, and Pi ships them disabled.

If you do build search tools, the sources give clear rules:

- **Summarize and cap.** OpenCode caps both tools at 100 results. SWE-agent capped at 50 and, past that, returned no results and asked for a more specific query.
- **Never page one result at a time.** SWE-agent's iterative search, with next and previous commands, scored 12.0%, which was worse than having no search tool at 15.7%. Agents stepped through every match until they ran out of budget.
- **Default to file names.** Claude Code's Grep has three output modes and defaults to listing matching files, with content and counts on request.
- **Return the engine's diagnostic on a bad pattern.** An earlier Claude Code version answered a rejected regex with "No files found", which the docs treat as a bug that was fixed. Empty and failed must look different.
- **Respect ignore files** for content search.

A dedicated search tool earns its place when you need its calls to be distinct from arbitrary shell commands, for permission rules or for rendering. Otherwise the shell already does the job.

## Editing files

The edit tool is where harnesses differ most and where most tool failures occur. Three formats are in use, the right one depends on the model family, and the main design choice is how forgiving the matcher should be.

### The three formats

| Format | The model sends | Used by | Strength | Weakness |
| --- | --- | --- | --- | --- |
| String replacement | A file path, the exact old text, and the new text | Claude Code `Edit`, OpenCode `edit`, Pi `edit`, Cline `editor`, Anthropic `str_replace` | Simple, and the old text is its own staleness check | One location per replacement unless the tool takes a list |
| Patch | A free-text patch with file headers and `+`, `-`, and context lines | Codex `apply_patch`, and OpenCode and Cline for GPT-family models | Several files and locations in one call, with adds, deletes, and renames | A grammar the model must have been trained on |
| Whole file | The path and the full new content | Every `write` tool, and Aider's `whole` format | Cannot mismatch | Slow and costly for a small change, and invites elided code |

### String replacement

The rules are the same everywhere: the old text must appear in the file, and it must appear exactly once.

```text
edit(path, old_text, new_text, replace_all?)
  0 matches  -> error: not found; the text must match exactly, including whitespace
  1 match    -> replace
  2+ matches -> error: found N occurrences; add surrounding context to make it unique
```

Pi's current tool takes a list of replacements for one file. Every entry is matched against the original file, entries may not overlap, and its guidance tells the model to keep each old text "as small as possible while still being unique".

### The patch format

Codex's `apply_patch` is a free-form tool constrained by a grammar, and the model does not wrap it in JSON. A patch looks like this:

```text
*** Begin Patch
*** Add File: hello.txt
+Hello world
*** Update File: src/app.py
*** Move to: src/main.py
@@ def greet():
-print("Hi")
+print("Hello, world!")
*** Delete File: obsolete.txt
*** End Patch
```

- There are no line numbers. An `@@` line carries one line of context, usually a function or class header, to narrow the position.
- Within a file, chunks must appear in file order, and the matcher only searches forward.
- The whole patch is parsed and checked against the files before anything is written.
- Success returns a short list of files added, modified, and deleted. The prompt tells the model not to re-read files afterward, because "the tool call will fail if it didn't work".

### How forgiving to be

Models reproduce text with small errors: trailing spaces, changed indentation, curly quotes for straight ones. The harnesses sit at different points between strict and lenient.

| Harness | Matching after an exact attempt fails |
| --- | --- |
| Claude Code | None. "It doesn't use regex or fuzzy matching." |
| Pi | One pass: Unicode normalization, trailing whitespace, smart quotes, dashes, unusual spaces |
| Codex `apply_patch` | Three more passes per line: ignore trailing whitespace, ignore all leading and trailing whitespace, normalize Unicode punctuation |
| OpenCode | A chain of nine matchers, including indentation-flexible, whitespace-normalized, and block matching by first and last line with a similarity score for the middle |

Leniency needs guards, and OpenCode and Pi show which ones:

- **Uniqueness per candidate.** OpenCode skips any fuzzy candidate that occurs more than once.
- **A size check.** OpenCode refuses when the matched span is much larger than the old text supplied, with the message "Re-read the file and provide the full exact oldString".
- **Write back only what changed.** When Pi matches in normalized space, it rewrites only the changed lines and copies the rest from the original, so normalization does not silently alter the file.

Aider's measurements, on 2023-era models, support leniency: disabling flexible patch application produced a ninefold increase in editing errors on its benchmark. Its stated rule is to be "maximally flexible when interpreting" edit instructions.

### Choose the format by model family

OpenCode's registry contains the rule in four lines: models whose ID contains `gpt-`, other than GPT-4 and open-weight variants, get `apply_patch` and lose `edit` and `write`. Everything else gets `edit` and `write`. Cline's routing table makes the same split. Aider keeps a format per model in a settings file, with search-and-replace blocks as the default, a fenced variant for Gemini, and whole-file for weaker models.

The evidence that format matters is old but large. On Aider's refactoring benchmark, GPT-4 Turbo scored 20% with search-and-replace blocks and 61% with unified diffs, mostly because the diff format stopped it from replacing code with placeholder comments. Aider also found that asking for edits inside JSON function calls made models write worse code, because of escaping.

### Safety checks around the edit

| Check | What it does | Who does it |
| --- | --- | --- |
| Read before edit | Rejects an edit to a file the model has not read in this conversation | Claude Code, relaxed for newer models. OpenCode's description states it, and the code read does not enforce it. |
| Changed on disk | Allows the edit only if the match is exact and unique, and tells the model the file has other changes | Claude Code |
| Per-file lock | Serializes concurrent edits to one file | OpenCode, Pi |
| Line endings and BOM | Detects and preserves them | OpenCode, Pi |
| Diagnostics after edit | Appends language-server errors to the result | OpenCode, and Claude Code with a plugin |
| Lint gate | Discards an edit that introduces a syntax error | SWE-agent |

The last two are the same idea at different strengths. SWE-agent's gate was worth 3.0 points, and having an edit command at all was worth 7.7 over editing with `sed` and shell redirection. The paper also notes the gate's cost: a change that is only valid as two edits must be made as one.

Claude Code counts a file as read when the model viewed it through the shell with a simple command such as `cat`, `head`, or `grep` on that one file, which keeps the rule from blocking shell-first workflows.

### Write

A write tool creates or overwrites a file with the full content. Pi's guidance is "use write only for new files or complete rewrites". Claude Code requires a prior read before overwriting an existing file on older models. Both OpenCode and Pi create parent directories automatically.

## Tool results as context

A tool result is prompt text for the next step, so its shape matters as much as the tool's schema. The harnesses agree on bounding every result and differ on the numbers.

### Caps in use

| Harness | Cap | When exceeded |
| --- | --- | --- |
| Claude Code Bash | About 30,000 characters | Full output saved to a file, with the path and a 2,000-character preview |
| Codex | 10,000 tokens | Head and tail kept, with the original token count and total lines stated |
| OpenCode, all tools | 2,000 lines or 50 KB | Full output saved to a file, with the path and a hint |
| Pi | 2,000 lines or 50 KB | Full output saved to a temp file, with the path in a footer |
| Cline | About 48,000 characters | Middle cut |

### Say what was cut and what to do next

OpenCode's generic truncation message is a good template:

```text
...N lines truncated...

The tool call succeeded but the output was truncated. Full output saved to: <file>
Use Grep to search the full content or Read with offset/limit to view specific sections.
```

When the agent has a sub-agent tool, the hint changes to tell it to delegate reading the file, to save context. OpenCode's shell description also tells the model not to pipe through `head` or `tail` itself, because the full output is already captured. That matters: Ryan Lopopolo records agents piping an expensive test run through `head`, which can close the pipe, kill the run early, and hide the exit status.

### Errors as instructions

The best error messages in these codebases carry the recovery step.

- **Pi, on a line over the byte limit:** `[Line 812 is 1.2MB, exceeds 50.0KB limit. Use bash: sed -n '812p' <path> | head -c 51200]`
- **OpenCode, on a missing file:** "File not found" followed by "Did you mean one of these?"
- **Cline's older edit tool, on a failed match:** it reverted the file and returned its current content in the error, so the model could retry without another read. After three failures in a row it told the model to change approach.
- **Claude Code's web search, at its per-session cap:** it returns a notice telling the model to continue with what it has, "rather than an error that would invite a retry".
- **Any tool, on arguments that fail the schema:** OpenCode returns the validation detail and "Please rewrite the input so it satisfies the expected schema."

### Keep success quiet

A successful edit in Pi returns one line. Codex returns a list of changed files. SWE-agent replaced empty command output with a fixed sentence so that silence was never ambiguous. Verbose success output is context the model pays for on every later step.

## Planning and interaction tools

Three small tools sit beside the file and shell tools in most harnesses: a to-do list, a way to ask the user, and sometimes a way to declare the work finished. The harnesses agree least here.

### To-do lists

The common shape replaces the whole list on every call and allows one item in progress.

```text
update_plan(explanation?, plan: [{ step, status: pending | in_progress | completed }])
```

That is Codex's schema. OpenCode's `todowrite` adds a priority and a cancelled status, and Claude Code's `TodoWrite` adds a present-tense label for display. Claude Code also has per-task tools that support dependencies between tasks.

Two harnesses have moved away from the idea:

- **Claude Code** leaves these tools out by default on newer models. The docs' reason is that newer models keep track of multi-step work "without a written checklist, and the tools' definitions and reminders take up context".
- **Pi** refuses to add them. Its author's view is that to-do lists "generally confuse models more than they help", and that a plan belongs in a file with checkboxes, where it survives the session and can be versioned.

A reasonable position for a new harness is to start with a plan file and add a to-do tool only if your evals show the model losing track.

### Asking the user

The three harnesses that have this tool converged on structured multiple choice.

| Harness | Tool | Shape |
| --- | --- | --- |
| Claude Code | `AskUserQuestion` | Questions with a short header and options that each have a label and a description. Multi-select optional. |
| Codex | `request_user_input` | One to three questions, each with two or three mutually exclusive options |
| OpenCode | `question` | The same shape as Claude Code's |

All three add a free-text answer automatically and tell the model not to include an "Other" option. Codex and OpenCode tell the model to put the recommended option first and label it. Claude Code can time the question out, submit what was selected, and tell the model the user may be away.

### Declaring completion

Most harnesses have no completion tool. The loop ends when the model replies without calling a tool. Cline is the exception: its `submit_and_exit` takes a summary and a `verified` flag, and its description says to submit "because you have observed evidence" that the solution works.

A completion tool gives the harness a place to demand verification. It also adds a protocol the model must follow, and the harness guide records a case where a two-step completion protocol tuned for one model made another time out on tasks it had already solved.

### Plan mode

Claude Code has tools to enter and exit a plan mode, with the exit presenting the plan for approval. Pi gets the same effect without a mode by starting the agent with only read-only tools.

## Concurrency

Models can request several tool calls in one reply, and the harness decides which may run together. The rule in use is that read-only calls run in parallel and anything that changes state runs alone.

### How the harnesses enforce it

- **Codex** marks each tool as parallel-safe or not. Parallel-safe tools take a shared lock and the rest take an exclusive one, so `apply_patch` and `update_plan` always run alone.
- **Claude Code**, according to a third-party reading of its source, classifies tools as concurrent-safe or exclusive, starts executing tool calls while the reply is still streaming, and buffers results so they are returned in the order requested ([Dive into Claude Code](https://arxiv.org/abs/2604.14228)). When one shell command errors, in-flight sibling commands are aborted.
- **OpenCode and Pi** serialize edits to the same file with a per-file lock.

Result order matters. The model expects each result to line up with the call that produced it, so run in parallel and return in order.

### What parallel calls buy

A study of web research agents measured it. On 100 BrowseComp tasks, one tool call per turn reached 66% accuracy at $102.50. Three calls per turn reached 68% at $65.70 and 41% less wall-clock time ([W&D](https://arxiv.org/abs/2602.07359)). The saving comes from one reasoning step covering several calls. Wider was not better: five calls per turn scored 60%. The study is about search and browsing, so treat it as indicative for coding.

The harnesses prompt for parallelism in their tool descriptions. OpenCode's read tool says "call this tool in parallel when you know there are multiple files you want to read".

### Code as the orchestration layer

Codex has gone a step further for most of its models. Ten of the eleven models in its catalog see a single free-form `exec` tool that runs JavaScript, with the ordinary tools available inside it as functions. The prompt tells the model to batch independent reads with `Promise.allSettled` and to keep edits and approvals sequential. Parallelism, filtering, and control flow then happen in code, and only the script's output returns to the context.

This is the same idea as Anthropic's code execution over MCP, applied to the built-in tools. It is worth knowing about and not a first-version feature.

## How real harnesses define these tools

The same jobs appear under different names. This table maps them as of the versions read on 2026-10-03.

| Job | Claude Code | Codex | OpenCode | Pi | Cline | Anthropic API tools |
| --- | --- | --- | --- | --- | --- | --- |
| Run a command | `Bash` | `exec_command`, `write_stdin` | `bash` | `bash` | `run_commands` | `bash` |
| Read a file | `Read` | Through the shell | `read` | `read` | `read_files` | `view` |
| Edit a file | `Edit` | `apply_patch` | `edit`, or `apply_patch` for GPT models | `edit` | `editor`, or `apply_patch` for GPT models | `str_replace`, `insert` |
| Write a file | `Write` | `apply_patch` with an add-file header | `write` | `write` | `editor` | `create` |
| Find files | `Glob`, off by default on macOS and Linux | Through the shell | `glob` | `find`, off by default | `search_codebase` | `view` on a directory |
| Search contents | `Grep`, off by default on macOS and Linux | Through the shell | `grep` | `grep`, off by default | `search_codebase` | None |
| Track a plan | `TodoWrite` or task tools, off on newer models | `update_plan` | `todowrite` | None | None | None |
| Ask the user | `AskUserQuestion` | `request_user_input` | `question` | None | `ask_question` | None |
| Finish | None | None | None | None | `submit_and_exit` | None |

### What is distinctive about each

- **Claude Code** is the strictest about edits, with exact matching and read-before-edit, and the most developed for background work. A timed-out command keeps running and its output goes to a file.
- **Codex** has the smallest tool list and the most unusual shell. Commands never time out. They yield a session handle. Most of its models now drive the tools from JavaScript.
- **OpenCode** puts the most text in its tool descriptions and the most leniency in its edit matcher, and it appends formatter and language-server results to every edit.
- **Pi** is the minimal case: four tools, no line numbers, no to-dos, no background processes, no sub-agent tool, and a system prompt under 1,000 tokens. Each tool contributes its own line and guidelines to the system prompt.
- **Cline** accepts loose input shapes, batches several commands or files per call, and is the only one with a completion tool.
- **The Anthropic API tools** have no schema for you to write. The model already knows them, and your code supplies the implementation: a persistent shell, truncation, and uniqueness checking for `str_replace`.

Two things changed in 2026 that older write-ups get wrong. Codex's `shell` tool with an argument array and a `timeout_ms` has been replaced by `exec_command`. Cline's `replace_in_file` and `write_to_file` have been replaced by `editor` and `apply_patch`.

## Starter design

Build four tools and one shared layer that shapes every result, then add checks in the order failures appear. This section is my synthesis of the sources, so treat it as a starting design to test.

&#91;embedded content: tool call path · validate, permission, execute, shape result, append\]

A schema error, a denial, and a failed command all pass through the same shaping step as a success, so the model always receives bounded text that says what happened and what to do next.

### Starter schemas

```text
shell(command, workdir?, timeout_ms?, background?)
  -> output, exit code, and when cut: a note, and the path of the full output

read(path, offset?, limit?)
  -> a window of lines, then "(Showing lines a-b of N. Use offset=K to continue.)"

edit(path, edits: [{ old_text, new_text }], replace_all?)
  -> "Edited <path>", plus diagnostics, or an error stating how many matches were found

write(path, content)
  -> "Wrote <path>". For new files and complete rewrites.
```

If you support GPT-family models, add `apply_patch` as an alternative to `edit` and `write` and select by model.

### Build order

1. **Shell.** Start a new process per call in a working directory passed as a parameter. Fix the environment so nothing pages or colors. Merge the output streams. At the time limit, kill the process tree and return a message that says how to retry with a longer limit.
2. **Read.** Return up to 2,000 lines or 50 KB with a footer naming the next offset. Suggest near matches when a path is not found.
3. **Edit.** Exact string replacement that requires one match. Report zero and multiple matches as different errors. Preserve line endings, and lock per file.
4. **Write.** Create parent directories. Refuse to overwrite a file the model has not read.
5. **The result layer.** One function that every tool's output passes through: cap it, save the full text to a file when cut, and append what to do next. Return schema failures in the same form.
6. **Read tracking.** Record what the model has read and when. Reject edits to unread files, and note when a file changed on disk since the read.
7. **Measured leniency.** Add one normalization pass for whitespace and Unicode punctuation, with a uniqueness check and a size check, when your traces show exact-match failures.
8. **Background commands.** Move a command to the background at its time limit, stream its output to a file, and add a tool to stop it.
9. **Diagnostics after edits.** Run a syntax check or language server on the edited file and append errors to the result.
10. **Parallel reads.** Mark tools as read-only or exclusive, run read-only calls together, and return results in request order.
11. **Asking the user.** One structured question tool. Add a to-do tool only if evals show the need.

### Defaults to adopt until you have evidence otherwise

| Decision | Default | Reason |
| --- | --- | --- |
| Shell state | New process per call, working directory as a parameter | What every product harness read here does |
| Shell time limit | 2 minutes, raised per call by the model | Claude Code's and OpenCode's default |
| Shell output | Keep the tail, save the rest to a file | Errors and summaries come last |
| Read window | 2,000 lines or 50 KB | OpenCode's, Pi's, and Cline's default |
| Paths | Absolute | Fixed a class of errors in Anthropic's SWE-bench agent |
| Edit format | String replacement, unique match | The model-independent baseline |
| Edit format for GPT models | `apply_patch` | OpenCode and Cline both route this way |
| Search | Through the shell, with `rg` installed | Codex's and Claude Code's current choice |
| To-do tool | None at first | Disputed, and it costs context |
| Completion | A reply with no tool call | No protocol for the model to get wrong |
| Tool descriptions | A few sentences each | Pi works with under 1,000 tokens for prompt and tools together |

## Open questions and disagreements

The harnesses agree on the jobs and on matching edits by content. They disagree on the points below, and none of the disagreements has been settled by a published comparison on current models.

- **Dedicated search tools or the shell.** Codex and Claude Code search through the shell. OpenCode's shell description forbids exactly that and directs the model to its Glob and Grep tools. SWE-agent's 2024 result favored summarized search tools over none by 2.3 points.
- **Strict or lenient edit matching.** Claude Code matches exactly and relies on the model to retry. OpenCode tries nine matchers. Aider's data favors leniency on older models. No source measures the rate of wrong-location edits that leniency introduces.
- **Whether a to-do tool helps.** Codex and OpenCode ship one. Claude Code has turned it off for newer models, and Pi's author says it confuses models.
- **One shell or a process per command.** Anthropic's reference keeps a persistent shell. Every product harness read here starts a new process.
- **Background support in the tool or outside it.** Claude Code and Codex build it in. Pi says to use tmux.
- **Line numbers in read output.** Claude Code and OpenCode add them. Pi does not.
- **A completion tool.** Cline has one with a verification flag. The others end the loop when the model stops calling tools.
- **Tool calls or code.** Codex has moved most models to writing JavaScript that calls tools. The others still use one tool call per action.

The measurements are dated. SWE-agent's ablations used GPT-4 Turbo and Claude 3 Opus in 2024, and Aider's format benchmarks used GPT-3.5 and GPT-4 era models. The direction of their findings matches what the 2026 codebases do, and the sizes of the effects should not be assumed to hold.

## Sources

Repositories were read from shallow clones on 2026-10-03, and documentation pages were read in full unless noted.

### Harness source code

- [openai/codex](https://github.com/openai/codex), commit `3e238776`. Tool specs, the apply-patch crate, unified exec, truncation, and prompts.
- [OpenCode](https://github.com/sst/opencode), now at anomalyco/opencode, commit `907b3bc5`. The tool directory with its description files. A newer rewrite of the tool layer in the same repository was not read.
- [Pi](https://github.com/badlogic/pi-mono), now at earendil-works/pi, commit `83692682`, and the author's post [What I learned building an opinionated and minimal coding agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/), Nov 2025. The code is newer than the post.
- [cline/cline](https://github.com/cline/cline), commit `39ff2359`. Current tool definitions. The older tool prompts were not found in this snapshot.

### Documentation

- [Claude Code tools reference](https://code.claude.com/docs/en/tools-reference) and the Agent SDK type reference. These give schemas and behavior and do not publish model-facing descriptions.
- Anthropic API [bash tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/bash-tool) and [text editor tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/text-editor-tool).
- Aider: [edit formats](https://aider.chat/docs/more/edit-formats.html), [unified diffs](https://aider.chat/docs/unified-diffs.html), and [benchmarks](https://aider.chat/docs/benchmarks.html). Results are from 2023 and early 2024 models.

### Papers and tools

- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering](https://arxiv.org/abs/2405.15793), 2024.
- [Dive into Claude Code: The Design Space of Today's and Future AI Agent Systems](https://arxiv.org/abs/2604.14228), Apr 2026, read in part. A third-party reading of an older Claude Code version.
- [W&D: Scaling Parallel Tool Calling for Efficient Deep Research Agents](https://arxiv.org/abs/2602.07359), Feb 2026. Web research agents only.
- [google/agent-shell-tools](https://github.com/google/agent-shell-tools) and [onesuper/tui-use](https://github.com/onesuper/tui-use), READMEs.

### Carried over from the harness guide

- [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents), Anthropic.
- [Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/), Lilian Weng.
- [lopopolo/harness-engineering](https://github.com/lopopolo/harness-engineering), for the piped-output failure.
