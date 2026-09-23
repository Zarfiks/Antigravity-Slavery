# Antigravity Slavery

A [Claude Code](https://claude.com/claude-code) skill that uses the Antigravity
CLI (`agy`) as a pool of disposable subagent workers. Claude stays the
orchestrator; Gemini, Claude and GPT-OSS workers read the files, and only their
conclusions come back. Claude's context stays small.

```
Claude Code (orchestrator)
 ├── agy worker: gemini-high    ─┐
 ├── agy worker: gemini-medium  ─┤
 ├── agy worker: gemini-medium  ─┼─→ answers (text or JSON) ─→ Claude decides
 ├── agy worker: opus           ─┤
 └── shared memory file ←───────┘
```

## What you get

- **Six tiers** named after their models: `gemini-high`, `gemini-medium`,
  `gemini-low`, `opus`, `sonnet`, `gpt-oss`, each with automatic fallback when
  a model is out of capacity.
- **Safe by default.** Workers cannot run shell commands unless you allow it.
  A guard warns when a worker changes files it should only read.
- **Worktree isolation.** `-w` runs an editing worker in a throwaway
  `git worktree`; you review the diff before anything touches your checkout.
- **Shared memory.** `-m notes.md` lets workers read what earlier workers found.
- **Fan-out.** `agy-fanout.sh` runs one worker per line of a tasks file, in
  parallel.
- **Structured output** with a JSON Schema, a run log with token costs, and
  resume by conversation id.
- **Guidance for Claude** on when delegation pays off and how many workers to
  start, based on measured costs (every call has ~12k tokens of overhead).

## Requirements

- Antigravity CLI `agy` on `PATH` (tested with v1.2.6 and v1.2.7), signed in.
- `bash` 3.2+, `git`, Python 3.
- Linux, macOS, WSL, or Windows with Git Bash.

## Install

```bash
git clone https://github.com/Zarfiks/Antigravity-Slavery.git
cd Antigravity-Slavery
./install.sh              # copy to ~/.claude/skills/antigravity-slavery
# ./install.sh --link     # symlink instead, for development
# ./install.sh --project  # into ./.claude/skills of the current project
```

Restart Claude Code. The skill loads on its own when delegation fits, or on
request: `/antigravity-slavery`, "use agy", "use subagents".

## Use without Claude

```bash
# one worker, read-only
scripts/agy-slave.sh gemini-medium "Explain the retry logic in src/net/client.py" ./repo

# a second opinion from another model family
scripts/agy-slave.sh opus "Is the locking in src/cache.py correct?" ./repo

# an edit in an isolated worktree
scripts/agy-slave.sh -w gemini-high "Add input validation to parse_config()" ./repo

# structured answer
scripts/agy-slave.sh -s examples/verdict.schema.json gemini-low "Does src/ use eval()?" ./repo

# many workers with shared memory
scripts/agy-fanout.sh -j 3 -m .agy-memory.md gemini-medium ./repo examples/tasks.txt
```

Run `scripts/agy-slave.sh -h` for all options.

| Option | Effect |
|---|---|
| `-s FILE` | JSON Schema; prints `structured_output` |
| `-f` | allow shell commands (`--dangerously-skip-permissions`) |
| `-w` | run in a throwaway git worktree (implies `-f`) |
| `-m FILE` | shared memory file (also `AGY_MEMORY`) |
| `-c ID` | resume a worker by conversation id |
| `-t SEC` | hard timeout |
| `-q` | no cost line |

| Environment | Effect |
|---|---|
| `AGY_CHAIN_<TIER>` | override a tier's model chain, e.g. `AGY_CHAIN_GEMINI_HIGH="gemini-3.9-flash-high"` |
| `AGY_MEMORY` | default memory file |
| `AGY_MEMORY_TAIL` / `AGY_MEMORY_MAX_LINES` | lines read from / written to memory (200 / 40) |
| `AGY_WORKTREE_DIR` | where worktrees go (default `$TMPDIR/agy-worktrees`) |

## Security notes

- `agy` has **no enforced read-only mode**. In the default mode workers cannot
  run shell commands but can still edit files in the folder you give them.
  Use `-w` for anything that edits code, and read the diff before applying.
- `-f` and `-w` pass `--dangerously-skip-permissions`. With `-w` the worker's
  folder is a disposable worktree, but a shell command can still reach
  anything your user can. Do not use `-f` on untrusted repositories.
- Prompts and file contents go to the model provider behind Antigravity.
  Do not hand workers secrets.

## Limitations

- Workers do not talk to each other; shared memory is a file, not a message bus.
- Each call has about 12 000 tokens and several seconds of overhead. Small jobs
  are faster done directly.
- Model ids are hard-coded as defaults and will go stale. Override with
  `AGY_CHAIN_<TIER>` or pass a model id.

## Layout

```
SKILL.md                       the skill (instructions for Claude)
scripts/agy-slave.sh           one worker: tiers, fallback, memory, worktree, guard
scripts/agy-fanout.sh          many workers in parallel from a tasks file
references/models.md           models, tiers, overrides, agy flags
references/troubleshooting.md  every failure mode observed, with the fix
examples/                      JSON Schema and tasks file
install.sh                     installer
```

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Google, Anthropic or OpenAI. "Antigravity", "Gemini",
"Claude" and "GPT" are trademarks of their owners.
