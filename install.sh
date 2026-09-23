#!/usr/bin/env bash
# install.sh — make the skill visible to Claude Code (or Codex).
#
#   ./install.sh            copy into ~/.claude/skills/antigravity-slavery
#   ./install.sh --link     symlink instead (edits here take effect at once)
#   ./install.sh --project  install into ./.claude/skills of the current directory
#   ./install.sh --codex    install into ~/.codex/skills for OpenAI Codex CLI
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest_root="$HOME/.claude/skills"; mode=copy
for a in "$@"; do
    case "$a" in
        --link)    mode=link ;;
        --project) dest_root="$PWD/.claude/skills" ;;
        --codex)   dest_root="$HOME/.codex/skills" ;;
        *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
dest="$dest_root/antigravity-slavery"

command -v agy >/dev/null 2>&1 || echo "note: agy is not on PATH yet — install the Antigravity CLI first" >&2
mkdir -p "$dest_root"
if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "already exists: $dest — remove it first to reinstall" >&2; exit 1
fi

if [ "$mode" = link ]; then
    ln -s "$src" "$dest"
else
    mkdir -p "$dest"
    cp -R "$src/SKILL.md" "$src/scripts" "$src/references" "$src/schemas" "$src/examples" "$dest/"
fi
chmod +x "$dest/scripts/"*.sh
echo "installed ($mode): $dest"
