#!/usr/bin/env bash
# agy-merge.sh — bring a write worker's snapshot back into your checkout.
#
#   agy-merge.sh <snapshot>             apply its changes to your checkout, then remove it
#   agy-merge.sh --check <snapshot>     show files and overlaps, change nothing
#   agy-merge.sh --keep <snapshot>      apply, but keep the snapshot
#   agy-merge.sh --discard <snapshot>   throw the snapshot away
#   agy-merge.sh --list                 list snapshots waiting for review
#   agy-merge.sh --prune [DAYS]         remove snapshots older than DAYS (default 7)
#                                       and any whose repository is gone
#
# Files you did not touch since the snapshot are copied over; files you also
# edited are merged three-way (`git merge-file`); real conflicts get markers.
# Nothing is committed — review with `git diff`, run your checks, commit yourself.
# Exit: 0 ok, 1 conflicts or overlaps (--check), 2 usage error.

set -uo pipefail
help() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

action=apply; keep=0; target=""; days=7
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   action=check; shift ;;
        --discard) action=discard; shift ;;
        --keep)    keep=1; shift ;;
        --list)    action=list; shift ;;
        --prune)   action=prune; shift
                   case "${1:-}" in ''|*[!0-9]*) ;; *) days="$1"; shift ;; esac ;;
        -h|--help) help ;;
        -*)        echo "unknown option: $1" >&2; help ;;
        *)         target="$1"; shift ;;
    esac
done

wbase="${AGY_WORKTREE_DIR:-${TMPDIR:-/tmp}/agy-worktrees}"

if [ "$action" = list ]; then
    found=0
    for m in "$wbase"/*.meta; do
        [ -e "$m" ] || continue
        found=1
        wt="$(sed -n 's/^WT=//p' "$m")"; base="$(sed -n 's/^BASE=//p' "$m")"
        root="$(sed -n 's/^ROOT=//p' "$m")"
        git -C "$wt" add -A >/dev/null 2>&1
        n="$(git -C "$wt" diff --cached --name-only "$base" 2>/dev/null | wc -l | tr -d ' ')"
        printf '%s\n    repo: %s   files changed: %s\n' "$wt" "$root" "$n"
    done
    [ "$found" = 1 ] || echo "no snapshots in $wbase"
    exit 0
fi

if [ "$action" = prune ]; then
    removed=0
    for m in "$wbase"/*.meta; do
        [ -e "$m" ] || continue
        wt="$(sed -n 's/^WT=//p' "$m")"; root="$(sed -n 's/^ROOT=//p' "$m")"
        if [ ! -d "$root" ] || [ ! -d "$wt" ] || [ -n "$(find "$m" -mmin +"$((days * 1440))" 2>/dev/null)" ]; then
            git -C "$root" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
            rm -f "$m" "$wt.patch" "$wt.verify.log"
            [ -d "$root" ] && git -C "$root" worktree prune 2>/dev/null
            echo "removed $wt"; removed=$((removed + 1))
        fi
    done
    echo "pruned $removed snapshot(s) older than $days day(s) or orphaned"
    exit 0
fi

[ -n "$target" ] || help
wt="${target%/}"; meta="$wt.meta"
[ -f "$meta" ] || { echo "not an agy snapshot (no $meta)" >&2; exit 2; }
root="$(sed -n 's/^ROOT=//p' "$meta")"
base="$(sed -n 's/^BASE=//p' "$meta")"
owns="$(sed -n 's/^OWNS=//p' "$meta")"

remove() {
    git -C "$root" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
    rm -f "$meta" "$wt.patch" "$wt.verify.log"
    echo "removed $wt"
}

if [ "$action" = discard ]; then remove; exit 0; fi

git -C "$wt" add -A >/dev/null 2>&1
files="$(git -C "$wt" diff --cached --name-only "$base")"
if [ -z "$files" ]; then
    echo "nothing to merge: the worker changed no files"
    [ "$action" = apply ] && [ "$keep" = 0 ] && remove
    exit 0
fi

overlap=0
while IFS= read -r f; do
    if [ -e "$root/$f" ]; then cur="$(git -C "$root" hash-object "$f" 2>/dev/null)"; else cur=none; fi
    was="$(git -C "$wt" rev-parse -q --verify "$base:$f" 2>/dev/null || echo none)"
    note=""
    [ "$cur" != "$was" ] && { note="  [overlap: you changed it too]"; overlap=1; }
    if [ -n "$owns" ]; then
        inside=0; IFS=, read -ra list <<< "$owns"
        for o in "${list[@]}"; do
            o="${o#./}"; o="${o%/}"
            { [ "$f" = "$o" ] || [[ "$f" == "$o"/* ]]; } && inside=1
        done
        [ "$inside" = 0 ] && note="$note  [outside --owns]"
    fi
    echo "  $f$note"
done <<< "$files"

if [ "$action" = check ]; then
    echo "diff: git -C \"$wt\" diff $base"
    exit "$overlap"
fi

# File by file, against your working tree (uncommitted edits included):
# - you did not touch the file since the snapshot -> take the worker's version
# - you did -> three-way merge (snapshot = base, yours, worker's) with
#   `git merge-file`; clashing hunks get <<<<<<< markers
conflicts=0
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
while IFS= read -r f; do
    if [ -e "$root/$f" ]; then cur="$(git -C "$root" hash-object "$f" 2>/dev/null)"; else cur=none; fi
    was="$(git -C "$wt" rev-parse -q --verify "$base:$f" 2>/dev/null || echo none)"
    if [ "$cur" = "$was" ]; then
        if [ -e "$wt/$f" ]; then
            mkdir -p "$(dirname "$root/$f")" && cp -p "$wt/$f" "$root/$f"
        else
            rm -f "$root/$f"
        fi
        echo "  taken   $f"
    elif [ ! -e "$wt/$f" ]; then
        echo "  CONFLICT $f — the worker deleted it, you changed it; left as yours" >&2; conflicts=1
    else
        [ "$was" = none ] && : > "$tmp" || git -C "$wt" show "$base:$f" > "$tmp"
        [ -e "$root/$f" ] || : > "$root/$f"
        git merge-file -L yours -L snapshot -L agy "$root/$f" "$tmp" "$wt/$f"
        rc=$?
        if [ "$rc" = 0 ]; then echo "  merged  $f"
        else echo "  CONFLICT $f — resolve the <<<<<<< markers" >&2; conflicts=1; fi
    fi
done <<< "$files"

if [ "$conflicts" = 0 ]; then
    echo "applied to $root (not committed). Next: git diff, typecheck, tests, build."
    [ "$keep" = 0 ] && remove
    exit 0
fi
echo "snapshot kept for reference: $wt  (drop it: $0 --discard \"$wt\")" >&2
exit 1
