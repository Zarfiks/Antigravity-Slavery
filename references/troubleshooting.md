# Failure modes

Every entry was observed with a real `agy` run (Windows, v1.2.6–1.2.7), not
inferred.

## The worker answers about the wrong files

**Symptom.** The answer is plausible and cites real code, but the file paths
belong to a different project than the one you are working in.

**Cause.** `agy` ignores the shell's current directory. A worker launched from
a repo checkout, asked for its working directory, answered with its own scratch
folder (`~/.gemini/antigravity-cli/scratch`). Asked to read a file by relative
path, it could not find it, searched the disk, and read another checkout of the
same project somewhere else.

**Fix.** Always `--add-dir <absolute path>`. The scripts do this. By hand from
Git Bash: `--add-dir "$(cygpath -w "$PWD")"`; from WSL with the Windows
`agy.exe`: `--add-dir "$(wslpath -w "$PWD")"`; on Linux/macOS: `--add-dir "$PWD"`.

## The job returns nothing after many minutes

**Causes, most likely first.**
1. No `--add-dir`, so the worker searches the filesystem. One file took 168 s
   and 93 492 tokens this way; a two-file job was killed at 420 s with nothing.
2. A short `timeout` or `-t`. A killed worker returns nothing and the tokens
   are still spent.

**Fix.** Add `--add-dir`, run the call in the background, and budget 10+ minutes
for anything that reads many files.

## `status: ERROR` but exit code 0

```json
{"status":"ERROR","response":"",
 "error":"Our servers are experiencing high traffic right now ...
          (UNAVAILABLE (code 503): No capacity available for model
          gpt-oss-120b-medium on the server)",
 "usage":{"total_tokens":0}}
```

**Fix.** Never trust the exit code. Require `status == "SUCCESS"`. On a capacity
error, retry the next model of the same strength. `agy-slave.sh` does this.

## Empty answer, `status: SUCCESS`, `denied_actions` present

```
jetski: no output produced — a tool required the "command" permission that
headless mode cannot prompt for, so it was auto-denied.
{"status":"SUCCESS","response":"", ... "denied_actions":[{"action":"command","display_name":"RunCommand"}]}
```

**Cause.** Without `--dangerously-skip-permissions` the worker may not run
shell commands. In v1.2.6 this made the call hang; in v1.2.7 the command is
denied at once and the run ends with an empty answer. Models try the shell out
of habit — even "Is 17 prime?" made one reach for a command.

**Fix.** `agy-slave.sh` appends a note to every default-mode prompt saying the
shell is disabled, which prevents most of these. If it still happens, the
script reports `failed: empty answer (denied: command; retry with --full?)` and
does not retry other models, because they would be denied too. Rephrase, or if
the job really needs the shell use `-w` (worktree) or, with the user's consent,
`-f`.

## A "read-only" worker changed files

**Cause.** `agy` has no enforced read-only mode. File-edit tools work without
`--dangerously-skip-permissions`, and `--mode plan` does not stop them.

**Fix.** Already handled: in a git repo every worker runs in its own snapshot,
and a read worker's snapshot is thrown away. The script reports
`[note] the worker edited N file(s) in its private snapshot; discarded`.
Only `--in-place` or a non-git folder exposes your files; there the script
compares `git status` before and after and prints a warning.

## Two workers (or you and a worker) changed the same file

**Prevention.** Give each write worker its own paths with `-o`. `agy-fanout.sh`
refuses a tasks file where two `[owns=...]` entries claim the same path.

**Detection.** `agy-slave.sh -w` prints `[overlap]` for files you changed in
your checkout since the snapshot. `agy-fanout.sh` prints `CONFLICT` for files
changed by more than one worker.

**Resolution.** `agy-merge.sh` merges each file three-way (snapshot, yours,
the worker's) with `git merge-file`. Separate edits merge cleanly; edits to the
same lines get `<<<<<<< yours` / `>>>>>>> agy` markers and exit code 1. For a
fan-out conflict: merge one snapshot, discard the other, re-run that task.

## `[violation] <file> is outside --owns`

The worker edited a file it was not given. Exit code 3. Check the diff; merge
anyway only if the extra edit is wanted, otherwise `agy-merge.sh --discard`.

## `[verify] FAIL`

The `-v` command failed inside the snapshot. Exit code 3. The log path is
printed (`<snapshot>.verify.log`). Resume the worker with `-c <id>` and the
error, or discard.

## Leftover snapshots

Write snapshots stay until you merge or discard them. List and clean:

```bash
scripts/agy-merge.sh --list
scripts/agy-merge.sh --discard <snapshot>
git worktree prune
```

## Snapshots are slow on a huge repo

Every worker gets a `git worktree` plus a copy of untracked files. On very large
repos use `--in-place` for read jobs, and only while nobody edits that folder.

## `Eligibility check failed ... not available in your location`

An account or region problem, not a model problem: every model fails the same
way. The script stops the chain and prints `account/region problem`. Check
that `agy` is signed in, and your VPN or network if Antigravity is not offered
where you are.

## `invalid model selection`

You passed `--effort` together with `--model`. Drop `--effort`. See
`references/models.md`.

## Unknown model

The model list rotated and the cache is stale. Run
`scripts/agy-models.sh --refresh`. If a tier still shows `(no model found)`,
override it with `AGY_CHAIN_<TIER>="..."` or pass a model id directly.

## Answer is prose when you wanted fields

Pass `-s schema.json` (script) or `--json-schema schema.json` (by hand) and read
`structured_output`, not `response`. Example schema:
`schemas/` (`-s findings`, `-s list`, `-s verdict`).

## `python3 is required`

The script parses JSON with Python 3. On Windows, `python3` may be the Microsoft
Store stub; the script falls back to `python`. Install Python 3 if neither works.
