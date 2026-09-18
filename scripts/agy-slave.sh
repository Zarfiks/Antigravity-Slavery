#!/usr/bin/env bash
# agy-slave.sh — run one Antigravity worker by tier name, with fallback.
#
#   ./agy-slave.sh <tier> "<prompt>" [workdir] [schema.json]
#
# Tiers: supreme | smart | basic | claudeman | mini-claudeman | dumbest
#
# Prints the worker's answer on stdout and a one-line cost report on stderr.
# Exits 1 if every model in the fallback chain failed.

set -uo pipefail

tier="${1:-}"; prompt="${2:-}"; workdir="${3:-.}"; schema="${4:-}"

if [ -z "$tier" ] || [ -z "$prompt" ]; then
    sed -n '2,12p' "$0" >&2
    exit 2
fi

# Each tier lists its model first, then same-quality fallbacks for when the
# server answers 503 "No capacity available".
case "$tier" in
    supreme)        chain="gemini-3.8-flash-high gemini-3.7-flash-high gemini-3.1-pro-high" ;;
    smart)          chain="gemini-3.8-flash-medium gemini-3.7-flash-medium gemini-3.6-flash-medium" ;;
    basic)          chain="gemini-3.8-flash-low gemini-3.7-flash-low gemini-3.6-flash-low" ;;
    claudeman)      chain="claude-opus-4-6-thinking claude-sonnet-4-6" ;;
    mini-claudeman) chain="claude-sonnet-4-6 claude-opus-4-6-thinking" ;;
    dumbest)        chain="gpt-oss-120b-medium gemini-3.6-flash-low" ;;
    *) echo "unknown tier: $tier" >&2; exit 2 ;;
esac

if [ ! -d "$workdir" ]; then
    echo "workdir does not exist: $workdir" >&2
    exit 2
fi

# agy IGNORES the shell's current directory — it always runs in its own
# scratch dir (~/.gemini/antigravity-cli/scratch). The only way to hand a
# worker your files is --add-dir with an ABSOLUTE WINDOWS path. Without it
# the worker hunts the whole disk for the filenames you mentioned, which is
# how a job either takes minutes or silently analyses the wrong repository.
if command -v cygpath >/dev/null 2>&1; then
    winpath="$(cygpath -w "$(cd "$workdir" && pwd)")"
else
    winpath="$(cd "$workdir" && pwd)"
fi

for model in $chain; do
    args=(-p "$prompt" --model "$model" --add-dir "$winpath"
          --output-format json --dangerously-skip-permissions)
    [ -n "$schema" ] && args+=(--json-schema "$schema")

    raw="$( agy "${args[@]}" 2>/dev/null )"

    # agy exits 0 even when the run failed, so the status field is the only
    # trustworthy signal.
    verdict="$(printf '%s' "$raw" | python -c '
import json, sys
raw = sys.stdin.read()
line = ""
for candidate in raw.splitlines():          # the JSON result is the last line
    if candidate.strip().startswith("{"):
        line = candidate
if not line:
    print("FAIL\tno JSON returned (worker produced nothing)")
    sys.exit()
try:
    d = json.loads(line)
except ValueError:
    print("FAIL\tunparseable JSON")
    sys.exit()
if d.get("status") != "SUCCESS":
    print("FAIL\t" + str(d.get("error", "status=" + str(d.get("status")))))
    sys.exit()
body = d.get("structured_output")
body = json.dumps(body, ensure_ascii=False, indent=2) if body is not None else d.get("response", "")
u = d.get("usage", {})
print("OK\t%s\t%s\t%s" % (u.get("total_tokens", "?"), round(d.get("duration_seconds", 0)), d.get("conversation_id", "")))
print(body)
' )"

    head="$(printf '%s' "$verdict" | head -1)"
    if [ "${head%%	*}" = "OK" ]; then
        IFS=$'\t' read -r _ tokens secs convo <<< "$head"
        printf '%s\n' "$verdict" | tail -n +2
        echo "[$tier/$model] ${tokens} tokens, ${secs}s, conversation=${convo}" >&2
        exit 0
    fi

    echo "[$tier/$model] failed: ${head#*	}" >&2
done

echo "[$tier] every model in the chain failed" >&2
exit 1
