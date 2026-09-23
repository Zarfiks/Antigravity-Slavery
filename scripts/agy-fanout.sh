#!/usr/bin/env bash
# agy-fanout.sh — run many agy workers in parallel, one task per line.
#
#   agy-fanout.sh [-j N] [-o OUTDIR] [agy-slave options] <tier> <workdir> <tasks-file>
#
#   -j N        parallel workers (default 4)
#   -o OUTDIR   where answers go (default ./agy-out-<timestamp>)
#   Every other option (-w, -v, -s, -m, -t ...) is passed to agy-slave.sh.
#
# tasks-file: one prompt per line; blank lines and lines starting with # skip.
# With -w (write jobs) give each task the files it owns, so workers never
# edit the same file:
#   [owns=src/auth/] Add rate limiting to the login handler
#   [owns=src/billing/,docs/billing.md] Rename Invoice.total to amount
#
# Result: OUTDIR/NN.txt (answer), OUTDIR/NN.log (cost line, [changed] files,
# merge command), a summary table, and a CONFLICT list of files that more than
# one worker changed. Exit 1 if any task failed or conflicted.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
help() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

jobs=4; outdir=""; pass=(); pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        -j) jobs="${2:?}"; shift 2 ;;
        -o) outdir="${2:?}"; shift 2 ;;
        -s|--schema|-m|--memory|-t|--timeout|-c|--conversation|-v|--verify|-r|--retries)
            pass+=("$1" "${2:?}"); shift 2 ;;
        -h|--help) help ;;
        -*) pass+=("$1"); shift ;;
        *)  pos+=("$1"); shift ;;
    esac
done
[ ${#pos[@]} -eq 3 ] || help
tier="${pos[0]}"; workdir="${pos[1]}"; tasks="${pos[2]}"
[ -f "$tasks" ] || { echo "tasks file not found: $tasks" >&2; exit 2; }
outdir="${outdir:-./agy-out-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$outdir"

# Two write tasks that claim the same path would edit the same files: refuse
# before spending anything.
claims="$(sed -n 's/^\[owns=\([^]]*\)\].*/\1/p' "$tasks" | tr ',' '\n' | sed 's#^\./##; s#/$##' | sed '/^$/d' | sort)"
dup="$(printf '%s\n' "$claims" | uniq -d)"
if [ -n "$dup" ]; then
    echo "two tasks own the same path — split the work differently:" >&2
    printf '  %s\n' $dup >&2
    exit 2
fi

n=0; running=0
while IFS= read -r task || [ -n "$task" ]; do
    task="${task%$'\r'}"
    case "$task" in ''|'#'*) continue ;; esac
    n=$((n + 1)); id="$(printf '%02d' "$n")"
    extra=()
    if [[ "$task" =~ ^\[owns=([^]]*)\][[:space:]]*(.*)$ ]]; then
        extra=(-o "${BASH_REMATCH[1]}"); task="${BASH_REMATCH[2]}"
    fi
    printf '%s\n' "$task" > "$outdir/$id.task"
    ( "$here/agy-slave.sh" ${pass[@]+"${pass[@]}"} ${extra[@]+"${extra[@]}"} "$tier" "$task" "$workdir" \
          > "$outdir/$id.txt" 2> "$outdir/$id.log"
      echo $? > "$outdir/$id.rc" ) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        # bash >= 4.3 waits for any one job; older bash (macOS /bin/bash) waits for the batch
        if wait -n 2>/dev/null; then running=$((running - 1)); else wait; running=0; fi
    fi
done < "$tasks"
wait

fail=0
for rc in "$outdir"/*.rc; do
    [ -e "$rc" ] || continue
    id="$(basename "$rc" .rc)"
    case "$(cat "$rc")" in
        0) s=ok ;;
        3) s=CHECK; fail=1 ;;     # worker ok, but verify failed or it left --owns
        *) s=FAIL; fail=1 ;;
    esac
    printf '%-4s %-5s %s\n' "$id" "$s" "$(grep -m1 '^\[.*tokens' "$outdir/$id.log" || tail -n 1 "$outdir/$id.log")" >&2
done

# Files changed by more than one worker cannot all be merged cleanly.
conflicts="$(grep -h '^\[changed\] ' "$outdir"/*.log 2>/dev/null | grep -v 'nothing —' | sort | uniq -d | sed 's/^\[changed\] //')"
if [ -n "$conflicts" ]; then
    fail=1
    echo "CONFLICT — changed by more than one worker; merge one, re-run the others on top:" >&2
    printf '%s\n' "$conflicts" | sed 's/^/  /' >&2
fi
grep -h '^\[merge\]' "$outdir"/*.log 2>/dev/null | sed 's/^\[merge\] */merge: /' >&2
echo "answers in $outdir" >&2
exit "$fail"
