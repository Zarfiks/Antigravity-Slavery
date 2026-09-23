#!/usr/bin/env bash
# agy-slave.sh — run one Antigravity (`agy`) worker by tier name, with fallback.
#
#   agy-slave.sh [options] <tier|model-id> "<prompt>" [workdir]
#
# Tiers (best to cheapest):
#   gemini-high  gemini-medium  gemini-low  opus  sonnet  gpt-oss
#   Any raw model id from `agy models` also works (no fallback chain).
#
# Isolation (git repos): every worker gets its OWN snapshot — a git worktree
# holding your current files, uncommitted and untracked ones included. It never
# works in your checkout, so it can never collide with you or other workers.
#   read job (default)   snapshot is thrown away afterwards
#   -w, --write          snapshot is kept; you review and merge it with
#                        agy-merge.sh. Implies shell access (--full).
#
# Options:
#   -o, --owns PATHS         write jobs: comma-separated paths the worker may
#                            change (e.g. src/auth/,docs/api.md). Changes
#                            outside them are reported as violations
#   -v, --verify "CMD"       write jobs: a check to run in the snapshot afterwards.
#                            Repeat it for a gate, in order, stopping at the
#                            first failure: -v "npm run lint" -v "npx tsc" -v "npm test"
#                            Exit 3 if one fails
#   -s, --schema FILE|NAME   JSON Schema file, or a bundled one: findings,
#                            verdict, list. Prints the parsed structured_output
#   -r, --retries N          if every model is out of capacity, wait and retry
#                            the whole chain N more times (default 1)
#   -f, --full               allow shell commands (--dangerously-skip-permissions)
#   -m, --memory FILE        shared memory: prepend FILE to the prompt, append the
#                            answer to it afterwards (default: $AGY_MEMORY)
#   -c, --conversation ID    resume an earlier worker
#   -t, --timeout SECONDS    hard limit (agy --print-timeout). Default 0 = none
#   --in-place               read job directly in <workdir>, no snapshot
#                            (faster on huge repos; a guard warns on edits)
#   -k, --keep               keep a read job's snapshot for inspection
#   -q, --quiet              no cost line on stderr
#   -h, --help
#
# stdout: the answer. stderr: cost line, [changed]/[overlap]/[violation]/[verify]
# lines, and the merge command for write jobs.
# Exit: 0 ok, 1 every model failed, 2 usage error, 3 worker ok but verify failed
# or it changed files outside --owns.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,43p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

schema=""; full=0; write=0; memory="${AGY_MEMORY:-}"; convo_in=""; timeout=0
quiet=0; inplace=0; keep=0; owns=""; verify=(); retries=1; pos=()

while [ $# -gt 0 ]; do
    case "$1" in
        -w|--write|--worktree) write=1; shift ;;
        -o|--owns)         owns="${2:?}"; shift 2 ;;
        -v|--verify)       verify+=("${2:?}"); shift 2 ;;
        -r|--retries)      retries="${2:?}"; shift 2 ;;
        -s|--schema)       schema="${2:?}"; shift 2 ;;
        -f|--full)         full=1; shift ;;
        -m|--memory)       memory="${2:?}"; shift 2 ;;
        -c|--conversation) convo_in="${2:?}"; shift 2 ;;
        -t|--timeout)      timeout="${2:?}"; shift 2 ;;
        --in-place)        inplace=1; shift ;;
        -k|--keep)         keep=1; shift ;;
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
if [ -n "$schema" ] && [ ! -f "$schema" ]; then
    bundled="$here/../schemas/$schema.schema.json"
    [ -f "$bundled" ] || { echo "schema not found: $schema (bundled: findings, verdict, list)" >&2; exit 2; }
    schema="$bundled"
fi
[ "$write" = 1 ] && [ "$inplace" = 1 ] && { echo "--write and --in-place exclude each other" >&2; exit 2; }
{ [ -n "$owns" ] || [ ${#verify[@]} -gt 0 ]; } && [ "$write" = 0 ] && { echo "--owns/--verify need --write" >&2; exit 2; }

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

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/agy-slave"
mkdir -p "$state_dir" 2>/dev/null || true

# Tiers are capabilities, not model ids. The chain is built from the live
# `agy models` list (cached for a day), newest version first, so a renamed or
# new model does not break anything. The static chains below are used only if
# discovery fails. AGY_CHAIN_<TIER>="a b" always wins.
case "$tier" in
    gemini-high)   static="gemini-3.8-flash-high gemini-3.7-flash-high gemini-3.1-pro-high" ;;
    gemini-medium) static="gemini-3.8-flash-medium gemini-3.7-flash-medium gemini-3.6-flash-medium" ;;
    gemini-low)    static="gemini-3.8-flash-low gemini-3.7-flash-low gemini-3.6-flash-low" ;;
    opus)          static="claude-opus-4-6-thinking claude-sonnet-4-6" ;;
    sonnet)        static="claude-sonnet-4-6 claude-opus-4-6-thinking" ;;
    gpt-oss)       static="gpt-oss-120b-medium gemini-3.6-flash-low" ;;
    *)             static="" ;;
esac
override_var="AGY_CHAIN_$(printf '%s' "$tier" | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_')"
if [ -n "${!override_var:-}" ]; then
    chain="${!override_var}"
elif [ -z "$static" ]; then
    chain="$tier"                       # a raw model id
else
    chain="$("$here/agy-models.sh" --chain "$tier" 2>/dev/null)"
    [ -n "$chain" ] || chain="$static"
fi

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

# ---- snapshot ------------------------------------------------------------
# A worktree at a commit that holds the checkout exactly as it is now:
# `git stash create` captures tracked edits without touching your checkout,
# untracked (non-ignored) files are copied, and everything is committed
# inside the worktree so the worker's own changes diff cleanly against it.
wt=""; base_commit=""; root=""
make_snapshot() {
    root="$(git -C "$workdir" rev-parse --show-toplevel)"
    local wbase start name
    wbase="${AGY_WORKTREE_DIR:-${TMPDIR:-/tmp}/agy-worktrees}"
    mkdir -p "$wbase"
    name="$(basename "$root")-$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    wt="$wbase/$name"
    start="$(git -C "$root" stash create 2>/dev/null)"
    [ -n "$start" ] || start=HEAD
    # parallel workers may hit git's worktree lock at the same moment: retry
    local try
    for try in 1 2 3 4 5; do
        git -C "$root" worktree add --detach --quiet "$wt" "$start" 2>/dev/null && break
        [ "$try" = 5 ] && { echo "git worktree add failed for $wt" >&2; exit 2; }
        sleep "$try"
    done
    (cd "$root" && git ls-files -z --others --exclude-standard) |
        while IFS= read -r -d '' f; do
            mkdir -p "$wt/$(dirname "$f")" && cp -p "$root/$f" "$wt/$f"
        done
    git -C "$wt" add -A 2>/dev/null
    git -C "$wt" -c user.name=agy-slave -c user.email=agy-slave@localhost \
        commit -q --no-verify --allow-empty -m "agy snapshot of $root"
    base_commit="$(git -C "$wt" rev-parse HEAD)"
    printf 'ROOT=%s\nBASE=%s\nWT=%s\nTIER=%s\nOWNS=%s\n' \
        "$root" "$base_commit" "$wt" "$tier" "$owns" > "$wt.meta"
}
drop_snapshot() {
    [ -n "$wt" ] || return 0
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    rm -f "$wt.meta"
    wt=""
}

mode=read
[ "$write" = 1 ] && { mode=write; full=1; }

rundir="$workdir"; before=""
if is_git "$workdir" && [ "$inplace" = 0 ]; then
    # read snapshots are disposable, whatever happens (set before creating one)
    [ "$mode" = read ] && [ "$keep" = 0 ] && trap drop_snapshot EXIT
    make_snapshot
    rel="$(git -C "$workdir" rev-parse --show-prefix)"   # keep the sub-folder the caller named
    rundir="$wt/$rel"
elif [ "$mode" = write ]; then
    echo "--write needs <workdir> inside a git repository" >&2; exit 2
else
    # in place: no isolation. Remember the state so an unexpected edit is reported.
    is_git "$workdir" || echo "[warning] $workdir is not a git repository: the worker runs in it directly, unguarded" >&2
    state_of() { is_git "$1" && { git -C "$1" status --porcelain -uall; git -C "$1" diff HEAD 2>/dev/null | cksum; }; }
    before="$(state_of "$workdir")"
fi
winpath="$(native_path "$rundir")"

# ---- prompt --------------------------------------------------------------
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

if [ "$mode" = write ]; then
    full_prompt="$full_prompt

(You are working in an isolated copy of the project. Make the change directly in the files. Do not commit, do not create branches."
    [ -n "$owns" ] && full_prompt="$full_prompt Only modify these paths: $owns. Leave every other file untouched."
    full_prompt="$full_prompt)"
else
    full_prompt="$full_prompt

(Read-only task: do not modify, create or delete any file.)"
fi

# Without --full every shell command is auto-denied, and a worker that tries
# one anyway (models reach for ls/cat/python out of habit) ends with an empty
# answer. Telling it up front avoids most of those wasted runs.
if [ "$full" = 0 ]; then
    full_prompt="$full_prompt
(Shell commands are disabled in this session and will be denied. Use only your file viewing and search tools.)"
fi

schema_arg=""
[ -n "$schema" ] && schema_arg="$(native_path "$(dirname "$schema")")/$(basename "$schema")"

# ---- after a successful run ----------------------------------------------
in_owns() {   # is path $1 inside one of the comma-separated --owns entries?
    local o IFS=,
    for o in $owns; do
        o="${o#./}"; o="${o%/}"
        [ -z "$o" ] && continue
        [ "$1" = "$o" ] && return 0
        case "$1" in "$o"/*) return 0 ;; esac
    done
    return 1
}

report_write() {
    local rc=0 f cur was n=0
    git -C "$wt" add -A >/dev/null 2>&1
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        echo "[changed] $f" >&2
        if [ -n "$owns" ] && ! in_owns "$f"; then
            echo "[violation] $f is outside --owns ($owns)" >&2; rc=3
        fi
        # Did YOU change this file in your checkout since the snapshot was taken?
        if [ -e "$root/$f" ]; then cur="$(git -C "$root" hash-object "$f" 2>/dev/null)"; else cur=none; fi
        was="$(git -C "$wt" rev-parse -q --verify "$base_commit:$f" 2>/dev/null || echo none)"
        [ "$cur" != "$was" ] && echo "[overlap] $f was also changed in your checkout since the snapshot — merge will need care" >&2
    done < <(git -C "$wt" diff --cached --name-only "$base_commit")
    [ "$n" = 0 ] && echo "[changed] nothing — the worker made no edits" >&2

    # The verification gate. A worker is never "done" just because agy said
    # SUCCESS: each check runs in the snapshot, in order, first failure stops.
    if [ ${#verify[@]} -gt 0 ] && [ "$n" -gt 0 ]; then
        local step=0 cmd
        : > "$wt.verify.log"
        for cmd in "${verify[@]}"; do
            step=$((step + 1))
            echo "===== [$step/${#verify[@]}] $cmd" >> "$wt.verify.log"
            if (cd "$rundir" && bash -c "$cmd") >> "$wt.verify.log" 2>&1; then
                echo "[verify $step/${#verify[@]}] PASS: $cmd" >&2
            else
                echo "[verify $step/${#verify[@]}] FAIL: $cmd — log: $wt.verify.log" >&2
                rc=3; break
            fi
        done
    fi
    echo "[snapshot] $wt" >&2
    echo "[merge]    $here/agy-merge.sh \"$wt\"          (review first: git -C \"$wt\" diff $base_commit)" >&2
    echo "[discard]  $here/agy-merge.sh --discard \"$wt\"" >&2
    return "$rc"
}

report_read() {
    if [ -n "$wt" ]; then
        git -C "$wt" add -A >/dev/null 2>&1
        local n
        n="$(git -C "$wt" diff --cached --name-only "$base_commit" | wc -l | tr -d ' ')"
        [ "$n" != 0 ] && echo "[note] the worker edited $n file(s) in its private snapshot; discarded, your checkout is untouched" >&2
        [ "$keep" = 1 ] && echo "[snapshot] kept at $wt" >&2
    elif [ -n "$before" ] && [ "$before" != "$(state_of "$workdir")" ]; then
        echo "[warning] the worker modified files in $workdir — review: git -C \"$workdir\" status" >&2
    fi
    return 0
}

# ---- run -----------------------------------------------------------------
attempt=0
while :; do
capacity_only=1
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
               WORKDIR="$winpath" STATE="$state_dir" MAXLINES="${AGY_MEMORY_MAX_LINES:-40}" MODE="$mode" \
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
       "model": os.environ["MODEL"], "mode": os.environ["MODE"], "workdir": os.environ["WORKDIR"],
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
        [ "$quiet" = 1 ] || echo "[$tier/$model] ${tokens} tokens, ${secs}s, conversation=${convo}${denied:+, denied=$denied}" >&2
        if [ "$mode" = write ]; then report_write; exit $?; fi
        report_read; exit 0
    fi

    echo "[$tier/$model] failed: ${head#*	}" >&2
    case "$head" in
        *503*|*[Cc]apacity*|*UNAVAILABLE*|*"high traffic"*) ;;
        *) capacity_only=0 ;;
    esac
    # a permission denial or an account problem is not a capacity problem:
    # every other model would fail the same way
    case "$head" in *"denied:"*) break ;; esac
    case "$head" in
        *[Ee]ligib*|*"not available in your location"*|*[Uu]nauthenticated*|*"sign in"*|*"log in"*)
            echo "[$tier] account/region problem, not the model — check 'agy' login or VPN" >&2; break ;;
        *"quota reached"*|*RESOURCE_EXHAUSTED*|*"code 429"*)
            # the quota is per account, shared by the fallback models: stop here
            reset="$(printf '%s' "$head" | grep -o 'Resets in [0-9hms]*' | head -n 1)"
            echo "[$tier] account quota used up${reset:+ ($reset)} — try another tier family or wait" >&2
            capacity_only=0; break ;;
    esac
done
# Retry the whole chain only when every model was merely busy.
[ "$capacity_only" = 1 ] && [ "$attempt" -lt "$retries" ] || break
attempt=$((attempt + 1))
echo "[$tier] all models busy — retry $attempt/$retries in $((30 * attempt))s" >&2
sleep $((30 * attempt))
done

echo "[$tier] every model in the chain failed" >&2
[ "$mode" = write ] && drop_snapshot
exit 1
