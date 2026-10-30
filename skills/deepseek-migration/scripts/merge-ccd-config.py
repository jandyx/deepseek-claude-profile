#!/usr/bin/env python3
"""Re-apply ccd hooks/statusLine/plugins/MCP definitions into the dsd profile.

Idempotent. Written to run on every launcher start, after ccd's MCP servers or
plugin list change, and to recover the profile's .claude.json if a running
session overwrites it.

What is mirrored:
  settings.json : hooks, statusLine, enabledPlugins, extraKnownMarketplaces
  .claude.json  : user-scope mcpServers + per-project mcpServers and enable/disable lists

What is deliberately not mirrored:
  credentials, OAuth logins, permissions, history, theme/attribution/model.
  OAuth MCP servers need a manual /mcp re-auth in the new profile.

Paths default to the standard layout; override with CCD_CONFIG_DIR and
DSD_PROFILE_DIR.
"""
import json
import os
import sys

HOME = os.path.expanduser("~")
CCD_HOME = os.environ.get("CCD_CONFIG_DIR", os.path.join(HOME, ".claude"))
DSD_HOME = os.environ.get("DSD_PROFILE_DIR", os.path.join(HOME, ".config", "deepseek-claude"))


def resolve_user_config(config_home, explicit):
    """Locate the profile's user-scope .claude.json.

    Claude Code keeps it at $CLAUDE_CONFIG_DIR/.claude.json when the variable is
    set, and at ~/.claude.json otherwise — not at ~/.claude/.claude.json, which is
    a legacy artifact that may exist but stay empty. Getting this wrong silently
    merges zero MCP servers, so try the right one first and fall back.
    """
    candidates = [os.path.join(HOME, ".claude.json")]
    if explicit:
        candidates.insert(0, os.path.join(config_home, ".claude.json"))
    else:
        candidates.append(os.path.join(config_home, ".claude.json"))
    for path in candidates:
        if os.path.exists(path):
            return path
    return candidates[0]


CCD_SET = os.path.join(CCD_HOME, "settings.json")
CCD_CFG = resolve_user_config(CCD_HOME, "CCD_CONFIG_DIR" in os.environ)
DSD_SET = os.path.join(DSD_HOME, "claude", "settings.json")
DSD_CFG = os.path.join(DSD_HOME, "claude", ".claude.json")


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def merge_settings(ccd_set, dsd_set):
    dsd_set["hooks"] = ccd_set.get("hooks", {})
    if ccd_set.get("statusLine"):
        dsd_set["statusLine"] = ccd_set["statusLine"]
    dsd_set["enabledPlugins"] = dict(ccd_set.get("enabledPlugins", {}))
    if ccd_set.get("extraKnownMarketplaces"):
        dsd_set["extraKnownMarketplaces"] = ccd_set["extraKnownMarketplaces"]
    return 2 if ccd_set.get("statusLine") else 1


def merge_config(ccd_cfg, dsd_cfg):
    dsd_cfg.setdefault("mcpServers", {}).update(ccd_cfg.get("mcpServers", {}))
    for path, project in ccd_cfg.get("projects", {}).items():
        servers = project.get("mcpServers") or {}
        lists = {
            k: project[k]
            for k in ("enabledMcpjsonServers", "disabledMcpjsonServers")
            if project.get(k)
        }
        if not servers and not lists:
            continue
        dst = dsd_cfg.setdefault("projects", {}).setdefault(path, {})
        if servers:
            dst.setdefault("mcpServers", {}).update(servers)
        dst.update(lists)
    return len(dsd_cfg.get("mcpServers", {}))


def main():
    ccd_set = load(CCD_SET)
    if ccd_set is None:
        print("no source settings.json, nothing to merge")
        return 0

    dsd_set = load(DSD_SET) or {}
    events = merge_settings(ccd_set, dsd_set)
    save(DSD_SET, dsd_set)

    ccd_cfg = load(CCD_CFG)
    if ccd_cfg is not None:
        dsd_cfg = load(DSD_CFG) or {}
        servers = merge_config(ccd_cfg, dsd_cfg)
        save(DSD_CFG, dsd_cfg)
    else:
        servers = 0

    print(
        "synced:",
        f"{len(dsd_set.get('hooks', {}))} hook events ({events}),",
        "statusLine" if dsd_set.get("statusLine") else "no statusLine,",
        f"{servers} user MCP servers,",
        f"{len(dsd_set.get('enabledPlugins', {}))} plugin entries",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
