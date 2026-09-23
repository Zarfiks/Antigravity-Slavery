#!/usr/bin/env bash
# agy-slave.sh — run one Antigravity (`agy`) worker by tier name, with fallback.
#
#   agy-slave.sh [options] <tier|model-id> "<prompt>" [workdir]
#
# Tiers (best to cheapest):
#   gemini-high  gemini-medium  gemini-low  opus  sonnet  gpt-oss
#   Any raw model id from `agy models` also works (no fallback chain).
#
# Options:
#   -s, --schema FILE        JSON Schema; prints the parsed structured_output
#   -f, --full               allow shell commands (--dangerously-skip-permissions)
#   -w, --worktree           run in a throwaway git worktree of <workdir> (HEAD),
#                            print its path and diffstat; your checkout is untouched.
#                            Implies --full: editing workers need shell access
#   -m, --memory FILE        shared memory: prepend FILE to the prompt, append the
#                            answer to it afterwards (default: $AGY_MEMORY if set)
#   -c, --conversation ID    resume an earlier worker instead of starting fresh
#   -t, --timeout SECONDS    hard limit (agy --print-timeout). Default 0 = none
#   -q, --quiet              no cost line on stderr
#   -h, --help
#
# Prints the answer on stdout, a one-line cost report on stderr.
# Exit codes: 0 ok, 1 every model in the chain failed, 2 usage error.

set -uo pipefail

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

schema=""; full=0; worktree=0; memory="${AGY_MEMORY:-}"; convo_in=""
timeout=0; quiet=0; pos=()

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--schema)       schema="${2:?}"; shift 2 ;;
        -f|--full)         full=1; shift ;;
        -w|--worktree)     worktree=1; shift ;;
        -m|--memory)       memory="${2:?}"; shift 2 ;;
        -c|--conversation) convo_in="${2:?}"; shift 2 ;;
        -t|--timeout)      timeout="${2:?}"; shift 2 ;;
        -q|--quiet)        quiet=1; shift ;;
        -h|--help)         usage ;;
        --)                shift; pos+=("$@"); break ;;
        -*)                echo "unknown option: $1" >&2; usage ;;
        *)                 pos+=("$1"); shift ;;
    esac
done

tier="${pos[0]:-}"; prompt="${pos[1]:-}"; workdir="${pos[2]:-.}"
{ [ -z "$tier" ] || [ -z "$prompt" ]; } && usage

command -v agy >/dev/null 2>&1 || { echo "agy not found on PATH" >&2; exit 2; }
[ -d "$workdir" ] || { echo "workdir does not exist: $workdir" >&2; exit 2; }
[ -z "$schema" ] || [ -f "$schema" ] || { echo "schema not found: $schema" >&2; exit 2; }

# Python does the JSON work; accept whichever interpreter actually runs
# (on Windows `python3` may be a Store stub that prints an ad and exits).
PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 2; }

# ---- tier -> model chain -------------------------------------------------
# First model is the tier's own; the rest are same-quality fallbacks for the
# 503 "No capacity available" case. Override any chain without editing this
# file: AGY_CHAIN_GEMINI_HIGH="model-a model-b" etc.
case "$tier" in              # names from v0.1 keep working
    supreme)        tier=gemini-high ;;
    smart)          tier=gemini-medium ;;
    basic)          tier=gemini-low ;;
    claudeman)      tier=opus ;;
    mini-claudeman) tier=sonnet ;;
    dumbest)        tier=gpt-oss ;;
esac

case "$tier" in
    gemini-high)   chain="gemini-3.8-flash-high gemini-3.7-flash-high gemini-3.1-pro-high" ;;
    gemini-medium) chain="gemini-3.8-flash-medium gemini-3.7-flash-medium gemini-3.6-flash-medium" ;;
    gemini-low)    chain="gemini-3.8-flash-low gemini-3.7-flash-low gemini-3.6-flash-low" ;;
    opus)          chain="claude-opus-4-6-thinking claude-sonnet-4-6" ;;
    sonnet)        chain="claude-sonnet-4-6 claude-opus-4-6-thinking" ;;
    gpt-oss)       chain="gpt-oss-120b-medium gemini-3.6-flash-low" ;;
    *)             chain="$tier" ;;   # treat as a raw model id
esac
override_var="AGY_CHAIN_$(printf '%s' "$tier" | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_')"
chain="${!override_var:-$chain}"

# ---- paths ---------------------------------------------------------------
# agy IGNORES the shell's current directory: it always runs in its own scratch
# dir. The only way to hand a worker your files is --add-dir with an absolute
# path in the form agy itself understands (a Windows path for agy.exe).
# Without it the worker hunts the disk for the file names you mentioned — slow,
# and it may confidently analyse a different copy of the repository.
native_path() {
    local p; p="$(cd "$1" && pwd)"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p"                                   # Git Bash / MSYS / Cygwin
    elif grep -qi microsoft /proc/version 2>/dev/null \
         && [[ "$(command -v agy)" == *.exe || "$(command -v agy)" == /mnt/* ]]; then
        wslpath -w "$p"                                   # WSL calling the Windows agy.exe
    else
        printf '%s\n' "$p"                                # Linux / macOS
    fi
}

is_git() { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

rundir="$workdir"
if [ "$worktree" = 1 ]; then
    full=1
    is_git "$workdir" || { echo "--worktree needs <workdir> inside a git repository" >&2; exit 2; }
    root="$(git -C "$workdir" rev-parse --show-toplevel)"
    base="${AGY_WORKTREE_DIR:-${TMPDIR:-/tmp}/agy-worktrees}"
    mkdir -p "$base"
    wt="$base/$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$"
    git -C "$root" worktree add --detach --quiet "$wt" HEAD || exit 2
    # keep the same sub-directory the caller pointed at
    rel="$(git -C "$workdir" rev-parse --show-prefix)"
    rundir="$wt/$rel"
fi
winpath="$(native_path "$rundir")"

# Snapshot the checkout so we can tell the orchestrator if a worker that was
# only supposed to read went and changed files anyway. agy has no enforced
# read-only mode: without --full it cannot run shell commands, but its
# file-edit tools still work.
snapshot() { is_git "$1" && { git -C "$1" status --porcelain -uall; git -C "$1" diff HEAD 2>/dev/null | cksum; }; }
before=""; [ "$worktree" = 0 ] && before="$(snapshot "$workdir")"

# ---- memory --------------------------------------------------------------
full_prompt="$prompt"
if [ -n "$memory" ] && [ -s "$memory" ]; then
    notes="$(tail -n "${AGY_MEMORY_TAIL:-200}" "$memory")"
    full_prompt="Shared notes left by earlier workers on this job. They may be stale or wrong; verify anything you rely on.
-----
$notes
-----

Your task:
$prompt"
fi

# Without --full every shell command is auto-denied, and a worker that tries
# one anyway (models reach for ls/cat/python out of habit) ends with an empty
# answer. Telling it up front avoids most of those wasted runs.
if [ "$full" = 0 ]; then
    full_prompt="$full_prompt

(Shell commands are disabled in this session and will be denied. Use only your file viewing, search and editing tools.)"
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/agy-slave"
mkdir -p "$state_dir" 2>/dev/null || true

schema_arg=""
[ -n "$schema" ] && schema_arg="$(native_path "$(dirname "$schema")")/$(basename "$schema")"

# ---- run -----------------------------------------------------------------
for model in $chain; do
    args=(-p "$full_prompt" --model "$model" --add-dir "$winpath"
          --output-format json --print-timeout "${timeout}s")
    [ "$full" = 1 ]      && args+=(--dangerously-skip-permissions)
    [ -n "$schema_arg" ] && args+=(--json-schema "$schema_arg")
    [ -n "$convo_in" ]   && args+=(--conversation "$convo_in")

    raw="$( agy "${args[@]}" 2>/dev/null )"

    # agy exits 0 even when the run failed: the status field is the only
    # trustworthy signal. Parsing, memory append and the run log live here.
    verdict="$(RAW="$raw" TIER="$tier" MODEL="$model" PROMPT="$prompt" MEMORY="$memory" \
               WORKDIR="$winpath" STATE="$state_dir" MAXLINES="${AGY_MEMORY_MAX_LINES:-40}" \
               "$PY" - <<'PYEOF'
import json, os, sys, time
raw = os.environ["RAW"]
line = ""
for cand in raw.splitlines():            # the JSON result is the last {...} line
    if cand.strip().startswith("{"):
        line = cand
def out(s):
    sys.stdout.buffer.write((s + "\n").encode("utf-8"))
if not line:
    out("FAIL\tno JSON returned (worker produced nothing)"); sys.exit()
try:
    d = json.loads(line)
except ValueError:
    out("FAIL\tunparseable JSON"); sys.exit()

u = d.get("usage") or {}
log = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "tier": os.environ["TIER"],
       "model": os.environ["MODEL"], "workdir": os.environ["WORKDIR"],
       "status": d.get("status"), "conversation_id": d.get("conversation_id"),
       "tokens": u.get("total_tokens"), "seconds": d.get("duration_seconds"),
       "prompt": os.environ["PROMPT"][:200]}
try:
    with open(os.path.join(os.environ["STATE"], "runs.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(log, ensure_ascii=False) + "\n")
except OSError:
    pass

if d.get("status") != "SUCCESS":
    out("FAIL\t" + " ".join(str(d.get("error", "status=" + str(d.get("status")))).split())); sys.exit()

body = d.get("structured_output")
body = json.dumps(body, ensure_ascii=False, indent=2) if body is not None else (d.get("response") or "")
denied = ",".join(a.get("action", "?") for a in d.get("denied_actions") or [])
if not body.strip():
    out("FAIL\tempty answer" + (" (denied: %s; retry with --full?)" % denied if denied else "")); sys.exit()

mem = os.environ["MEMORY"]
if mem:
    lines = body.strip().splitlines()
    cap = int(os.environ["MAXLINES"])
    snippet = "\n".join(lines[:cap]) + ("\n[... %d more lines]" % (len(lines) - cap) if len(lines) > cap else "")
    head = " ".join(os.environ["PROMPT"].split())[:100]
    entry = "\n### %s  %s/%s  conv=%s\nTask: %s\n\n%s\n" % (
        log["ts"], log["tier"], log["model"], d.get("conversation_id", ""), head, snippet)
    with open(mem, "a", encoding="utf-8") as f:   # one write call: good enough for parallel workers
        f.write(entry)

out("OK\t%s\t%s\t%s\t%s" % (u.get("total_tokens", "?"), round(d.get("duration_seconds") or 0),
                            d.get("conversation_id", ""), denied))
out(body)
PYEOF
    )"

    head="$(printf '%s\n' "$verdict" | head -n 1)"
    if [ "${head%%	*}" = "OK" ]; then
        IFS=$'\t' read -r _ tokens secs convo denied <<< "$head"
        printf '%s\n' "$verdict" | tail -n +2

        if [ "$worktree" = 1 ]; then
            git -C "$wt" add -A >/dev/null 2>&1
            echo "[worktree] $wt" >&2
            git -C "$wt" diff --cached --stat HEAD >&2
            echo "[worktree] apply:  git -C \"$wt\" diff --cached HEAD | git apply" >&2
            echo "[worktree] remove: git worktree remove --force \"$wt\"" >&2
        elif [ -n "$before" ] && [ "$before" != "$(snapshot "$workdir")" ]; then
            echo "[warning] the worker modified files in $workdir — review: git -C \"$workdir\" status" >&2
        fi

        [ "$quiet" = 1 ] || echo "[$tier/$model] ${tokens} tokens, ${secs}s, conversation=${convo}${denied:+, denied=$denied}" >&2
        exit 0
    fi

    echo "[$tier/$model] failed: ${head#*	}" >&2
    # a permission denial is not a capacity problem: the next model hits it too
    case "$head" in *"denied:"*) break ;; esac
done

echo "[$tier] every model in the chain failed" >&2
[ "$worktree" = 1 ] && echo "[worktree] left at $wt (git worktree remove --force \"$wt\")" >&2
exit 1
