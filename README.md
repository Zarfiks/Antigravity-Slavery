<div align="center">

# Antigravity Slavery

*Turn Claude Code or Codex into an orchestrator — hand heavy jobs to Antigravity sub-agents and keep only the answers.*

<p>
  <a href="https://claude.com/claude-code"><img src="https://img.shields.io/badge/Claude_Code-orchestrator-D97757?style=for-the-badge&logo=claude&logoColor=white&labelColor=555" alt="Claude Code orchestrator"></a>
  <a href="https://github.com/openai/codex"><img src="https://img.shields.io/badge/Codex-orchestrator-10A37F?style=for-the-badge&logo=openai&logoColor=white&labelColor=555" alt="Codex orchestrator"></a>
  <a href="https://antigravity.google"><img src="https://img.shields.io/badge/Antigravity_CLI-agy-4285F4?style=for-the-badge&logo=google&logoColor=white&labelColor=555" alt="Antigravity CLI agy"></a>
</p>
<p>
  <img src="https://img.shields.io/badge/workers-Gemini_%7C_Claude_%7C_GPT--OSS-8E75B2?style=for-the-badge&logo=googlegemini&logoColor=white&labelColor=555" alt="Workers: Gemini, Claude, GPT-OSS">
  <img src="https://img.shields.io/badge/skill-SKILL.md-333?style=for-the-badge&labelColor=555" alt="Skill">
  <img src="https://img.shields.io/badge/Windows_%7C_macOS_%7C_Linux-ready-222?style=for-the-badge&labelColor=555" alt="Windows, macOS, Linux">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3FB950?style=for-the-badge&labelColor=555" alt="MIT license"></a>
</p>

**Created by [Zarfiks](https://github.com/Zarfiks)**

</div>

---

## What is it

A skill: one `SKILL.md` file plus a few small scripts. It teaches your AI coding
agent (Claude Code or Codex) to pass work to the
[Antigravity CLI](https://antigravity.google) (`agy`).

Your agent becomes the **boss**. `agy` workers are the **helpers**. A helper
reads the files, does the job and returns a short answer. The boss never loads
those files, so its context stays small and it keeps working on your task.

```
your repo ── Claude Code / Codex (boss) keeps coding here
   │
   ├── copy 1 ── agy helper: review          ─┐
   ├── copy 2 ── agy helper: security check  ─┼──► short answers ──► boss decides
   └── copy 3 ── agy helper: fix src/billing ─┘──► diff ──► boss checks, merges
```

Every helper works in **its own copy** of the repo, so helpers never edit the
files the boss is editing.

**Good for:** reading a big log, checking the same thing in ten modules,
review and security passes while the boss codes, a second opinion from another
model, small independent fixes.

**Not for:** small jobs. Every helper costs about 12 000 tokens and a few
seconds. Two `grep`s are faster.

## Install

You need: the [Antigravity CLI](https://antigravity.google) (`agy`) signed in,
`git`, Python 3, and bash (on Windows, Git Bash).

```bash
git clone https://github.com/Zarfiks/Antigravity-Slavery.git
cd Antigravity-Slavery
./install.sh            # Claude Code
./install.sh --codex    # Codex
```

Restart your agent. Done.

## Use it

Just ask your agent:

> "Use agy helpers to find every place we read config in this repo."
>
> "Get a second opinion from opus on this function."
>
> "Have an agy helper fix this bug in a worktree."

The agent picks the model and the number of helpers by itself.

## Models

| Name | Model | For |
|---|---|---|
| `gemini-high`   | Gemini 3.8 Flash High   | hard questions |
| `gemini-medium` | Gemini 3.8 Flash Medium | normal work |
| `gemini-low`    | Gemini 3.8 Flash Low    | simple, clear tasks |
| `opus`          | Claude Opus 4.6         | second opinion |
| `sonnet`        | Claude Sonnet 4.6       | cheaper second opinion, text |
| `gpt-oss`       | GPT-OSS 120B            | quick yes/no checks |

The names are fixed; the models behind them are found automatically from
`agy models`, newest first. If a model is busy, the next one is used.

## Run by hand (optional)

```bash
# ask one helper
scripts/agy-slave.sh gemini-medium "Explain src/net/client.py" ./repo

# let a helper edit code: only src/billing/, then run the tests
scripts/agy-slave.sh -w -o src/billing/ -v "npm test" gemini-high "Fix the rounding bug" ./repo
scripts/agy-merge.sh /tmp/agy-worktrees/repo-...   # path is printed; brings the change back

# a queue of helpers: one task per line, at most 3 at once, 1 of them writing
scripts/agy-fanout.sh -j 3 --max-write 1 -m notes.md gemini-medium ./repo examples/tasks.txt
```

```bash
# two model families review the same code; you get what they agree on
scripts/agy-consensus.sh "Review src/auth/ for security bugs" ./repo

# which model is behind each name right now; what the helpers cost so far
scripts/agy-models.sh
scripts/agy-cost.sh --since 2026-09-23
```

Put your project's checks in `.agy-verify` (one command per line, e.g.
`npm run lint`, `npx tsc --noEmit`, `npm test`) and every editing helper is
checked with them automatically.

On Windows PowerShell: `scripts\agy.ps1 slave gemini-medium "..." C:\code\repo`
(also `fanout`, `consensus`, `merge`, `models`, `cost`).

| Flag | What it does |
|---|---|
| `-w` | helper may edit; its changes wait in a snapshot for `agy-merge.sh` |
| `-o PATHS` | files the helper may change, e.g. `src/auth/,docs/auth.md` |
| `-v "CMD"` | a check after the helper (repeat: lint, typecheck, tests, build) |
| `-s NAME` | answer as JSON: `findings`, `list`, `verdict` or your schema file |
| `-m FILE` | shared notes between helpers |
| `-f` | allow shell commands (use with care) |
| `-c ID` | continue an earlier helper |
| `-t SEC` | time limit |

All options: `scripts/agy-slave.sh -h`. Details and fixes:
[`references/`](references/).

## Safety

- **Helpers never work in your folder.** Each one gets its own copy of the
  repo (a `git worktree` with your uncommitted files too). You and five
  helpers can work at the same time without stepping on each other.
- Read helpers' copies are thrown away. Write helpers' changes come back only
  when you run `agy-merge.sh` — after you looked at the diff.
- Each write helper owns its files (`-o`). Two helpers on the same file are
  refused up front, or flagged as `CONFLICT` after a fan-out.
- `agy-merge.sh` merges line by line if you changed the same file meanwhile;
  real clashes get conflict markers. Nothing is committed for you.
- By default helpers **cannot run shell commands**. `-w` and `-f` allow it.
  Do not use `-f` on code you do not trust.
- Your prompts and files go to the model provider. Do not give helpers secrets.

## License

[MIT](LICENSE) © [Zarfiks](https://github.com/Zarfiks)

Not affiliated with Google, Anthropic or OpenAI. All names are trademarks of
their owners.
