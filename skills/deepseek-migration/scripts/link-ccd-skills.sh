#!/bin/bash
# Link skills from the ccd profile into the dsd profile.
# Idempotent: existing entries (links or local skills) are never touched, so a
# skill created directly in the dsd profile survives.
set -euo pipefail

src_dir="${CCD_CONFIG_DIR:-$HOME/.claude}/skills"
dst_dir="${DSD_PROFILE_DIR:-$HOME/.config/deepseek-claude}/claude/skills"

# Greenfield installs have no source profile. Not an error.
[[ -d "$src_dir" ]] || exit 0
mkdir -p "$dst_dir"

shopt -s nullglob
for src in "$src_dir"/*; do
  name=${src##*/}
  # synced/ is claude's internal skill-sync bucket, not a user skill
  case "$name" in synced|.DS_Store|.trash) continue ;; esac
  if [[ -e "$dst_dir/$name" || -L "$dst_dir/$name" ]]; then
    continue
  fi
  ln -s "$src" "$dst_dir/$name"
  printf 'linked %s\n' "$name"
done
