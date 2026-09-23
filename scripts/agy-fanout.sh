#!/usr/bin/env bash
# agy-fanout.sh — a queue of agy workers: one task per line, run by a scheduler.
#
#   agy-fanout.sh [options] <tier> <workdir> <tasks-file>
#
#   -j N            at most N workers at once (default 4)
#   --max-write N   at most N of them write jobs (default 2)
#   -s NAME|FILE    schema for read tasks (findings, list, verdict or a file)
#   --prose         allow read tasks without a schema (free text answers)
#   --first         stop as soon as one task succeeds: cancel the running
#                   workers, skip the rest (for "first good answer wins")
#   -w              make every task a write task
#   -o OUTDIR       where answers go (default ./agy-out-<timestamp>)
#   Every other option (-v, -m, -t, -r ...) is passed to agy-slave.sh.
#
# tasks-file: one prompt per line; blank lines and # lines skip. Order is
# priority: earlier lines start first. Optional tags before the prompt:
#   [owns=src/auth/] Add rate limiting        write task owning src/auth/
#   [write] Fix the typo in README.md         write task, no ownership check
#   [schema=findings] Review src/billing/     read task with its own schema
#   [tier=opus] Double-check the locking      this task on another tier
#
# Read tasks MUST have a schema (-s or [schema=]) unless --prose: a fan-out is
# aggregated by a program, and prose breaks that.
#
# Result: OUTDIR/NN.txt (answer), OUTDIR/NN.log (cost, [changed], merge
# command), a summary table with total tokens, and a CONFLICT list of files
# changed by more than one worker. Exit 1 if any task failed or conflicted.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
help() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

jobs=4; maxw=2; outdir=""; schema=""; prose=0; first=0; allwrite=0; pass=(); pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        -j)          jobs="${2:?}"; shift 2 ;;
        --max-write) maxw="${2:?}"; shift 2 ;;
        -o)          outdir="${2:?}"; shift 2 ;;
        -s|--schema) schema="${2:?}"; shift 2 ;;
        --prose)     prose=1; shift ;;
        --first)     first=1; shift ;;
        -w|--write)  allwrite=1; shift ;;
        -m|--memory|-t|--timeout|-c|--conversation|-v|--verify|-r|--retries)
                     pass+=("$1" "${2:?}"); shift 2 ;;
        -h|--help)   help ;;
        -*)          pass+=("$1"); shift ;;
        *)           pos+=("$1"); shift ;;
    esac
done
[ ${#pos[@]} -eq 3 ] || help
tier="${pos[0]}"; workdir="${pos[1]}"; tasks="${pos[2]}"
[ -f "$tasks" ] || { echo "tasks file not found: $tasks" >&2; exit 2; }
[ "$jobs" -ge 1 ] && [ "$maxw" -ge 0 ] || { echo "-j must be >= 1, --max-write >= 0" >&2; exit 2; }

# ---- parse tasks ---------------------------------------------------------
text=(); isw=(); owns=(); sch=(); ttier=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    w="$allwrite"; o=""; s="$schema"; t="$tier"
    while [[ "$line" =~ ^\[([a-z]+)(=([^]]*))?\][[:space:]]*(.*)$ ]]; do
        case "${BASH_REMATCH[1]}" in
            owns)   o="${BASH_REMATCH[3]}"; w=1 ;;
            write)  w=1 ;;
            schema) s="${BASH_REMATCH[3]}" ;;
            tier)   t="${BASH_REMATCH[3]}" ;;
            *) echo "unknown tag [${BASH_REMATCH[1]}] in: $line" >&2; exit 2 ;;
        esac
        line="${BASH_REMATCH[4]}"
    done
    if [ "$w" = 0 ] && [ -z "$s" ] && [ "$prose" = 0 ]; then
        echo "read task without a schema: \"$line\" — add -s findings|list|verdict, [schema=...], or --prose" >&2
        exit 2
    fi
    text+=("$line"); isw+=("$w"); owns+=("$o"); sch+=("$s"); ttier+=("$t")
done < "$tasks"
n=${#text[@]}
[ "$n" -gt 0 ] || { echo "no tasks in $tasks" >&2; exit 2; }
[ "$maxw" = 0 ] && printf '%s\n' "${isw[@]}" | grep -q 1 && { echo "--max-write 0 but the file has write tasks" >&2; exit 2; }

# Two write tasks that claim the same path would edit the same files: refuse
# before spending anything.
dup="$(for o in ${owns[@]+"${owns[@]}"}; do printf '%s\n' "$o"; done | tr ',' '\n' \
       | sed 's#^\./##; s#/$##' | sed '/^$/d' | sort | uniq -d)"
if [ -n "$dup" ]; then
    echo "two tasks own the same path — split the work differently:" >&2
    printf '  %s\n' $dup >&2
    exit 2
fi

outdir="${outdir:-./agy-out-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$outdir"
job="fanout-$(date +%Y%m%d-%H%M%S)-$$"

# ---- scheduler -----------------------------------------------------------
children() {
    if command -v pgrep >/dev/null 2>&1; then pgrep -P "$1"
    else ps -l | awk -v p="$1" '{ i = ($1 ~ /^[0-9]+$/) ? 1 : 2; if ($(i+1) == p) print $i }'   # Git Bash
    fi
}
kill_tree() {
    local c
    for c in $(children "$1"); do kill_tree "$c"; done
    kill "$1" 2>/dev/null
}

pid=(); state=()                      # state: pending | running | done | cancelled | skipped
for ((k = 0; k < n; k++)); do state[k]=pending; done
running=0; wrunning=0; winner=""

launch() {
    local k=$1 id args=()
    id="$(printf '%02d' $((k + 1)))"
    [ "${isw[k]}" = 1 ] && args+=(-w)
    [ -n "${owns[k]}" ] && args+=(-o "${owns[k]}")
    [ "${isw[k]}" = 0 ] && [ -n "${sch[k]}" ] && args+=(-s "${sch[k]}")
    printf '%s\n' "${text[k]}" > "$outdir/$id.task"
    ( AGY_JOB="$job" "$here/agy-slave.sh" ${pass[@]+"${pass[@]}"} ${args[@]+"${args[@]}"} \
          "${ttier[k]}" "${text[k]}" "$workdir" > "$outdir/$id.txt" 2> "$outdir/$id.log"
      echo $? > "$outdir/$id.rc" ) &
    pid[k]=$!; state[k]=running
    running=$((running + 1)); [ "${isw[k]}" = 1 ] && wrunning=$((wrunning + 1))
}

while :; do
    # reap finished workers
    for ((k = 0; k < n; k++)); do
        [ "${state[k]}" = running ] || continue
        kill -0 "${pid[k]}" 2>/dev/null && continue
        wait "${pid[k]}" 2>/dev/null
        state[k]=done; running=$((running - 1)); [ "${isw[k]}" = 1 ] && wrunning=$((wrunning - 1))
        id="$(printf '%02d' $((k + 1)))"
        if [ "$first" = 1 ] && [ -z "$winner" ] && [ "$(cat "$outdir/$id.rc" 2>/dev/null)" = 0 ]; then
            winner=$k
            for ((j = 0; j < n; j++)); do
                case "${state[j]}" in
                    running) kill_tree "${pid[j]}"; wait "${pid[j]}" 2>/dev/null
                             state[j]=cancelled; echo 130 > "$outdir/$(printf '%02d' $((j + 1))).rc" ;;
                    pending) state[j]=skipped ;;
                esac
            done
            running=0; wrunning=0
        fi
    done

    # start what fits, in file order; a write task waits for a write slot,
    # read tasks behind it may still start
    if [ -z "$winner" ]; then
        for ((k = 0; k < n && running < jobs; k++)); do
            [ "${state[k]}" = pending ] || continue
            [ "${isw[k]}" = 1 ] && [ "$wrunning" -ge "$maxw" ] && continue
            launch "$k"
        done
    fi

    left=0
    for ((k = 0; k < n; k++)); do case "${state[k]}" in pending|running) left=1 ;; esac; done
    [ "$left" = 0 ] && break
    sleep 1
done

# ---- report --------------------------------------------------------------
fail=0; total=0
for ((k = 0; k < n; k++)); do
    id="$(printf '%02d' $((k + 1)))"
    case "${state[k]}" in
        skipped)   printf '%-4s %-9s %s\n' "$id" skipped "(not started: --first had a winner)" >&2; continue ;;
        cancelled) printf '%-4s %-9s %s\n' "$id" cancelled "(stopped: --first had a winner)" >&2; continue ;;
    esac
    case "$(cat "$outdir/$id.rc" 2>/dev/null)" in
        0) s=ok ;;
        3) s=CHECK; fail=1 ;;     # worker ok, but verify failed or it left --owns
        *) s=FAIL; fail=1 ;;
    esac
    cost="$(grep -m1 ' tokens, ' "$outdir/$id.log" 2>/dev/null)"
    tok="$(printf '%s' "$cost" | sed -n 's/.*\] \([0-9][0-9]*\) tokens.*/\1/p')"
    [ -n "$tok" ] && total=$((total + tok))
    printf '%-4s %-9s %s\n' "$id" "$s" "${cost:-$(tail -n 1 "$outdir/$id.log" 2>/dev/null)}" >&2
done
[ -n "$winner" ] && { echo "winner: $(printf '%02d' $((winner + 1))) — $outdir/$(printf '%02d' $((winner + 1))).txt" >&2; fail=0; }

# Files changed by more than one worker cannot all be merged cleanly.
conflicts="$(grep -h '^\[changed\] ' "$outdir"/*.log 2>/dev/null | grep -v 'nothing —' | sort | uniq -d | sed 's/^\[changed\] //')"
if [ -n "$conflicts" ]; then
    fail=1
    echo "CONFLICT — changed by more than one worker; merge one, re-run the others on top:" >&2
    printf '%s\n' "$conflicts" | sed 's/^/  /' >&2
fi
grep -h '^\[merge\]' "$outdir"/*.log 2>/dev/null | sed 's/^\[merge\] */merge: /' >&2
echo "total: $total tokens   job: $job   answers: $outdir   (cost: scripts/agy-cost.sh --job $job)" >&2
exit "$fail"
