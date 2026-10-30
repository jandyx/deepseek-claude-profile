# Compatibility reference

What survives a switch from Anthropic to DeepSeek (or any Anthropic-compatible
gateway), what degrades, and what to check when something looks wrong.

Claude Code talks the Anthropic Messages API. A compatible gateway implements
`POST /v1/messages` and accepts the same tool-use envelope. That is enough for the
agent loop, file tools, Bash, MCP, skills, and hooks — the parts of Claude Code that
are client-side. Anything that relies on a **server-side Anthropic feature** is where
breakage concentrates.

Treat every row below as "verify on your gateway", not as a guarantee. A corporate
relay may forward features that the public DeepSeek API does not have.

## Feature matrix

| Feature | Under a non-Anthropic endpoint | Impact |
|---|---|---|
| Agent loop, tool use, file edits, Bash | Works — implemented by the client | None |
| Skills, commands, agents, hooks, statusline, MCP (stdio/HTTP) | Works — client-side | None |
| Prompt caching (`cache_control`) | Usually ignored or silently unmapped | No cache read/write counters; every turn re-bills full context. Raise `CLAUDE_CODE_AUTO_COMPACT_WINDOW` or compact manually |
| Extended thinking / `budget_tokens` | Reasoning models exist, but the block format and budget controls are provider-specific | Thinking indicators may vanish; `effort` and thinking-budget settings may be no-ops |
| Web search server tool (`web_search_20xxxxxx`) | **Supported.** DeepSeek proxies Claude Code web search through its own Search API | Works, and costs extra: one Search API call plus extra model tokens for summarising results. If a gateway does not proxy it, fall back to an MCP search server |
| `WebFetch` | Depends on the build; DeepSeek also exposes a fetch API | Verify once per build; have an MCP fetch fallback |
| Image / screenshot input | Public DeepSeek chat models are text-only | Pasted screenshots fail. Route visual work to the Claude profile |
| PDF / Files API, Batch API | Anthropic-only | Not usable |
| 1M context suffix `[1m]` | Depends on the gateway; some reject the literal model name | If you get a 400 on the model, drop the suffix first |
| Token counting endpoint | May be absent | Status line token counts can be approximate |
| OAuth-based MCP servers | Unrelated to the provider, but logins are **not** copied between profiles | Manual `/mcp` re-auth per server |

## Model tier routing

Claude Code maps its internal tiers through environment variables:

| Variable | Fills |
|---|---|
| `ANTHROPIC_MODEL` | main loop |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | anything pinning `model: opus` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | anything pinning `model: sonnet` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | background tasks, small jobs |
| `ANTHROPIC_DEFAULT_FABLE_MODEL` | newer tier alias; harmless if unsupported |
| `CLAUDE_CODE_SUBAGENT_MODEL` | subagents that do not pin a model |

DeepSeek additionally maps **incoming `claude-*` names server-side**:

| Incoming model name | Served as |
|---|---|
| `claude-opus*` | `deepseek-v4-pro` (billed at V4 Pro rates) |
| `claude-sonnet*`, `claude-haiku*` | `deepseek-flash` |

Two ways to get tier behaviour, and they are not equivalent:

- **Explicit override** (what `profile.env` does by default). Every slot is pinned to
  `deepseek-flash[1m]` / `deepseek-flash`, so an agent file saying `model: opus` gets
  the flash model. Cheap and predictable, but the plugin's tier design collapses —
  prompts written assuming a stronger reviewer get the same model as everything else.
- **Let the server map.** Leave `ANTHROPIC_DEFAULT_OPUS_MODEL` unset, or point it at a
  `claude-opus*` name, and DeepSeek upgrades it to `deepseek-v4-pro` for you. This is
  the only configuration where `model: opus` still means something stronger. It also
  bills at pro rates for every agent that pins opus.

Pick deliberately. The default here favours cost; teams that need the old tier
gradient should point `DSD_MAIN_MODEL` at a pro model, or split the main and small
slots.

## Deliberate deviations from the official guide

The official guide sets `CLAUDE_CODE_EFFORT_LEVEL=max`. This tool defaults to `high`
instead: `max` spends noticeably more reasoning tokens per turn, and on a metered
third-party endpoint that shows up directly on the bill. It is one line in
`profile.env` if a team wants the guide's value back.

Also set here but absent from the guide:

| Variable | Why |
|---|---|
| `ANTHROPIC_DEFAULT_FABLE_MODEL` | newer Claude Code tier alias; harmless when unused, keeps `model: fable` agents mapped like opus |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | stops telemetry and non-essential calls that would otherwise still target Anthropic endpoints |

## Plugin verdicts

`audit-plugins.py` sorts enabled plugins into four buckets. What to do with each:

### PORTABLE
Markdown skills, commands, LSP servers, statusline scripts, and hooks that only shell
out locally. Nothing talks to a model directly. Enable as-is.

LSP plugins (`clangd`, `gopls`, `swift`, `kotlin`, …) are pure client-side language
servers — they are the most reliable category of all and should just be enabled.

### MODEL-ROUTED
The plugin pins model tiers, or reads model env vars itself. The plumbing works
through the mapping table above. What changes is the **quality assumption** baked into
prompts: an "Opus architect" that was meant to be the strongest available model is now
just another call to the same endpoint.

Spot-check after enabling: run one command from the plugin, read the output, and ask
whether it is at the level the plugin's prompts assume. If not, either put a stronger
model in that slot or disable the plugin.

Watch for plugins that spawn their own agent runtimes (memory servers, background
compactors, review bots). They may construct their own client and read
`ANTHROPIC_API_KEY` / an SDK default rather than inheriting the profile, which puts
them in the next category even if the manifest looks harmless.

### PROVIDER-BOUND
Calls `api.anthropic.com` or bundles `@anthropic-ai/sdk` directly. These bypass the
profile entirely. Two failure modes, both bad: it errors out, or it **succeeds and
bills the Anthropic account you were trying not to use**.

Disable by default. Re-enable only after reading the call site and confirming it
honours the base URL. If it needs Anthropic, run it in the Claude profile.

### TOOL-RISK
References web search server tools, `WebFetch`, image content, or thinking budgets.
The plugin's core logic is fine; the risk is concentrated in the one tool it calls.

Enable, then test that specific tool. Web search and fetch are **supported** and
billed separately — the failure mode there is cost, not breakage. Image input is the
one that genuinely does not work on a text-only model. If a gateway turns out not to
proxy search, an MCP search server is the substitute.

## MCP servers

Server definitions are copied from the source profile into the profile's
`.claude.json`. Two things are deliberately not copied:

1. **OAuth logins.** Re-auth with `/mcp` once per server.
2. **Anything project-scoped outside a known project path.** Add it manually if needed.

stdio servers (`npx …`, `docker run …`) work unchanged. Remote HTTP servers work if
the gateway passes tool results through untouched — they normally do, since the client
sits between the model and the server.

Servers that read provider credentials from the environment will see the DeepSeek
profile's values. That is usually what you want, but check any server whose auth is
model-provider auth rather than its own.

## Hooks and status line

Hooks are plain shell commands. They run under the profile's environment, so:

- A hook that reads `ANTHROPIC_API_KEY` will now get a DeepSeek key, or nothing.
- A hook that makes an Anthropic API call directly (rather than through Claude Code)
  will fail or bill the wrong account.
- Local-only hooks — notification bells, terminal title updates, graph lookups, log
  appenders — are unaffected.

The status line is a command with the same caveats. Status lines that render cost or
token counts will show wrong or empty numbers if the gateway does not report usage in
the Anthropic shape. That is cosmetic; do not chase it.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `400 model not found` | Model ID wrong for this gateway, or an unsupported `[1m]` suffix | Edit `profile.env`; drop the suffix first |
| `401` / `invalid token` | Key file empty, wrong key, or a stale `ANTHROPIC_AUTH_TOKEN` inherited from the parent shell | Launcher unsets `ANTHROPIC_*` before exporting; check `api-key` mode and content |
| Works, but usage/billing shows on Anthropic | `ANTHROPIC_BASE_URL` not applied, or a plugin calling Anthropic directly | Run `/status`; then `audit-plugins.py` for `PROVIDER-BOUND` |
| Model claims to be a Claude model | Plugin prompt text says so and the model parrots it; harmless | Ignore, or edit the plugin's prompt |
| Every turn is slow and expensive | Prompt caching not honoured | Lower `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, compact sooner, shorten CLAUDE.md |
| Plugins appear installed but commands missing | `enabledPlugins` not mirrored, or the plugins dir is not shared | Re-run `merge-ccd-config.py`, check the `plugins` symlink in `verify.sh` |
| Skills missing in the new profile | Link step skipped, or the skill dir was created after the last launch | Run `link-ccd-skills.sh` |
| `/mcp` shows servers but they error | OAuth not re-established in this profile | `/mcp` and log in per server |
| `/mcp` is empty in the new profile but populated in the old one | The merge read `~/.claude/.claude.json`, which is often a stale, empty legacy file | User-scope config really lives at `~/.claude.json`, or `$CLAUDE_CONFIG_DIR/.claude.json` when the variable is set. Re-run `merge-ccd-config.py` |
| Screenshots or pasted images fail | Text-only model | Use the Claude profile for image work |
| API returns 200 but content is empty | A `thinking` block consumed the whole `max_tokens` budget before any text block | Raise `max_tokens`. Reasoning builds emit `thinking` first; 16 tokens is nowhere near enough |
| Startup prints `[claude-code:unrecognized_model]` | Claude Code does not recognise a third-party model id | Cosmetic. Ignore it, or silence it by pinning a `claude-*` name and letting DeepSeek map it |
| Reported session cost looks absurd (e.g. $0.14 for one short turn) | Claude Code prices unknown models against an Anthropic table; `costBasis` comes back `unknown` | Treat cost and HUD spend numbers as fiction on this profile. Use the DeepSeek platform console for real billing |
| Repo's own hooks/settings not loading | `--setting-sources user` is intentional | `dsd --setting-sources user,project,local` for trusted repos |
| Profile settings get overwritten mid-session | A running session rewrote `.claude.json` | Re-run `merge-ccd-config.py`; it is idempotent and designed for this |

## Security notes

- The profile directory holds the API key and mirrored MCP tokens. Never commit,
  sync, or share it. Keep it `0700`, key `0600`.
- Configuration isolation is **not** a sandbox. Both profiles see the same
  filesystem, so the DeepSeek profile can send workspace contents to DeepSeek. Decide
  per repository whether that is acceptable.
- Repo-level `.claude/settings.json` and plugins are skipped by default precisely
  because an untrusted repository could otherwise execute hooks under a different
  billing account.
- Rotating the key means replacing `api-key` only, preserving mode `0600`. Nothing
  else in the profile needs to change.
