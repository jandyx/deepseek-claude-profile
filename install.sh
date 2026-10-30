#!/bin/bash
# Link the deepseek-migration skill into ~/.claude/skills.
# Symlink, so `git pull` updates the installed skill.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src="$repo/skills/deepseek-migration"
dst="${SKILLS_DIR:-$HOME/.claude/skills}/deepseek-migration"

[[ -f "$src/SKILL.md" ]] || { printf 'missing %s\n' "$src/SKILL.md" >&2; exit 1; }
mkdir -p "$(dirname -- "$dst")"

if [[ -L "$dst" ]]; then
  printf 'already linked: %s -> %s\n' "$dst" "$(readlink "$dst")"
  exit 0
fi

if [[ -e "$dst" ]]; then
  printf 'exists and is not a symlink: %s\n' "$dst" >&2
  printf 'Move it aside first:\n  mv %q %q\n' "$dst" "$dst.bak" >&2
  exit 1
fi

ln -s "$src" "$dst"
printf 'linked %s\n     -> %s\n\n' "$dst" "$src"
printf 'Next: run /deepseek-migration inside Claude Code, or:\n'
printf '  bash %q --dry-run\n' "$src/scripts/bootstrap.sh"
