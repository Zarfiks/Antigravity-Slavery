# Changelog

## 1.2.0 — 2026-09-23

- Dynamic model discovery: `scripts/agy-models.sh` maps capability tiers to
  the live `agy models` list (cached 24 h), newest version first. Hard-coded
  chains are only a fallback.
- Verification gate: `-v` can repeat (lint, typecheck, tests, build); runs in
  order, stops at the first failure, one log per snapshot.
- Contracts: bundled schemas `findings`, `list`, `verdict` in `schemas/`,
  usable by name (`-s findings`).
- New `scripts/agy-consensus.sh`: same question to two model families,
  findings matched by file and lines into `agreed` / `single`.
- Retries: when every model of a tier is busy (503), the chain is retried
  after 30 s, 60 s, ... (`-r N`, default 1). Account / region errors stop the
  chain at once with a clear message.
- Quota errors (429 `Individual quota reached`) stop the chain at once and show
  when the quota resets, instead of walking every fallback model.
- `findings` schema verified against the real `agy` (enum and integer fields
  accepted).
- New `scripts/agy.ps1`: PowerShell entry point that finds Git Bash.
- Snapshot creation retries on git's worktree lock; read snapshots are always
  cleaned up, even when creation fails half-way.
- `SKILL.md`: job pipeline, delegation table by file count, contracts,
  consensus, scheduler notes.

## 1.1.0 — 2026-09-23

Safe parallel work: a worker never touches the files you are editing.

- Every worker runs in its own snapshot (`git worktree` with your uncommitted
  and untracked files). Read snapshots are thrown away; write snapshots wait
  for review. `--in-place` keeps the old behaviour for huge repos.
- `-w` is now `--write` (`--worktree` still works). Snapshots include
  uncommitted changes instead of only `HEAD`.
- `-o/--owns PATHS`: file ownership for write workers; `[violation]` on edits
  outside it.
- `-v/--verify "CMD"`: run tests / typecheck / build in the snapshot.
- `[overlap]` report when you changed the same file since the snapshot.
- New `scripts/agy-merge.sh`: three-way merge back into your checkout
  (`git merge-file`), `--check`, `--discard`, `--list`. Never commits.
- `agy-fanout.sh`: `[owns=...]` per task, refuses duplicate owners, reports
  files changed by more than one worker as `CONFLICT`.
- Exit code 3: worker finished, but verify failed or it left `--owns`.

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
- MIT license, installer (`--codex` for OpenAI Codex), examples.

## 0.1.0 — 2026-09-18

Initial personal version.
