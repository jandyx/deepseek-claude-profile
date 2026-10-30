---
name: deepseek-migration
description: Migrate an existing Claude Code CLI setup onto an isolated DeepSeek-backed (or any Anthropic-compatible) endpoint profile that reuses the same skills, plugins, commands, agents, hooks, statusline, and MCP servers without sharing credentials. Use when someone wants to run Claude Code against DeepSeek, onboard a teammate to a dual-profile setup, clone a `~/.claude` profile into a provider-isolated one, audit which installed plugins survive a non-Anthropic backend, or roll such a profile back.
---

# DeepSeek migration

Builds a **second Claude Code profile** that talks to `https://api.deepseek.com/anthropic`
while sharing all configuration with the normal profile. Credentials, history,
sessions, and permissions stay isolated; skills, plugins, commands, CLAUDE.md,
hooks, statusline, and MCP definitions are shared.

Two names, used throughout:

| Name | Meaning | Default path |
|---|---|---|
| `ccd` | existing Claude Code profile | `~/.claude` |
| `dsd` | DeepSeek profile being created | `~/.config/deepseek-claude/claude` |

## Why a separate profile at all

`CLAUDE_CONFIG_DIR` is a complete config-namespace switch: settings, sessions,
history, credentials, permissions, and project approvals all move with it. So one
profile can point at Anthropic and another at DeepSeek, with no cross-contamination
of auth state, and nothing leaking into the calling shell.

What is **shared** by symlink or mirror, and what is **isolated**:

| Shared | Isolated |
|---|---|
| `skills/` (per-entry symlink) | credentials / Keychain namespace |
| `plugins/` (whole dir symlink: registry, marketplaces, cache) | history, sessions, project approvals |
| `commands/` | permissions |
| `CLAUDE.md` | model routing, theme, attribution |
| `hooks`, `statusLine` (mirrored into profile settings) | |
| MCP server definitions (mirrored into profile `.claude.json`) | |

Sharing is **not** a filesystem sandbox. Both profiles can read the same workspace,
so the DeepSeek profile can send repository contents to DeepSeek. Say that out loud
before running this on a work machine.

## Before you start

Ask, and do not guess:

1. **Which endpoint and model IDs?** Per the official DeepSeek integration guide the
   defaults are `deepseek-flash[1m]` for the main slot and `deepseek-flash` for the
   small/subagent slot. DeepSeek also maps incoming `claude-*` names server-side:
   `claude-opus*` → `deepseek-v4-pro`, `claude-sonnet*`/`claude-haiku*` →
   `deepseek-flash`. A corporate gateway or relay may use different names, and may or
   may not accept the `[1m]` context suffix. Everything below reads model IDs from
   `profile.env`, so nothing is hardcoded — confirm the real values first.
2. **Is a key already on disk**, or will the user paste one?
3. **Should repo-level `.claude/settings.json` be honoured?** Default here is no
   (`--setting-sources user`), to stop an untrusted repo's hooks and plugins from
   loading under the DeepSeek account. Opt back in with
   `dsd --setting-sources user,project,local` when the repo is trusted.

**Never print, echo, log, or commit the API key.** It is read from a file inside the
launcher and never enters the shell environment of the caller. Do not paste it into
chat, a skill file, or a commit. Same for the MCP env tokens copied by the merge step.

## Procedure

Commands below use `$SKILL_DIR`, the directory containing this file:

```bash
export SKILL_DIR="${SKILL_DIR:-$HOME/.claude/skills/deepseek-migration}"
```

Run these in order. Every step is idempotent; a failed run can be repeated.

### 1. Inventory the source profile

```bash
python3 "$SKILL_DIR/scripts/audit-plugins.py"
```

Reports every enabled plugin as `PORTABLE`, `MODEL-ROUTED`, `PROVIDER-BOUND`, or
`TOOL-RISK`, with the file and line that triggered the verdict. Read it before
enabling anything on the DeepSeek side. `references/compatibility.md` explains what
each verdict means and which Claude Code features have no DeepSeek equivalent.

### 2. Bootstrap the profile

```bash
bash "$SKILL_DIR/scripts/bootstrap.sh" --dry-run
bash "$SKILL_DIR/scripts/bootstrap.sh"
```

Creates, with correct modes (dir `0700`, key `0600`, launchers `0700`):

- `~/.config/deepseek-claude/api-key`
- `~/.config/deepseek-claude/profile.env` — endpoint + model IDs, the only place to edit
- `~/.config/deepseek-claude/claude/` — the profile itself
- `~/.local/bin/deepseek-claude` — launcher, safe permission prompts
- `~/.local/bin/dsd` — same, plus `--dangerously-skip-permissions`
- `link-ccd-skills.sh`, `merge-ccd-config.py` — sync helpers, re-run on every launch
- a marked alias block in `~/.zshrc` (alias name via `DSD_ALIAS`, default `dsd`)

Pass `--force` only to replace an existing launcher; without it an existing launcher is
left alone and a `.new` file is written for diffing. That protects a working setup.

### 3. Confirm what got shared

```bash
bash "$SKILL_DIR/scripts/verify.sh"
```

Checks modes, link counts, JSON validity, and that hooks/statusLine/MCP actually
landed in the profile. Then `verify.sh --live` makes one real API call through the
profile, which is the only check that proves the endpoint and model IDs are right.

### 4. Migrate plugins

Plugins need no reinstall — `plugins/` is a directory symlink into the shared
`~/.claude/plugins`, so the registry, marketplaces, and cache are the same objects.
What must be mirrored is the **enablement**, which `merge-ccd-config.py` does by
copying `enabledPlugins` and `extraKnownMarketplaces` into the profile's
`settings.json` on every launch.

After the first launch, inside `dsd`:

```
/plugin          # confirm the list matches ccd
/mcp             # confirm servers are present; re-auth OAuth ones
/status          # confirm model + endpoint
```

OAuth logins are deliberately **not** copied. Each OAuth MCP server (GitHub, Notion,
Linear, Sentry, …) needs one manual `/mcp` re-auth in the new profile. Say so up front
so nobody reads the empty auth state as a broken migration.

Rules for the audit verdicts:

- `PORTABLE` — enable as-is. Markdown skills, commands, LSP plugins, statuslines, and
  hooks that only shell out locally.
- `MODEL-ROUTED` — enable, then spot-check. Agent files pinning `model: opus|sonnet|haiku`
  are remapped through `ANTHROPIC_DEFAULT_*_MODEL`, so they run on whatever tier you
  configured. Tier *semantics* change even when the plumbing works: an "Opus" reviewer
  may now be the same model as everything else. Quality assumptions in those prompts
  no longer hold automatically.
- `PROVIDER-BOUND` — disable unless verified. Anything calling `api.anthropic.com` or
  the Anthropic SDK directly bypasses the profile entirely and will either fail or
  bill the wrong account.
- `TOOL-RISK` — enable only after testing the specific tool. Web search server tools,
  image input, and thinking-budget controls are the usual casualties.

To disable one without touching the shared profile:

```bash
claude plugins disable <plugin>@<marketplace>   # run inside dsd
```

That writes to the profile's `settings.json`, but `merge-ccd-config.py` re-copies
`enabledPlugins` from ccd on every launch and will undo it. For a permanent
difference, add the plugin to `DISABLED_PLUGINS` in the profile's `profile.env`
(exposed as `DSD_DISABLED_PLUGINS`), or drop the plugin from ccd's `enabledPlugins`.

### 5. Pin the model IDs

Edit `~/.config/deepseek-claude/profile.env`. Defaults the launcher understands:

```sh
DSD_BASE_URL=https://api.deepseek.com/anthropic
DSD_MAIN_MODEL=deepseek-flash[1m]   # opus / sonnet / fable slots
DSD_SMALL_MODEL=deepseek-flash      # haiku slot + subagents
DSD_EFFORT_LEVEL=high
DSD_AUTO_COMPACT_WINDOW=786432
```

Append `[1m]` to a model ID only if the endpoint advertises a 1M-token window and
accepts the suffix. If requests 400 on the model name, drop the suffix first — that is
the most common misconfiguration.

### 6. Hand over, with the guardrails

Tell the user explicitly:

- Billing is DeepSeek's, not the Claude subscription. Both profiles can be used on the
  same machine, but they are different bills.
- Isolation is configuration, not security. Same filesystem, same workspace.
- `--setting-sources user` is what keeps repo-level hooks and plugins out. Changing it
  widens the trust boundary.
- Rotate the key by replacing `api-key` only, keeping mode `0600`.
- `~/.config/deepseek-claude/` contains the key and mirrored MCP tokens. Never commit,
  sync, or share it.

### 7. Rollback

Delete the launchers and the profile directory, and remove only the marked alias block
from `~/.zshrc`. `bootstrap.sh --rollback` does exactly this.

Do **not** restore a whole `zshrc` backup — unrelated edits made since will be lost.
The current setup keeps dated backups under `backups/` for reference only.

## Driving it from a fresh machine

Greenfield, no existing `~/.claude`, works too. `bootstrap.sh` tolerates a missing
source profile: the link and merge helpers no-op, and the user gets an empty but
functional DeepSeek profile to build up from `claude plugins marketplace add …`.
