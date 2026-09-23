#!/usr/bin/env bash
# agy-cost.sh — what delegation actually cost, from the run log.
#
#   agy-cost.sh                    all runs, grouped by tier
#   agy-cost.sh --job ID           one fan-out (the id is printed at its end)
#   agy-cost.sh --since 2026-09-23 runs from that day on
#   agy-cost.sh --last N           the last N runs
#
# Reads ${XDG_STATE_HOME:-~/.local/state}/agy-slave/runs.jsonl, written by
# agy-slave.sh for every call. Use the median to decide whether a job is worth
# delegating: if you can read the files for fewer tokens than one worker call
# costs, do it yourself.

set -uo pipefail
job=""; since=""; last=0
while [ $# -gt 0 ]; do
    case "$1" in
        --job)   job="${2:?}"; shift 2 ;;
        --since) since="${2:?}"; shift 2 ;;
        --last)  last="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 2; }

log="${XDG_STATE_HOME:-$HOME/.local/state}/agy-slave/runs.jsonl"
[ -s "$log" ] || { echo "no runs logged yet ($log)"; exit 0; }

JOB="$job" SINCE="$since" LAST="$last" "$PY" - "$log" <<'PYEOF'
import json, os, statistics, sys

rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
if os.environ["JOB"]:
    rows = [r for r in rows if r.get("job") == os.environ["JOB"]]
if os.environ["SINCE"]:
    rows = [r for r in rows if (r.get("ts") or "") >= os.environ["SINCE"]]
if int(os.environ["LAST"]):
    rows = rows[-int(os.environ["LAST"]):]
if not rows:
    print("no matching runs"); sys.exit()

def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0

by = {}
for r in rows:
    by.setdefault(r.get("tier") or "?", []).append(r)

print("%-14s %5s %5s %5s %12s %10s %8s" % ("tier", "calls", "ok", "fail", "tokens", "median tok", "median s"))
tot_tok = 0
for tier, rs in sorted(by.items()):
    ok = [r for r in rs if r.get("status") == "SUCCESS"]
    tok = sum(num(r.get("tokens")) for r in rs)
    tot_tok += tok
    med_t = statistics.median([num(r.get("tokens")) for r in ok]) if ok else 0
    med_s = statistics.median([num(r.get("seconds")) for r in ok]) if ok else 0
    print("%-14s %5d %5d %5d %12d %10d %8.0f" % (tier, len(rs), len(ok), len(rs) - len(ok), tok, med_t, med_s))

ok_all = [r for r in rows if r.get("status") == "SUCCESS"]
print("-" * 66)
print("%-14s %5d %5d %5d %12d" % ("total", len(rows), len(ok_all), len(rows) - len(ok_all), tot_tok))
if ok_all:
    m = statistics.median([num(r.get("tokens")) for r in ok_all])
    print("\nA successful call costs ~%d tokens (median). Reading fewer than that yourself is cheaper." % m)
PYEOF
