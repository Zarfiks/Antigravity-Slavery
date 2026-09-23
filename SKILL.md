---
name: antigravity-slavery
description: Delegate work to the Antigravity CLI (`agy`) as disposable subagent workers, so the orchestrator's context stays small. Use when a job can be farmed out — bulk file analysis, parallel review passes, mechanical rewrites in an isolated git worktree, summarisation, cross-checking an answer with a second model family — or when the user asks to use agy, Antigravity, Gemini, or "subagents". Covers the six worker tiers, how many workers to launch, exact invocation, shared memory between workers, structured output, cost reality, and the failure modes that silently return nothing.
---

# Antigravity Slavery

`agy` is the Antigravity CLI. In **print mode** (`-p`) it runs one prompt to
completion and exits. That makes it a disposable worker: you fan several out in
parallel, keep only their conclusions, and never pay context for the files they
read.

You stay the orchestrator. Workers do not talk to each other. They remember
nothing between calls unless you resume a conversation by id or give them the
shared memory file (see **Memory**).

Everything below goes through two scripts in this skill's `scripts/` folder.
Use them instead of calling `agy` by hand: they encode every rule in this file.

```bash
scripts/agy-slave.sh  [options] <tier> "<prompt>" [workdir]        # one worker
scripts/agy-fanout.sh [-j N] [options] <tier> <workdir> <tasks.txt> # many workers
```

## Tiers

Best to cheapest. Use the tier name with the scripts and when talking to the user.

| Tier | Model | Use for |
|---|---|---|
| `gemini-high`   | Gemini 3.8 Flash (High)      | Hard reasoning, architecture, anything where being wrong is expensive |
| `gemini-medium` | Gemini 3.8 Flash (Medium)    | Normal analysis, review passes, "explain this module" |
| `gemini-low`    | Gemini 3.8 Flash (Low)       | Mechanical work with a clear spec: extract, reformat, list, classify |
| `opus`          | Claude Opus 4.6 (Thinking)   | Second opinion from another model family; subtle code semantics |
| `sonnet`        | Claude Sonnet 4.6 (Thinking) | Cheaper second opinion; prose and docs |
| `gpt-oss`       | GPT-OSS 120B (Medium)        | Throwaway: yes/no checks, string munging, smoke tests of your pipeline |

Each tier falls back to an older model of the same strength when the server
answers `503 No capacity available`. A raw model id from `agy models` also
works as the tier argument. The model list changes: if a call fails with an
unknown-model error, run `agy models` and override the chain, for example
`AGY_CHAIN_GEMINI_HIGH="gemini-3.9-flash-high gemini-3.8-flash-high"`.
See `references/models.md`.

## How many workers

Decide before you launch anything. Every call costs about **12 000 input
tokens of fixed overhead** and 5 seconds to several minutes.

| Situation | Workers |
|---|---|
| Answer is two `grep`s or one short file away | **0** — do it yourself |
| One big read: a long log, a large module, a whole directory | **1**, `gemini-medium` |
| A judgement you will act on without checking | **2** — `gemini-high` and `opus` on the same prompt; compare |
| The same question over N independent parts (modules, files, services) | **N**, via `agy-fanout.sh -j 4` |
| A code change | **1** per independent change, each with `-w` (worktree) |

Two model families that agree is a signal. Two calls to the same family that
agree is not.

## Access levels

`agy` has no enforced read-only mode. What the flags do in practice (v1.2.7):

| Flags | Shell commands | File edits in the workspace |
|---|---|---|
| default (no flag) | **denied** automatically | **allowed** |
| `-f` / `--full` (`--dangerously-skip-permissions`) | allowed | allowed |
| `-w` / `--worktree` (implies `--full`) | allowed | allowed, but only inside a throwaway worktree |

`agy --mode plan` does **not** stop file edits either.

So:

- **Read-only jobs:** use the default. The script snapshots `git status` before
  and after, and prints `[warning] the worker modified files` if the worker
  edited something anyway. Put "Do not modify any file" in the prompt.
- **Jobs that change code:** always use `-w`. The worker gets its own
  `git worktree` of `HEAD` in a temp folder. Your checkout is not touched. The
  script prints the diffstat and the commands to apply or discard the change.
  Uncommitted changes in your checkout are **not** in the worktree.
- **`--full` without `-w`:** only when the worker must run commands (tests, a
  build) against your real checkout. Tell the user first.

If a default-mode worker returns nothing with `denied: command`, it tried to use
the shell. Rephrase ("use your file viewing tools, not shell commands") before
you reach for `--full`.

## Memory

Workers share nothing by default. `-m FILE` (or `AGY_MEMORY=FILE`) gives them a
shared notebook:

- before the call, the last 200 lines of `FILE` go in front of the prompt,
  marked as notes that may be stale;
- after a successful call, the script appends the task and the first 40 lines
  of the answer to `FILE`.

Use one memory file per job, not per project. Good pattern for a multi-stage
job: stage 1 workers map the code and write to memory; stage 2 workers read
those notes instead of re-reading the files. Keep the file out of git (the
bundled `.gitignore` excludes `.agy-memory*.md`).

Separately, every call (success or failure) is logged as one JSON line in
`${XDG_STATE_HOME:-~/.local/state}/agy-slave/runs.jsonl`: time, tier, model,
workdir, status, `conversation_id`, tokens, seconds, prompt head. Use it to
find a `conversation_id` to resume, or to total the token cost of a job.

## Resuming a worker

The cost line on stderr ends with `conversation=<id>`. Continue that worker
instead of paying the startup cost again:

```bash
scripts/agy-slave.sh -c <id> gemini-medium "Now do the same for control/" ./repo
```

## Structured output

For any fan-out you will aggregate mechanically, pass a JSON Schema. The script
then prints the parsed `structured_output` instead of prose:

```bash
scripts/agy-slave.sh -s examples/verdict.schema.json gemini-low "Is 17 prime?" .
# {"verdict": "yes", "reason": "17 has no divisors other than 1 and itself"}
```

Parsing prose out of free-text answers is how orchestration breaks.

## Fan-out

One prompt per line in a tasks file; `#` lines are skipped.

```bash
cat > tasks.txt <<'EOF'
In src/vision/, list every config key the code reads. Names only.
In src/control/, list every config key the code reads. Names only.
In src/webapp/, list every config key the code reads. Names only.
EOF
scripts/agy-fanout.sh -j 3 -o out -m .agy-memory.md gemini-medium . tasks.txt
```

Answers go to `out/NN.txt`, cost lines and errors to `out/NN.log`, and a summary
table to stderr. Budget **10+ minutes** for workers that read many files. Do not
set a short `-t` timeout: a killed worker returns nothing and you have paid for
it anyway. Run fan-outs in the background and keep working.

## Calling agy directly

Only if the scripts cannot be used. The form that works:

```bash
agy -p "<prompt>" --model <model-id> --add-dir <absolute path> --output-format json
```

Rules, each learned from a failure:

1. **Always `--add-dir <absolute path>`.** `agy` ignores the shell's current
   directory and runs in its own scratch folder. `cd` does nothing. Without
   `--add-dir` the worker hunts the disk for the file names you gave it — 3×
   the tokens and 4× the time — and may analyse **a different copy of the
   repository** with full confidence. On Windows give a Windows path
   (`cygpath -w` in Git Bash, `wslpath -w` in WSL). The flag can repeat.
2. **Check `.status`, not the exit code.** A failed run still exits 0 with
   `"status":"ERROR"` and the reason in `"error"`.
3. **Never pass `--effort` with `--model`.** The `-high/-medium/-low` suffix
   *is* the effort. The combination fails with `invalid model selection`.
4. **Use `--output-format json`** whenever a program reads the result.
5. **An empty `response` with `denied_actions`** means a tool was refused in
   headless mode. See **Access levels**.

## Cost reality

Measured on Windows, CLI v1.2.6–1.2.7:

| Job | Time | Tokens |
|---|---|---|
| `Say OK` (`gpt-oss`) | 3 s | 12 147 in |
| Read one small file, with `--add-dir` | 5 s | ~29 000 |
| Trivial question + JSON schema | 23 s | 30 122 in |
| List a directory, with `--add-dir` | 44 s | 32 254 |
| One-line fix in a worktree | 8 s | ~42 000 |
| Read one 342-line file **without** `--add-dir` | **168 s** | **93 492** |
| Two-file analysis, no `--add-dir` | killed at 420 s | nothing returned |

**Delegate** when the worker reads a lot and returns a little: surveying many
files, summarising a big log, the same review across ten modules.

**Do not delegate** what you can answer with two `grep`s. You pay 12k tokens
and up to a minute to save a 200-token read.

## Rules for the orchestrator

- Pick the cheapest tier whose answer you can **check** (a path, a line number,
  a list). Use `gemini-high` only for judgements you cannot check.
- Workers advise; you decide. Never let a worker's answer alone justify a
  destructive or security-relevant action.
- Read a worktree diff before you apply it.
- Tell the user which tier you used and what it cost when the job was large.

Failure modes and fixes: `references/troubleshooting.md`.
