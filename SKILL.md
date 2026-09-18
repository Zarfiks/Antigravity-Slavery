---
name: antigravity-slavery
description: Delegate work to the Antigravity CLI (`agy`) as disposable subagent workers, so the orchestrator's context stays small. Use when a job can be farmed out — bulk file analysis, parallel review passes, mechanical rewrites, summarisation, cross-checking — or when the user asks to use agy, Antigravity, Gemini 3.8, or "subagents". Covers the six-tier worker roster, exact invocation, structured output, cost reality, and the failure modes that silently return nothing.
---

# Antigravity Slavery

`agy` is the Antigravity CLI (`C:\Users\rdor\AppData\Local\agy\bin\agy`, v1.2.6). In
**print mode** it runs one prompt to completion and exits. That makes it a disposable
worker: you fan several out in parallel, keep only their conclusions, and never pay
context for the files they read.

You stay the orchestrator. Workers do not talk to each other and do not remember
anything between calls unless you resume a conversation by id.

## The roster

Six tiers, best to worst. `Call it` is the name to use when talking to the user.

| # | Call it           | Model ID                  | Good for |
|---|-------------------|---------------------------|----------|
| 1 | **Supreme**       | `gemini-3.8-flash-high`   | Hard reasoning, architecture questions, anything where being wrong is expensive |
| 2 | **Smart**         | `gemini-3.8-flash-medium` | Normal analysis, code review passes, "explain this module" |
| 3 | **Basic**         | `gemini-3.8-flash-low`    | Mechanical work with a clear spec: extract, reformat, list, classify |
| 4 | **Claudeman**     | `claude-opus-4-6-thinking`| Second opinion on a Supreme answer you distrust; subtle code semantics |
| 5 | **Mini Claudeman**| `claude-sonnet-4-6`       | Cheaper Claude-flavoured second opinion; prose and docs |
| 6 | **Dumbest**       | `gpt-oss-120b-medium`     | Throwaway: yes/no checks, string munging, smoke tests of your own pipeline |

Older families exist as fallbacks when a tier is out of capacity:
`gemini-3.7-flash-{high,medium,low}`, `gemini-3.6-flash-{high,medium,low}`,
`gemini-3.1-pro-{high,low}`. Run `agy models` to re-check the live list — do not
trust this table if a call fails with an unknown-model error.

## Invocation — the only form that works

```bash
agy -p "<prompt>" --model <model-id> --output-format json --dangerously-skip-permissions
```

Five rules, each learned from a failure:

1. **Never pass `--effort` together with `--model`.** Effort is already baked into
   the model id. `--model gemini-3.8-flash-high --effort medium` dies with
   `invalid model selection`, and the Claude models reject `--effort` outright.
2. **Always `--dangerously-skip-permissions`** in print mode. Without it a worker
   that decides to touch a file blocks on a permission prompt nobody can answer.
3. **Always `--output-format json`** when anything but a human reads the result.
4. **Check `.status`, not the exit code.** A worker that failed still exits 0.
5. **Hand it the files with `--add-dir` and an absolute Windows path.**
   This is the one that bites hardest. `agy` **ignores the shell's current
   directory**. It always runs in its own scratch dir — asked to `pwd`, a worker
   launched from a repo checkout answered
   `C:\Users\rdor\.gemini\antigravity-cli\scratch`. `cd`-ing before the call
   does nothing. Without `--add-dir` the worker cannot find the paths you named,
   so it hunts the disk for them — and may answer confidently about **a different
   copy of the file in a different repository**. That happened: a worker asked
   about `carpilot/vision/line_tracker.py` from one checkout silently read
   another checkout on the Desktop. Use `cygpath -w` to build the path from Git
   Bash; `--add-dir` is repeatable.

### What the JSON looks like

```json
{"conversation_id":"...","status":"SUCCESS","response":"OK\n",
 "duration_seconds":3.46,"num_turns":1,
 "usage":{"input_tokens":12147,"output_tokens":27,"thinking_tokens":0,
          "cache_read_tokens":0,"total_tokens":12174}}
```

On failure `status` is `ERROR` and `error` carries the reason, e.g.
`No capacity available for model gpt-oss-120b-medium` (HTTP 503). Exit code is
still 0. Retry on another tier.

### Structured output

Pass a JSON Schema and the result gains a parsed `structured_output` field:

```bash
agy -p "Is 17 prime? Answer using the schema." --model gemini-3.8-flash-low \
    --json-schema ./schema.json --output-format json --dangerously-skip-permissions
# -> "structured_output":{"reason":"17 is a prime number...","verdict":"yes"}
```

Use this for every fan-out you will aggregate mechanically. Parsing prose out of
`response` is how orchestration breaks.

## Cost reality — read before delegating

Delegation is not free and is often **not** the cheap option.

All numbers below are measured, not estimated.

| Job | Time | Tokens |
|---|---|---|
| `Say OK` (dumbest) | 3 s | 12 147 in |
| Trivial question + JSON schema | 23 s | 30 122 in |
| List a directory, **with** `--add-dir` | 44 s | 32 254 total |
| Read one 342-line file **without** `--add-dir` | **168 s** | **93 492 total** |
| Two-file analysis, no `--add-dir` | killed at 420 s | nothing returned |

Two things follow. Every call pays **~12 000 input tokens of fixed overhead**
before your prompt even starts. And the difference between the last two rows is
almost entirely `--add-dir`: a worker that has to search for your files burns
three times the tokens and four times the wall clock, or never finishes.

So:

**Delegate** when the worker reads a lot and returns a little — surveying many
files, summarising a big log, running the same review across ten modules. The
saving is the file content you never load.

**Do not delegate** a task you could finish with two `grep`s. You will pay 12k
tokens and a minute or more to save a 200-token read. In the session this skill
came from, two delegated code-analysis jobs both timed out with zero output
while direct `grep`/`sed` answered the same questions in seconds.

## Routing

Pick the cheapest tier that can be *checked*.

- Answer is verifiable by you afterwards (a file path, a line number, a list) →
  **Basic** or **Dumbest**.
- Answer is a judgement you will act on without checking → **Supreme**.
- Answer disagrees with your own reading, or the stakes are high → re-run on
  **Claudeman** and compare. Two families disagreeing is a signal; two calls to
  the same family agreeing is not.
- Never route safety-relevant or destructive decisions to a worker. Workers
  advise; the orchestrator decides.

## Fan-out

Launch workers in parallel in the background, then collect. Never block on one.

```bash
repo="$(cygpath -w "$PWD")"
for mod in vision control webapp; do
  agy -p "In carpilot/$mod/, list every config key the code reads. Names only." \
      --model gemini-3.8-flash-medium --add-dir "$repo" --output-format json \
      --dangerously-skip-permissions > "out-$mod.json" &
done
wait
```

Budget **10+ minutes** per file-reading worker and never wrap one in a short
`timeout` — a killed worker returns nothing and you have paid for it anyway.

## Resuming a worker

`conversation_id` from the JSON lets you continue one instead of re-paying the
startup cost:

```bash
agy -p "Now do the same for control/" --conversation <conversation_id> \
    --output-format json --dangerously-skip-permissions
```

`-c` / `--continue` resumes the most recent conversation.

## Helper

`scripts/agy-slave.sh` wraps all of the above: tier names instead of model ids,
automatic fallback when a tier is out of capacity, and `status` checking.

```bash
./scripts/agy-slave.sh supreme "Explain the retry logic in io/command_sender.py" ./repo
```

See `references/models.md` for the full live model list and `references/troubleshooting.md`
for every failure mode observed so far.
