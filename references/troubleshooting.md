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

**Fix.** Say "Do not modify any file" in the prompt. `agy-slave.sh` compares
`git status` and the diff before and after, and prints
`[warning] the worker modified files in <dir>`. For jobs that should change
code, use `-w` so the edits land in a throwaway worktree.

## `--worktree` result is missing my latest changes

The worktree is created from `HEAD`. Uncommitted changes in your checkout are
not in it. Commit first, or accept that the worker sees the last commit.

## Leftover worktrees

A failed run leaves its worktree in place and prints its path. List and clean:

```bash
git worktree list
git worktree remove --force <path>
git worktree prune
```

## `invalid model selection`

You passed `--effort` together with `--model`. Drop `--effort`. See
`references/models.md`.

## Unknown model

The model list rotated. Run `agy models`, then override the tier chain with
`AGY_CHAIN_<TIER>="..."` or pass the model id directly.

## Answer is prose when you wanted fields

Pass `-s schema.json` (script) or `--json-schema schema.json` (by hand) and read
`structured_output`, not `response`. Example schema:
`examples/verdict.schema.json`.

## `python3 is required`

The script parses JSON with Python 3. On Windows, `python3` may be the Microsoft
Store stub; the script falls back to `python`. Install Python 3 if neither works.
