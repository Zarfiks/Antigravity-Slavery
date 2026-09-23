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

A skill: one `SKILL.md` file plus two small scripts. It teaches your AI coding
agent (Claude Code or Codex) to pass work to the
[Antigravity CLI](https://antigravity.google) (`agy`).

Your agent becomes the **boss**. `agy` workers are the **helpers**. A helper
reads the files, does the job and returns a short answer. The boss never loads
those files, so its context stays small and it keeps working on your task.

```
You ──► Claude Code / Codex  (boss)
            ├── agy helper: Gemini high   ─┐
            ├── agy helper: Gemini medium ─┼──► short answers ──► boss decides
            ├── agy helper: Claude Opus   ─┘
            └── shared notes file (helpers read what others found)
```

**Good for:** reading a big log, checking the same thing in ten modules,
a second opinion from another model, simple edits in a safe copy of the repo.

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

If a model is busy, the next one of the same level is used automatically.

## Run by hand (optional)

```bash
# ask one helper
scripts/agy-slave.sh gemini-medium "Explain src/net/client.py" ./repo

# let a helper edit code in a safe copy (git worktree)
scripts/agy-slave.sh -w gemini-high "Fix the bug in calc.py" ./repo

# many helpers at once, one task per line, with shared notes
scripts/agy-fanout.sh -j 3 -m notes.md gemini-medium ./repo examples/tasks.txt
```

| Flag | What it does |
|---|---|
| `-w` | work in a safe copy of the repo; you get a diff to apply |
| `-m FILE` | shared notes between helpers |
| `-s FILE` | answer as JSON by this schema |
| `-f` | allow shell commands (use with care) |
| `-c ID` | continue an earlier helper |
| `-t SEC` | time limit |

All options: `scripts/agy-slave.sh -h`. Details and fixes:
[`references/`](references/).

## Safety

- By default helpers **cannot run shell commands**.
- Helpers can still edit files. If one changes something it should only read,
  you get a warning. For real edits use `-w`: your checkout is not touched.
- `-f` and `-w` give full access. Do not use `-f` on code you do not trust.
- Your prompts and files go to the model provider. Do not give helpers secrets.

## License

[MIT](LICENSE) © [Zarfiks](https://github.com/Zarfiks)

Not affiliated with Google, Anthropic or OpenAI. All names are trademarks of
their owners.
