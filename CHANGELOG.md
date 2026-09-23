# Changelog

## 1.0.0 — 2026-09-23

First public release.

- Tier names are now the model names: `gemini-high`, `gemini-medium`,
  `gemini-low`, `opus`, `sonnet`, `gpt-oss`. The old names (`supreme`,
  `smart`, `basic`, `claudeman`, `mini-claudeman`, `dumbest`) still work.
- Works on Linux, macOS, WSL and Windows (Git Bash). No hard-coded user paths.
- Default mode no longer passes `--dangerously-skip-permissions`: workers cannot
  run shell commands unless you pass `-f`/`--full` or `-w`/`--worktree`. The
  prompt tells the worker so, which avoids empty answers.
- New `-w`/`--worktree`: editing workers run in a throwaway `git worktree`;
  your checkout is untouched; diffstat and apply command are printed.
- Guard: warns when a worker that should only read modified files.
- New shared memory: `-m FILE` / `AGY_MEMORY` gives workers a common notebook.
- Every call logged to `~/.local/state/agy-slave/runs.jsonl`.
- New `scripts/agy-fanout.sh`: parallel workers from a tasks file.
- New options: `-c` resume, `-t` timeout, `-q` quiet; raw model ids accepted;
  `AGY_CHAIN_<TIER>` overrides a model chain.
- Permission denials are reported clearly and do not burn the fallback chain.
- `SKILL.md`: guidance on how many workers to launch; access-level table.
- MIT license, installer, examples.

## 0.1.0 — 2026-09-18

Initial personal version.
