# Failure modes

Every entry here was observed on this machine, not inferred.

## The worker answers about the wrong files

**Symptom.** The answer is plausible and cites real code, but the file paths
belong to a different project than the one you are working in.

**Cause.** `agy` ignores the shell's current directory. A worker launched from
a repo checkout, asked to report its own working directory, answered
`C:\Users\rdor\.gemini\antigravity-cli\scratch`. Told to read
`carpilot/vision/line_tracker.py`, it could not find that path, searched the
disk, and read an entirely different checkout on the Desktop instead.

**Fix.** Always `--add-dir <absolute Windows path>`. From Git Bash:
`--add-dir "$(cygpath -w "$PWD")"`.

## The job returns nothing after many minutes

**Symptom.** Empty output, no error, non-zero wall clock burned.

**Causes, in order of likelihood.**
1. No `--add-dir`, so the worker is searching the filesystem. One file took
   168 s and 93 492 tokens this way; a two-file version was killed at 420 s
   having produced nothing.
2. The job was wrapped in `timeout`. A killed worker returns nothing and the
   tokens are still spent.

**Fix.** Add `--add-dir`, run the call in the background, and budget 10+ minutes
for anything that reads files.

## `status: ERROR` but exit code 0

**Symptom.** Your script thinks the call succeeded and parses an empty response.

**Example.**
```json
{"status":"ERROR","response":"",
 "error":"Our servers are experiencing high traffic right now ...
          (UNAVAILABLE (code 503): No capacity available for model
          gpt-oss-120b-medium on the server)",
 "usage":{"total_tokens":0}}
```

**Fix.** Never trust the exit code. Parse the JSON and require
`status == "SUCCESS"`. On a capacity error, retry the next model in the tier's
fallback chain — `scripts/agy-slave.sh` does this automatically.

## `invalid model selection`

You passed `--effort` alongside `--model`. See `references/models.md`. Drop
`--effort`.

## The call hangs forever with no output at all

You forgot `--dangerously-skip-permissions`. The worker hit a permission prompt
and is waiting for an answer that will never come in print mode.

## Response is prose when you wanted fields

Pass `--json-schema <file>` and read the `structured_output` field of the JSON
result rather than scraping `response`. Confirmed working:

```json
"structured_output":{"reason":"17 is a prime number...","verdict":"yes"}
```
