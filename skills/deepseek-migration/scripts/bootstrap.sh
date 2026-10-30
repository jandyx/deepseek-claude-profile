#!/bin/bash
# Create or update an isolated DeepSeek-backed Claude Code profile.
#
# Idempotent. Never overwrites an existing launcher without --force, never
# prints the API key, and never modifies the source profile's settings.
#
#   bootstrap.sh --dry-run          show what would change
#   bootstrap.sh                    apply
#   bootstrap.sh --force            replace existing launchers
#   bootstrap.sh --rollback         remove launchers, profile dir, alias block
#
# Environment overrides:
#   DSD_PROFILE_DIR   default ~/.config/deepseek-claude
#   CCD_CONFIG_DIR    default ~/.claude
#   DSD_BIN_DIR       default ~/.local/bin
#   DSD_API_KEY_FILE  copy the key from here instead of prompting
#   DSD_BASE_URL / DSD_MAIN_MODEL / DSD_SMALL_MODEL
set -euo pipefail
umask 077

PROFILE_DIR="${DSD_PROFILE_DIR:-$HOME/.config/deepseek-claude}"
CCD_DIR="${CCD_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${DSD_BIN_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${DSD_ZSHRC:-$HOME/.zshrc}"
ALIAS_NAME="${DSD_ALIAS:-dsd}"
ALIAS_BEGIN="# >>> deepseek-claude profile >>>"
ALIAS_END="# <<< deepseek-claude profile <<<"

DRY_RUN=0
FORCE=0
ROLLBACK=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --rollback) ROLLBACK=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run()  { if (( DRY_RUN )); then printf '  would: %s\n' "$*"; else "$@"; fi; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- rollback ----
if (( ROLLBACK )); then
  step "Rollback"
  run rm -f "$BIN_DIR/dsd" "$BIN_DIR/deepseek-claude"
  run rm -rf "$PROFILE_DIR"
  if [[ -f "$ZSHRC" ]] && grep -qF "$ALIAS_BEGIN" "$ZSHRC"; then
    if (( DRY_RUN )); then
      say "  would: remove alias block from $ZSHRC"
    else
      cp "$ZSHRC" "$ZSHRC.before-dsd-rollback.$(date +%Y%m%d-%H%M%S)"
      awk -v b="$ALIAS_BEGIN" -v e="$ALIAS_END" '
        index($0,b){skip=1} !skip{print} index($0,e){skip=0}
      ' "$ZSHRC" > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
      say "  removed alias block from $ZSHRC"
    fi
  fi
  say "Rolled back. Nothing else was touched."
  exit 0
fi

# ---------------------------------------------------------------- preflight ---
step "Preflight"
command -v claude >/dev/null || die "claude CLI not found in PATH"
command -v python3 >/dev/null || die "python3 not found; merge step needs it"
say "  claude  $(claude --version 2>/dev/null | head -1)"
say "  profile $PROFILE_DIR"
say "  source  $CCD_DIR $([[ -d $CCD_DIR ]] && echo '(found)' || echo '(missing — greenfield)')"
(( DRY_RUN )) && say "  MODE    dry-run, nothing will be written"

# ------------------------------------------------------------------- layout ---
step "Profile directories"
run mkdir -p "$PROFILE_DIR/claude" "$BIN_DIR"
if (( ! DRY_RUN )); then
  chmod 700 "$PROFILE_DIR" "$PROFILE_DIR/claude"
  chmod 700 "$BIN_DIR" 2>/dev/null || true
fi

# ---------------------------------------------------------------- api key -----
step "API key"
KEY_FILE="$PROFILE_DIR/api-key"
if [[ -s "$KEY_FILE" ]]; then
  say "  exists, leaving untouched"
elif [[ -n "${DSD_API_KEY_FILE:-}" ]]; then
  [[ -r "$DSD_API_KEY_FILE" ]] || die "DSD_API_KEY_FILE is not readable: $DSD_API_KEY_FILE"
  run cp "$DSD_API_KEY_FILE" "$KEY_FILE"
  say "  copied from $DSD_API_KEY_FILE"
else
  if (( DRY_RUN )); then
    say "  would prompt for a key"
  else
    read -rs -p "  paste DeepSeek API key (input hidden): " key_from_tty
    printf '\n'
    [[ -n "$key_from_tty" ]] || die "empty key"
    printf '%s' "$key_from_tty" > "$KEY_FILE"
    unset key_from_tty
    say "  written to $KEY_FILE"
  fi
fi
(( ! DRY_RUN )) && [[ -f "$KEY_FILE" ]] && chmod 600 "$KEY_FILE"

# ------------------------------------------------------------- profile.env ----
step "profile.env"
ENV_FILE="$PROFILE_DIR/profile.env"
if [[ -f "$ENV_FILE" ]]; then
  say "  exists, leaving untouched (edit it to change models)"
else
  if (( DRY_RUN )); then
    say "  would write $ENV_FILE"
  else
    cat > "$ENV_FILE" <<EOF
# Read by ~/.local/bin/deepseek-claude on every launch.
# Values below match the official DeepSeek Claude Code integration guide
# (api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code).
#   deepseek-flash       fast tier, also what claude-sonnet*/claude-haiku* map to
#   deepseek-v4-pro      pro tier, what claude-opus* maps to
# Append [1m] only if the endpoint advertises a 1M window and accepts the suffix.
# Effort defaults to high rather than the guide's max: max burns noticeably more
# reasoning tokens per turn, which lands straight on a metered bill.
DSD_BASE_URL=${DSD_BASE_URL:-https://api.deepseek.com/anthropic}
DSD_MAIN_MODEL=${DSD_MAIN_MODEL:-deepseek-flash[1m]}
DSD_SMALL_MODEL=${DSD_SMALL_MODEL:-deepseek-flash}
DSD_EFFORT_LEVEL=${DSD_EFFORT_LEVEL:-high}
DSD_AUTO_COMPACT_WINDOW=${DSD_AUTO_COMPACT_WINDOW:-786432}
# Space-separated plugins to keep disabled even though ccd has them enabled.
DSD_DISABLED_PLUGINS="${DSD_DISABLED_PLUGINS:-}"
EOF
    chmod 600 "$ENV_FILE"
    say "  wrote $ENV_FILE"
  fi
fi

# ---------------------------------------------------------------- launchers ---
install_launcher() {
  local target="$1" body="$2"
  if [[ -f "$target" ]] && (( ! FORCE )); then
    say "  exists, left alone: $target  (use --force to replace; see $target.new)"
    if (( ! DRY_RUN )); then printf '%s' "$body" > "$target.new"; chmod 700 "$target.new"; fi
    return
  fi
  if (( DRY_RUN )); then
    say "  would write $target"
  else
    printf '%s' "$body" > "$target"
    chmod 700 "$target"
    say "  wrote $target"
  fi
}

step "Launchers"
read -r -d '' LAUNCHER <<'LAUNCHER_EOF' || true
#!/bin/bash
# DeepSeek-only Claude Code profile. Nothing is exported into the calling shell.
set +x
set -euo pipefail
umask 077
profile_dir="${DSD_PROFILE_DIR:-$HOME/.config/deepseek-claude}"

die() { printf 'deepseek-claude: %s\n' "$*" >&2; exit 1; }

[[ -r "$profile_dir/api-key" ]] || die "missing API key: $profile_dir/api-key"

# Do not inherit Claude credentials, provider routing, or Keychain overrides.
while IFS= read -r name; do
  case "$name" in
    ANTHROPIC_*|CLAUDE_CODE_OAUTH_TOKEN*|CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR|\
    CLAUDE_CODE_USE_*|CLAUDE_SECURESTORAGE_CONFIG_DIR)
      unset "$name" ;;
  esac
done < <(compgen -e)

# shellcheck disable=SC1091
[[ -r "$profile_dir/profile.env" ]] && . "$profile_dir/profile.env"

key="$(cat "$profile_dir/api-key")"
[[ -n "$key" ]] || die "API key is empty: $profile_dir/api-key"

main_model="${DSD_MAIN_MODEL:-deepseek-flash[1m]}"
small_model="${DSD_SMALL_MODEL:-deepseek-flash}"

export CLAUDE_CONFIG_DIR="$profile_dir/claude"
export ANTHROPIC_BASE_URL="${DSD_BASE_URL:-https://api.deepseek.com/anthropic}"
export ANTHROPIC_AUTH_TOKEN="$key"
export ANTHROPIC_MODEL="$main_model"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$main_model"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$main_model"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$small_model"
export ANTHROPIC_DEFAULT_FABLE_MODEL="$main_model"
export CLAUDE_CODE_SUBAGENT_MODEL="$small_model"
export CLAUDE_CODE_EFFORT_LEVEL="${DSD_EFFORT_LEVEL:-high}"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW="${DSD_AUTO_COMPACT_WINDOW:-786432}"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

# Mirror ccd's shared config on every launch (skills, plugins, hooks, statusLine, MCP).
# Best-effort: a sync failure must never block startup.
for helper in link-ccd-skills.sh merge-ccd-config.py; do
  [[ -x "$profile_dir/$helper" ]] && { "$profile_dir/$helper" >/dev/null 2>&1 || true; }
done

# Avoid loading $HOME/.claude as project settings when launched from $HOME.
# Repo CLAUDE.md still applies; repo settings/hooks/plugins are opt-in.
exec claude --setting-sources user "$@"
LAUNCHER_EOF

read -r -d '' DSD_EOF <<'DSD_EOF' || true
#!/bin/bash
# Permission-bypass variant. Also a command, for shells opened before the alias.
exec "${HOME}/.local/bin/deepseek-claude" --dangerously-skip-permissions "$@"
DSD_EOF

install_launcher "$BIN_DIR/deepseek-claude" "$LAUNCHER"
install_launcher "$BIN_DIR/dsd" "$DSD_EOF"

# ------------------------------------------------------------------ helpers ---
step "Sync helpers"
for helper in link-ccd-skills.sh merge-ccd-config.py; do
  src="$SCRIPT_DIR/$helper"
  dst="$PROFILE_DIR/$helper"
  [[ -f "$src" ]] || die "missing $src"
  if (( DRY_RUN )); then
    say "  would install $dst"
  else
    install -m 700 "$src" "$dst" 2>/dev/null || { cp "$src" "$dst"; chmod 700 "$dst"; }
    say "  installed $dst"
  fi
done

# ------------------------------------------------------------ profile files ---
step "Profile settings"
DSD_SET="$PROFILE_DIR/claude/settings.json"
DSD_CFG="$PROFILE_DIR/claude/.claude.json"
if (( ! DRY_RUN )); then
  [[ -f "$DSD_SET" ]] || { printf '{}\n' > "$DSD_SET"; chmod 600 "$DSD_SET"; }
  [[ -f "$DSD_CFG" ]] || { printf '{}\n' > "$DSD_CFG"; chmod 600 "$DSD_CFG"; }
  python3 - "$DSD_SET" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
# Only seed keys the merge step will not overwrite. Merge owns hooks/statusLine/
# enabledPlugins/extraKnownMarketplaces.
d.setdefault("theme", "dark")
d.setdefault("attribution", {"commit": "", "pr": ""})
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
PY
  say "  seeded $DSD_SET"
fi

# ------------------------------------------------- shared config symlinks ----
# Skills are linked per entry (so a local skill in the profile survives);
# everything else is linked wholesale.
step "Shared config links"
link_shared() {
  local name="$1"
  local src="$CCD_DIR/$name"
  local dst="$PROFILE_DIR/claude/$name"
  if [[ -e "$dst" || -L "$dst" ]]; then
    say "  exists, left alone: $name"
    return
  fi
  if [[ ! -e "$src" ]]; then
    say "  source absent, skipped: $name"
    return
  fi
  if (( DRY_RUN )); then
    say "  would link $name -> $src"
  else
    ln -s "$src" "$dst"
    say "  linked $name"
  fi
}

for shared in commands agents CLAUDE.md plugins; do
  link_shared "$shared"
done

# -------------------------------------------------------------------- sync ----
step "Sync from $CCD_DIR"
if [[ -d "$CCD_DIR" ]]; then
  if (( DRY_RUN )); then
    say "  would run link-ccd-skills.sh and merge-ccd-config.py"
  else
    "$PROFILE_DIR/link-ccd-skills.sh" || say "  skills link failed (non-fatal)"
    "$PROFILE_DIR/merge-ccd-config.py" || say "  config merge failed (non-fatal)"
  fi
else
  say "  source profile absent, skipping"
fi

# ------------------------------------------------------------- disabled list -
if (( ! DRY_RUN )) && [[ -f "$ENV_FILE" ]] && grep -q '^DSD_DISABLED_PLUGINS=' "$ENV_FILE"; then
  python3 - "$DSD_SET" "$ENV_FILE" <<'PY'
import json, sys
set_path, env_path = sys.argv[1], sys.argv[2]
disabled = ""
for line in open(env_path):
    line = line.strip()
    if line.startswith("DSD_DISABLED_PLUGINS="):
        disabled = line.split("=", 1)[1].strip().strip('"').strip("'")
names = [n for n in disabled.split() if n]
if not names:
    sys.exit(0)
d = json.load(open(set_path))
enabled = d.get("enabledPlugins", {})
changed = []
for n in names:
    if enabled.get(n):
        enabled[n] = False
        changed.append(n)
if changed:
    d["enabledPlugins"] = enabled
    json.dump(d, open(set_path, "w"), indent=2, ensure_ascii=False)
    open(set_path, "a").write("\n")
    print("  disabled:", ", ".join(changed))
PY
fi

# ------------------------------------------------------------------ zshrc -----
step "Shell alias"
if [[ -f "$ZSHRC" ]] && grep -qF "$ALIAS_BEGIN" "$ZSHRC"; then
  say "  alias block already present in $ZSHRC"
elif [[ -f "$ZSHRC" ]] && grep -qE "^[[:space:]]*alias[[:space:]]+${ALIAS_NAME}=" "$ZSHRC"; then
  # Already handled by hand. Adding a managed block would duplicate it, and a
  # later duplicate silently wins, so leave the user's own alias alone.
  say "  unmanaged $ALIAS_NAME alias already present in $ZSHRC, not adding a block"
elif (( DRY_RUN )); then
  say "  would append alias block to $ZSHRC"
elif [[ -f "$ZSHRC" ]]; then
  cp "$ZSHRC" "$ZSHRC.before-dsd.$(date +%Y%m%d-%H%M%S)"
  cat >> "$ZSHRC" <<EOF

$ALIAS_BEGIN
alias ccd='claude --dangerously-skip-permissions'
alias $ALIAS_NAME='\$HOME/.local/bin/dsd'
$ALIAS_END
EOF
  say "  appended alias block to $ZSHRC (open a new shell, or use $BIN_DIR/dsd now)"
else
  say "  no $ZSHRC, skipped"
fi

# ------------------------------------------------------------------ finish ----
step "Done"
if (( DRY_RUN )); then
  say "  dry-run complete. Re-run without --dry-run to apply."
  exit 0
fi
say "  key      $KEY_FILE (0600)"
say "  config   $PROFILE_DIR/profile.env (edit model IDs here)"
say "  launch   $BIN_DIR/dsd"
say ""
say "  Next: bash $(printf '%q' "$SCRIPT_DIR/verify.sh")"
say "        then inside dsd: /status  /mcp  /plugin"
say "  Rollback: bootstrap.sh --rollback"
