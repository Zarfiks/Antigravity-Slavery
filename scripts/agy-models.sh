#!/usr/bin/env bash
# agy-models.sh — map capability tiers to the models `agy` offers right now.
#
#   agy-models.sh                 show every tier and its model chain
#   agy-models.sh --chain TIER    print one tier's chain (used by agy-slave.sh)
#   agy-models.sh --refresh       re-read `agy models` instead of the cache
#
# Tiers are capabilities; the models behind them are found by pattern and
# sorted newest version first, so a new or renamed model is picked up on its
# own. The list is cached for AGY_MODELS_TTL seconds (default 86400) in
# ${XDG_STATE_HOME:-~/.local/state}/agy-slave/models.txt.

set -uo pipefail

want=""; refresh=0
while [ $# -gt 0 ]; do
    case "$1" in
        --chain)   want="${2:?}"; shift 2 ;;
        --refresh) refresh=1; shift ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

PY=""
for c in python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "python3 is required" >&2; exit 2; }

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/agy-slave"
mkdir -p "$state_dir" 2>/dev/null || true
cache="$state_dir/models.txt"

stale="$(CACHE="$cache" TTL="${AGY_MODELS_TTL:-86400}" "$PY" -c '
import os, time
c = os.environ["CACHE"]
print(1 if not os.path.exists(c) or os.path.getsize(c) == 0
        or time.time() - os.path.getmtime(c) > int(os.environ["TTL"]) else 0)')"

if [ "$refresh" = 1 ] || [ "$stale" = 1 ]; then
    list="$(agy models 2>/dev/null | grep -E '^[a-z0-9][a-z0-9.-]*[[:space:]]' )"
    if [ -n "$list" ]; then
        printf '%s\n' "$list" > "$cache"
    elif [ ! -s "$cache" ]; then
        echo "could not read 'agy models' and no cache yet" >&2; exit 1
    fi
fi

WANT="$want" "$PY" - "$cache" <<'PYEOF'
import os, re, sys

ids = []
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        if line.strip():
            ids.append(line.split()[0])

def ver(mid):
    # gemini-3.8-flash-high -> (3, 8); claude-opus-4-6-thinking -> (4, 6)
    return tuple(int(n) for n in re.findall(r"\d+", mid)[:3]) or (0,)

def pick(pattern, newest=True):
    found = [m for m in ids if re.fullmatch(pattern, m)]
    return sorted(found, key=ver, reverse=newest)

def chain(*groups, limit=3):
    out = []
    for g in groups:
        for m in g:
            if m not in out:
                out.append(m)
    return out[:limit]

flash = lambda lvl: pick(r"gemini-[\d.]+-flash-%s" % lvl)
pro   = lambda lvl: pick(r"gemini-[\d.]+-pro-%s" % lvl)
opus   = pick(r"claude-opus-.*")
sonnet = pick(r"claude-sonnet-.*")

tiers = {
    "gemini-high":   chain(flash("high"), pro("high")),
    "gemini-medium": chain(flash("medium"), pro("low")),
    "gemini-low":    chain(flash("low")),
    "opus":          chain(opus[:2], sonnet[:1]),
    "sonnet":        chain(sonnet[:2], opus[:1]),
    # cheapest last resort: gpt-oss, then the OLDEST small flash
    "gpt-oss":       chain(pick(r"gpt-oss-.*"), pick(r"gemini-[\d.]+-flash-low", newest=False)[:1], limit=2),
}

want = os.environ["WANT"]
if want:
    print(" ".join(tiers.get(want, [])))
else:
    for t, c in tiers.items():
        print("%-14s %s" % (t, "  ".join(c) if c else "(no model found)"))
PYEOF
