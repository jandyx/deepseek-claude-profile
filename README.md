# DeepSeek × Claude Code

Run Claude Code against DeepSeek in a **separate profile** that reuses everything you
already have — skills, plugins, slash commands, `CLAUDE.md`, hooks, status line, MCP
servers — while keeping credentials, history and billing isolated.

Two commands side by side on one machine:

```bash
ccd    # Claude Code, Anthropic account
dsd    # Claude Code, DeepSeek account — same skills, same plugins, different bill
```

No reinstalling plugins. No rebuilding your setup. No risk of the DeepSeek session
quietly authenticating as your Claude subscription.

---

## Quick start — hand it to an agent

Open Claude Code and paste this. Replace the key. That is the whole setup.

```text
Set up a DeepSeek-backed Claude Code profile on this machine.

Repository: https://github.com/jandyx/deepseek-claude-profile
DeepSeek API key: sk-<paste yours here>
Alias to launch it: dsd
Models: deepseek-flash[1m] (main), deepseek-flash (small)

Steps:
1. Copy skills/deepseek-migration from the repo into ~/.claude/skills/.
2. Run scripts/bootstrap.sh --dry-run, show me the plan, then run it for real.
3. Run scripts/verify.sh --live and paste the output.
4. Run scripts/audit-plugins.py and list everything that is not PORTABLE.
   Do not disable any plugin yet.

Rules:
- Never print the API key back to me, and never write it into a file in a repo.
- ~/.config/deepseek-claude must stay mode 0700, the key file 0600.
- Do not touch my existing ~/.claude configuration.
```

The agent installs the skill, builds the profile, verifies it with a real API call, and
reports which plugins need attention. Roughly two minutes.

**Do not want to paste a key into chat?** Swap the key line for:

```text
DeepSeek API key: I will paste it when prompted.
```

The bootstrap script reads it with a hidden prompt and never echoes it.

### 中文速览

把上面的 prompt 复制进 Claude Code，填上 DeepSeek 的 API key 和想要的启动别名，
agent 会自己装 skill、建 profile、跑真实请求验证，最后列出需要处理的插件。
整个流程约两分钟，不会动你现有的 `~/.claude`。

---

## Install the skill manually

```bash
git clone https://github.com/jandyx/deepseek-claude-profile.git
cd deepseek-claude-profile
./install.sh              # symlinks the skill into ~/.claude/skills/
```

Or copy it:

```bash
cp -R skills/deepseek-migration ~/.claude/skills/
```

Then, from any Claude Code session:

```
/deepseek-migration
```

or just describe the goal — *"migrate my Claude Code setup to DeepSeek"* — and the skill
loads on its own.

---

## What it actually does

Claude Code reads its entire configuration from `$CLAUDE_CONFIG_DIR`. Point that at a
second directory and you get a second, fully independent profile. This tool builds that
directory and then wires the two together:

| Shared with your existing profile | Isolated |
|---|---|
| `skills/` — one symlink per skill | credentials / Keychain namespace |
| `plugins/` — registry, marketplaces, cache | history, sessions |
| `commands/`, `agents/`, `CLAUDE.md` | project approvals, permissions |
| `hooks`, `statusLine`, `enabledPlugins` (mirrored) | model routing, theme, attribution |
| MCP server definitions (mirrored) | billing |

Everything is re-synced from the source profile on **every launch**, so a plugin you add
or an MCP server you edit on the Claude side shows up in the DeepSeek side next time you
start it. All steps are idempotent.

### Files it creates

```
~/.config/deepseek-claude/
├── api-key                 0600, the only place the key lives
├── profile.env             0600, endpoint + model IDs — the one file you edit
├── claude/                 the profile itself (CLAUDE_CONFIG_DIR)
├── link-ccd-skills.sh      per-skill symlinks, idempotent
└── merge-ccd-config.py     mirrors hooks / statusLine / plugins / MCP

~/.local/bin/deepseek-claude   safe permission prompts
~/.local/bin/dsd               same, plus --dangerously-skip-permissions
```

---

## Daily use

```bash
dsd                      # start DeepSeek profile
cd ~/code/project && dsd # start it in a project

dsd --setting-sources user,project,local   # also load the repo's own settings
```

By default the launcher passes `--setting-sources user`, which deliberately ignores
repository-level `.claude/settings.json`, hooks and plugins. That stops an untrusted repo
from executing code under a different billing account. Repo `CLAUDE.md` still applies.
Opt in only for repos you trust.

### Change the model

```bash
$EDITOR ~/.config/deepseek-claude/profile.env
```

```sh
DSD_BASE_URL=https://api.deepseek.com/anthropic
DSD_MAIN_MODEL=deepseek-flash[1m]   # opus / sonnet / fable slots
DSD_SMALL_MODEL=deepseek-flash      # haiku slot + subagents
DSD_EFFORT_LEVEL=high
DSD_AUTO_COMPACT_WINDOW=786432
```

Values match the official [DeepSeek Claude Code guide](https://api-docs.deepseek.com/zh-cn/quick_start/agent_integrations/claude_code),
except `DSD_EFFORT_LEVEL`, which defaults to `high` instead of the guide's `max` — `max`
burns noticeably more reasoning tokens per turn, and that lands on your bill.

### Rotate the key

Replace `~/.config/deepseek-claude/api-key`, keep mode `0600`. Nothing else changes.

---

## Plugin migration

Plugins are not reinstalled. `plugins/` is a symlink into your existing
`~/.claude/plugins`, so registry, marketplaces and cache are the same objects.
`enabledPlugins` and `extraKnownMarketplaces` are mirrored into the profile on each
launch. OAuth logins are **not** copied — re-auth each OAuth MCP server once with `/mcp`.

Before trusting the new profile, run the audit:

```bash
python3 ~/.claude/skills/deepseek-migration/scripts/audit-plugins.py
```

| Verdict | Meaning | Action |
|---|---|---|
| `PROVIDER-BOUND` | Calls `api.anthropic.com` directly | Disable — it bypasses the profile and can bill the wrong account |
| `TOOL-RISK` | Uses web search, fetch, image input or thinking budgets | Test that tool; cost differs, image input does not work |
| `MODEL-ROUTED` | Pins `model: opus/sonnet/haiku` | Works via env mapping, but the tier may collapse — spot-check quality |
| `PORTABLE` | Markdown, commands, LSP servers, local hooks | Enable as-is |

Each finding includes `file:line` evidence. Full feature-by-feature comparison lives in
[`references/compatibility.md`](skills/deepseek-migration/references/compatibility.md).

---

## Verify

```bash
bash ~/.claude/skills/deepseek-migration/scripts/verify.sh --live
```

```
Profile          dir 0700, key 0600
Launchers        both executable
Profile settings hooks, statusLine, enabledPlugins, MCP
Shared config    skills linked N/N, commands, CLAUDE.md
Endpoint         base / main / small
Live call        http 200, model deepseek-flash[1m], reply OK
9 passed, 0 failed, 0 warnings
```

`--live` makes one 128-token request. That single check proves endpoint, key and model
ID all work — the three things that go wrong.

---

## Rollback

```bash
bash ~/.claude/skills/deepseek-migration/scripts/bootstrap.sh --rollback
```

Removes the two launchers, the profile directory, and the marked alias block from
`~/.zshrc`. It does **not** restore a whole zshrc backup — unrelated edits made since
would be lost.

---

## Security

- The profile directory holds the API key and mirrored MCP tokens. Never commit, sync or
  share it. Directory `0700`, key `0600`, enforced by the scripts.
- Configuration isolation is **not** a sandbox. Both profiles see the same filesystem, so
  the DeepSeek profile can send workspace contents to DeepSeek. Decide per repository.
- The launcher unsets every inherited `ANTHROPIC_*`, `CLAUDE_CODE_USE_*` and
  `CLAUDE_SECURESTORAGE_CONFIG_DIR` before exporting its own, so a Claude subscription
  session in the parent shell cannot leak into the DeepSeek one.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` stops telemetry and non-essential calls
  that would still target Anthropic endpoints.
- Repo settings and plugins are skipped by default (`--setting-sources user`). Changing
  that widens the trust boundary.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `400 model not found` | Wrong model ID, or the gateway rejects `[1m]` | Edit `profile.env`; drop the suffix first |
| `401` / invalid token | Empty key file, or an inherited token | Check `api-key` mode and contents |
| `[claude-code:unrecognized_model]` | Claude Code does not know third-party IDs | Cosmetic, ignore |
| Reported cost looks absurd | Claude Code prices unknown models against an Anthropic table | Trust the DeepSeek console, not the HUD |
| Empty content with HTTP 200 | A `thinking` block ate the `max_tokens` budget | Raise `max_tokens` |
| Every turn slow and expensive | Prompt caching is not honoured by the endpoint | Lower `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, compact sooner |
| Plugins installed but commands missing | `enabledPlugins` not mirrored | Re-run `merge-ccd-config.py` |
| MCP servers show but error | OAuth not re-established in this profile | `/mcp` and log in |

Full table: [`references/compatibility.md`](skills/deepseek-migration/references/compatibility.md).

---

## Requirements

- Claude Code (`claude --version`) — `npm i -g @anthropic-ai/claude-code` or Homebrew
- `python3` for the merge and audit steps
- A DeepSeek API key ([platform.deepseek.com](https://platform.deepseek.com))
- Bash, macOS or Linux. Windows: use WSL — the launchers are bash.

An existing Claude Code setup is optional. With no `~/.claude`, the sync steps no-op and
you get an empty but working DeepSeek profile.

---

## Layout

```
skills/deepseek-migration/
├── SKILL.md                    the agent-facing procedure
├── scripts/
│   ├── bootstrap.sh            build / update / rollback the profile
│   ├── link-ccd-skills.sh      per-skill symlinks
│   ├── merge-ccd-config.py     mirror hooks, statusLine, plugins, MCP
│   ├── audit-plugins.py        plugin compatibility verdicts
│   └── verify.sh               post-migration checks, --live
└── references/
    └── compatibility.md        feature matrix, verdicts, troubleshooting
```

## License

MIT — see [LICENSE](LICENSE).
