#!/usr/bin/env bash
# agy-consensus.sh — ask two model families the same review question and
# compare their evidence, not their prose.
#
#   agy-consensus.sh [-T tierA,tierB] [agy-slave options] "<prompt>" [workdir]
#
#   -T TIERS    two (or more) tiers, comma-separated. Default gemini-high,opus
#
# Every worker answers with the bundled `findings` schema: claim, severity,
# file, line_start/line_end, evidence, confidence. Findings from different
# workers that point at the same file and overlapping lines (±3) count as one.
#
# stdout: JSON {"agreed": [...], "single": [...], "failed": [...]}
#   agreed  found by 2+ workers — strong signal, still check the evidence
#   single  found by one worker only — verify yourself before acting
# stderr: a short table. Exit 1 if fewer than two workers answered.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
help() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

tiers="gemini-high,opus"; pass=(); pos=()
while [ $# -gt 0 ]; do
    case "$1" in
        -T) tiers="${2:?}"; shift 2 ;;
        -m|--memory|-t|--timeout|-r|--retries) pass+=("$1" "${2:?}"); shift 2 ;;
        -h|--help) help ;;
        -*) pass+=("$1"); shift ;;
        *)  pos+=("$1"); shift ;;
    esac
done
prompt="${pos[0]:-}"; workdir="${pos[1]:-.}"
[ -n "$prompt" ] || help

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 2; }

out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
IFS=, read -ra list <<< "$tiers"
full_prompt="$prompt

Report only problems you can point to in the code. For each: the file path relative to the workspace, the line numbers, the exact code as evidence, and a confidence between 0 and 1."

for t in "${list[@]}"; do
    ( "$here/agy-slave.sh" ${pass[@]+"${pass[@]}"} -q -s findings "$t" "$full_prompt" "$workdir" \
          > "$out/$t.json" 2> "$out/$t.log"
      echo $? > "$out/$t.rc" ) &
done
wait

OUT="$out" TIERS="$tiers" "$PY" - <<'PYEOF'
import json, os, sys

out = os.environ["OUT"]
tiers = os.environ["TIERS"].split(",")
answers, failed = {}, []
for t in tiers:
    try:
        rc = open(os.path.join(out, t + ".rc")).read().strip()
        if rc != "0":
            raise ValueError("exit " + rc)
        data = json.load(open(os.path.join(out, t + ".json"), encoding="utf-8"))
        answers[t] = data.get("findings") or []
    except Exception as e:
        log = open(os.path.join(out, t + ".log"), encoding="utf-8", errors="replace").read().strip().splitlines()
        reasons = [l.split("failed: ", 1)[1] for l in log if "failed: " in l]
        failed.append({"tier": t, "error": reasons[0] if reasons else (log[-1] if log else str(e))})

def norm(p):
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p.lower()

def span(f):
    a = int(f.get("line_start") or 0)
    b = int(f.get("line_end") or a)
    return min(a, b), max(a, b)

groups = []   # each: {"file", "lo", "hi", "items": [(tier, finding)]}
for t, fs in answers.items():
    for f in fs:
        lo, hi = span(f)
        path = norm(f.get("file", ""))
        for g in groups:
            if g["file"] == path and lo <= g["hi"] + 3 and hi >= g["lo"] - 3 \
               and t not in {x[0] for x in g["items"]}:
                g["items"].append((t, f)); g["lo"] = min(g["lo"], lo); g["hi"] = max(g["hi"], hi)
                break
        else:
            groups.append({"file": path, "lo": lo, "hi": hi, "items": [(t, f)]})

sev = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}
def entry(g):
    items = g["items"]
    return {
        "file": g["file"], "lines": [g["lo"], g["hi"]],
        "found_by": [t for t, _ in items],
        "severity": min((f.get("severity", "info") for _, f in items), key=lambda s: sev.get(s, 5)),
        "confidence": round(sum(float(f.get("confidence") or 0) for _, f in items) / len(items), 2),
        "claims": {t: f.get("claim", "") for t, f in items},
        "evidence": {t: f.get("evidence", "") for t, f in items},
    }

agreed = [entry(g) for g in groups if len(g["items"]) > 1]
single = [entry(g) for g in groups if len(g["items"]) == 1]
key = lambda e: (sev.get(e["severity"], 5), -e["confidence"])
agreed.sort(key=key); single.sort(key=key)

sys.stdout.buffer.write((json.dumps({"agreed": agreed, "single": single, "failed": failed},
                                    ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
w = sys.stderr.write
w("answered: %s   failed: %s\n" % (", ".join(answers) or "-", ", ".join(x["tier"] for x in failed) or "-"))
for label, rows in (("AGREED", agreed), ("single", single)):
    for e in rows:
        w("%-6s %-8s %s:%d-%d  (%s)\n" % (label, e["severity"], e["file"], e["lines"][0], e["lines"][1], "+".join(e["found_by"])))
sys.exit(0 if len(answers) >= 2 else 1)
PYEOF
