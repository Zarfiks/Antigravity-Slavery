#!/usr/bin/env bash
# agy-fanout.sh — run many agy workers in parallel, one task per line.
#
#   agy-fanout.sh [-j N] [-o OUTDIR] [agy-slave options] <tier> <workdir> <tasks-file>
#
#   -j N        parallel workers (default 4)
#   -o OUTDIR   where answers go (default ./agy-out-<timestamp>)
#   Every other option (-s, -f, -w, -m, -t ...) is passed to agy-slave.sh.
#
# tasks-file: one prompt per line; blank lines and lines starting with # skip.
# Result: OUTDIR/NN.txt (answer), OUTDIR/NN.log (cost line / errors),
# and a summary table on stderr. Exit 1 if any task failed.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
help() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

jobs=4; outdir=""; pass=(); pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        -j) jobs="${2:?}"; shift 2 ;;
        -o) outdir="${2:?}"; shift 2 ;;
        -s|--schema|-m|--memory|-t|--timeout|-c|--conversation) pass+=("$1" "${2:?}"); shift 2 ;;
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

n=0; running=0
while IFS= read -r task || [ -n "$task" ]; do
    task="${task%$'\r'}"
    case "$task" in ''|'#'*) continue ;; esac
    n=$((n + 1)); id="$(printf '%02d' "$n")"
    printf '%s\n' "$task" > "$outdir/$id.task"
    ( "$here/agy-slave.sh" ${pass[@]+"${pass[@]}"} "$tier" "$task" "$workdir" \
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
    if [ "$(cat "$rc")" = 0 ]; then s=ok; else s=FAIL; fail=1; fi
    printf '%-4s %-4s %s\n' "$id" "$s" "$(tail -n 1 "$outdir/$id.log")" >&2
done
echo "answers in $outdir" >&2
exit "$fail"
