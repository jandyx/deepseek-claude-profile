#!/usr/bin/env python3
"""Audit installed Claude Code plugins for portability to a non-Anthropic endpoint.

Reads the enabled-plugin list from the source profile's settings.json and each
plugin's install path from plugins/installed_plugins.json, then scans the plugin
contents for signals that do not survive a switch to DeepSeek or any other
Anthropic-compatible gateway.

Verdicts, most severe first:

  PROVIDER-BOUND  calls api.anthropic.com or bundles the Anthropic SDK directly.
                  Bypasses the profile: fails, or bills the wrong account.
  TOOL-RISK       depends on a tool the endpoint may not implement: web search
                  server tool, WebFetch, image input, thinking budgets.
  MODEL-ROUTED    pins model tiers (opus/sonnet/haiku) or reads model env vars.
                  Plumbing works through ANTHROPIC_DEFAULT_*_MODEL, but tier
                  semantics change; spot-check output quality.
  PORTABLE        markdown, commands, LSP servers, local shell hooks.

Usage:
  audit-plugins.py [--all] [--json]

  --all   scan every installed plugin, not just the enabled ones

Environment:
  CCD_CONFIG_DIR   source profile, default ~/.claude
"""
import argparse
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
CCD_HOME = os.environ.get("CCD_CONFIG_DIR", os.path.join(HOME, ".claude"))
PLUGINS_DIR = os.path.join(CCD_HOME, "plugins")

SKIP_DIRS = {
    "node_modules", ".git", ".hg", "dist", "build", "out", "vendor",
    "coverage", ".next", ".cache", "__pycache__", "target",
    # Not shipped behaviour: examples, fixtures, and test suites never run
    # in a session, and they are full of illustrative call sites that would
    # otherwise dominate the verdicts.
    "tests", "test", "__tests__", "examples", "example", "docs", "fixtures",
}
TEXT_EXT = {
    ".md", ".json", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py",
    ".sh", ".bash", ".zsh", ".toml", ".yaml", ".yml", ".txt", ".mdx",
}
# Only real code can bind a plugin to a provider. A markdown explainer that
# mentions api.anthropic.com is documentation, not a call site.
CODE_EXT = {".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".py", ".sh", ".bash", ".zsh"}
# Dependency manifests declare the SDK without ever calling it.
MANIFESTS = {"package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"}
MAX_FILES = 2000
MAX_BYTES = 256 * 1024

PROVIDER_RE = re.compile(r"(api\.anthropic\.com|@anthropic-ai/|anthropic\.com/v1)")
TOOL_RE = re.compile(
    r"(web_search_20\d{6}|\bWebSearch\b|\bWebFetch\b|budget_tokens|image_url|\"type\"\s*:\s*\"image\")"
)
MODEL_RE = re.compile(
    r"^\s*model\s*:\s*(opus|sonnet|haiku|inherit)\s*$|ANTHROPIC_MODEL|CLAUDE_CODE_SUBAGENT_MODEL",
    re.M,
)

VERDICT_ORDER = ["PROVIDER-BOUND", "TOOL-RISK", "MODEL-ROUTED", "PORTABLE"]
ACTION = {
    "PROVIDER-BOUND": "disable unless you have verified it works against the gateway",
    "TOOL-RISK": "enable, then test the specific tool before relying on it",
    "MODEL-ROUTED": "enable, then spot-check output quality on the new tier",
    "PORTABLE": "enable as-is",
    "UNKNOWN": "verify manually — enabled but not resolvable in this profile",
    "BUILTIN": "nothing to migrate, shipped with the CLI",
}


def load_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def iter_text_files(root):
    """Yield (path, text) deterministically, shallow paths first.

    Sorting dirnames keeps repeated runs comparable, and walking in sorted order
    means the file cap trims the deepest, least relevant files rather than
    randomly truncating the plugin's own source.
    """
    seen = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(
            d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")
        )
        for name in sorted(filenames):
            ext = os.path.splitext(name)[1].lower()
            if ext not in TEXT_EXT:
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getsize(path) > MAX_BYTES:
                    continue
                with open(path, "r", errors="ignore") as f:
                    yield path, ext, f.read()
            except OSError:
                continue
            seen += 1
            if seen >= MAX_FILES:
                return


def scan(path):
    hits = {"PROVIDER-BOUND": [], "TOOL-RISK": [], "MODEL-ROUTED": []}
    extras = []
    for file_path, ext, text in iter_text_files(path):
        rel = os.path.relpath(file_path, path)
        base = os.path.basename(file_path)
        is_code = ext in CODE_EXT
        is_manifest = base in MANIFESTS
        is_agent = "/agents/" in os.path.join("/", rel) or rel.startswith("agents/")

        if is_code and not is_manifest:
            m = PROVIDER_RE.search(text)
            if m:
                hits["PROVIDER-BOUND"].append(_hit(rel, text, m))
        elif is_manifest and PROVIDER_RE.search(text):
            extras.append(f"{rel} declares an Anthropic SDK dependency; check the call sites")

        if is_code:
            m = TOOL_RE.search(text)
            if m:
                hits["TOOL-RISK"].append(_hit(rel, text, m))

        if is_agent:
            m = MODEL_RE.search(text)
            if m:
                hits["MODEL-ROUTED"].append(_hit(rel, text, m))

    if os.path.isfile(os.path.join(path, ".mcp.json")):
        extras.append("ships an MCP server; re-auth with /mcp if it uses OAuth")
    return hits, extras


def _hit(rel, text, match):
    line_no = text.count("\n", 0, match.start()) + 1
    return f"{rel}:{line_no} {match.group(0).strip()[:48]}"


def resolve_plugins(installed, all_plugins):
    enabled = {}
    settings = load_json(os.path.join(CCD_HOME, "settings.json"), {}) or {}
    enabled = settings.get("enabledPlugins", {}) or {}

    entries = installed.get("plugins", {}) if installed else {}
    out = []
    for key, records in entries.items():
        if not all_plugins and not enabled.get(key):
            continue
        user = [r for r in records if r.get("scope") == "user"] or records
        path = user[0].get("installPath")
        if path and os.path.isdir(path):
            out.append((key, user[0].get("version", "?"), path))

    if not all_plugins:
        missing = [k for k, v in enabled.items() if v and k not in entries]
        for key in missing:
            out.append((key, "?", None))
    return sorted(out, key=lambda r: r[0].lower())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--all", action="store_true", help="scan every installed plugin")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    installed = load_json(os.path.join(PLUGINS_DIR, "installed_plugins.json"))
    if installed is None:
        print(f"no plugin registry at {PLUGINS_DIR}/installed_plugins.json", file=sys.stderr)
        return 1

    plugins = resolve_plugins(installed, args.all)
    if not plugins:
        print("no enabled plugins found", file=sys.stderr)
        return 0

    results = []
    for key, version, path in plugins:
        if path is None:
            if key.endswith("@builtin"):
                verdict, reasons = "BUILTIN", ["ships with the CLI, nothing to migrate"]
            else:
                verdict, reasons = "UNKNOWN", ["enabled but not installed in this profile"]
            results.append(
                {"plugin": key, "version": version, "verdict": verdict,
                 "reasons": reasons, "extras": []}
            )
            continue
        hits, extras = scan(path)
        verdict = next((v for v in VERDICT_ORDER if hits.get(v)), "PORTABLE")
        reasons = []
        for bucket in VERDICT_ORDER:
            reasons.extend(hits.get(bucket, []))
        results.append(
            {"plugin": key, "version": version, "verdict": verdict,
             "reasons": reasons[:6], "extras": list(dict.fromkeys(extras))}
        )

    if args.json:
        json.dump(results, sys.stdout, indent=2)
        print()
        return 0

    counts = {}
    for row in results:
        counts[row["verdict"]] = counts.get(row["verdict"], 0) + 1

    print(f"source profile: {CCD_HOME}")
    print(f"plugins: {len(results)}\n")
    rank = {v: i for i, v in enumerate(VERDICT_ORDER)}
    rank.update({"UNKNOWN": 90, "BUILTIN": 100})
    last = None
    for row in sorted(results, key=lambda r: rank.get(r["verdict"], 50)):
        if row["verdict"] != last:
            last = row["verdict"]
            print(f"--- {last} ---")
            print(f"    {ACTION.get(last, 'inspect manually')}")
        print(f"  {row['plugin']}  ({row['version']})")
        for reason in row["reasons"][:3]:
            print(f"      {reason}")
        for extra in row["extras"]:
            print(f"      note: {extra}")
    print()
    print("summary: " + ", ".join(
        f"{v}={counts[v]}" for v in VERDICT_ORDER + ["UNKNOWN", "BUILTIN"] if v in counts
    ))
    print("See references/compatibility.md for what each verdict implies.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
