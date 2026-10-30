#!/bin/bash
# Post-migration checks for the DeepSeek Claude Code profile.
# Read-only: never writes, never prints the API key.
#
#   verify.sh           local checks only
#   verify.sh --live    also make one real /v1/messages call
set -uo pipefail

PROFILE_DIR="${DSD_PROFILE_DIR:-$HOME/.config/deepseek-claude}"
CCD_DIR="${CCD_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${DSD_BIN_DIR:-$HOME/.local/bin}"
LIVE=0
[[ "${1:-}" == "--live" ]] && LIVE=1

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mwarn\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

perm() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

head_ "Profile"
if [[ -d "$PROFILE_DIR" ]]; then
  p=$(perm "$PROFILE_DIR")
  [[ "$p" == "700" ]] && ok "profile dir mode $p" || bad "profile dir mode $p, expected 700"
else
  bad "profile dir missing: $PROFILE_DIR"
fi

if [[ -s "$PROFILE_DIR/api-key" ]]; then
  p=$(perm "$PROFILE_DIR/api-key")
  [[ "$p" == "600" ]] && ok "api-key mode $p, non-empty" || bad "api-key mode $p, expected 600"
else
  bad "api-key missing or empty"
fi

if [[ -f "$PROFILE_DIR/profile.env" ]]; then
  ok "profile.env present"
elif grep -qs 'profile\.env' "$BIN_DIR/deepseek-claude" 2>/dev/null; then
  warn "launcher reads profile.env but the file is missing; it will use hardcoded defaults"
else
  ok "launcher carries its own settings (no profile.env), nothing to check"
fi

head_ "Launchers"
for f in deepseek-claude dsd; do
  if [[ -x "$BIN_DIR/$f" ]]; then ok "$BIN_DIR/$f executable"
  else bad "$BIN_DIR/$f missing or not executable"; fi
done

head_ "Profile settings"
python3 - "$PROFILE_DIR/claude/settings.json" "$PROFILE_DIR/claude/.claude.json" <<'PY'
import json, sys
fail = 0
set_path, cfg_path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(set_path))
except Exception as e:
    print(f"  FAIL settings.json unreadable: {e}"); sys.exit(1)
for key in ("hooks", "statusLine", "enabledPlugins"):
    if d.get(key):
        print(f"  ok   settings.{key} present")
    else:
        print(f"  warn settings.{key} empty")
if any(d.get("enabledPlugins", {}).values()) and "extraKnownMarketplaces" not in d:
    print("  warn extraKnownMarketplaces absent; plugin reinstall may fail")
try:
    c = json.load(open(cfg_path))
    n = len(c.get("mcpServers", {}))
    print(f"  ok   .claude.json valid, {n} user MCP server(s)")
except Exception as e:
    print(f"  FAIL .claude.json unreadable: {e}"); sys.exit(1)
PY

head_ "Shared config"
src_skills="$CCD_DIR/skills"
dst_skills="$PROFILE_DIR/claude/skills"
if [[ -d "$src_skills" && -d "$dst_skills" ]]; then
  want=$(find "$src_skills" -mindepth 1 -maxdepth 1 ! -name '.*' ! -name synced | wc -l | tr -d ' ')
  got=$(find "$dst_skills" -mindepth 1 -maxdepth 1 -type l | wc -l | tr -d ' ')
  [[ "$got" -ge "$want" ]] && ok "skills linked $got/$want" || warn "skills linked $got/$want, re-run link-ccd-skills.sh"
else
  warn "skills dir missing on one side"
fi

for pair in "commands:$CCD_DIR/commands" "CLAUDE.md:$CCD_DIR/CLAUDE.md"; do
  name="${pair%%:*}"; src="${pair#*:}"
  dst="$PROFILE_DIR/claude/$name"
  if [[ -e "$src" ]]; then
    [[ -L "$dst" ]] && ok "$name symlinked" || warn "$name not a symlink"
  fi
done

if [[ -L "$PROFILE_DIR/claude/plugins" ]]; then
  ok "plugins dir symlinked (registry + marketplaces + cache shared)"
elif [[ -d "$PROFILE_DIR/claude/plugins" ]]; then
  warn "plugins dir is a real directory, not shared"
else
  warn "no plugins dir in profile"
fi

head_ "Endpoint"
if [[ -f "$PROFILE_DIR/profile.env" ]]; then
  # shellcheck disable=SC1091
  ( set +u; . "$PROFILE_DIR/profile.env"
    printf '  base  %s\n  main  %s\n  small %s\n' \
      "${DSD_BASE_URL:-unset}" "${DSD_MAIN_MODEL:-unset}" "${DSD_SMALL_MODEL:-unset}" )
fi

if (( LIVE )); then
  head_ "Live call"
  if [[ ! -s "$PROFILE_DIR/api-key" ]]; then
    bad "no key, skipping live call"
  else
    # shellcheck disable=SC1091
    ( set +u; . "$PROFILE_DIR/profile.env" 2>/dev/null || true
      base="${DSD_BASE_URL:-https://api.deepseek.com/anthropic}"
      model="${DSD_MAIN_MODEL:-deepseek-flash[1m]}"
      key="$(cat "$PROFILE_DIR/api-key")"
      # 128, not 16: reasoning builds emit a thinking block before the text block,
      # and a tiny budget gets spent entirely on thinking, returning empty text.
      body=$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"max_tokens":128,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}))' "$model")
      out=$(curl -sS -m 45 -o /tmp/dsd-verify.$$ -w '%{http_code}' \
        "$base/v1/messages" \
        -H 'content-type: application/json' \
        -H 'anthropic-version: 2023-06-01' \
        -H "authorization: Bearer $key" \
        -H "x-api-key: $key" \
        -d "$body" 2>&1) || true
      printf '  http  %s\n' "$out"
      if [[ "$out" == "200" ]]; then
        python3 - /tmp/dsd-verify.$$ <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  warn unparsable response: {e}")
    sys.exit(0)
print(f"  model {d.get('model', '?')}")
blocks = d.get("content") or []
text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict))
print(f"  reply {text.strip()[:80] or '(empty)'}")
PY
      else
        printf '  body  %s\n' "$(head -c 400 /tmp/dsd-verify.$$ 2>/dev/null)"
      fi
      rm -f /tmp/dsd-verify.$$
    )
  fi
  printf '  note  CLI-side check: run `dsd`, then /status and /mcp inside the session\n'
fi

printf '\n%d passed, %d failed, %d warnings\n' "$PASS" "$FAIL" "$WARN"
[[ "$FAIL" -eq 0 ]]
