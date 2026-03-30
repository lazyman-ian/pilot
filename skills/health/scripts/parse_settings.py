#!/usr/bin/env python3
"""Parse settings files and extract hooks, MCP, permissions, auto mode, plugins."""
import json, sys, os

SETTINGS_LOCAL = sys.argv[1] if len(sys.argv) > 1 else ""
SETTINGS_PROJECT = sys.argv[2] if len(sys.argv) > 2 else ""
SETTINGS_USER = sys.argv[3] if len(sys.argv) > 3 else ""
PROJECT_DIR = sys.argv[4] if len(sys.argv) > 4 else "."

sources = [("local", SETTINGS_LOCAL), ("project", SETTINGS_PROJECT), ("user", SETTINGS_USER)]


def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


# ── Hooks ──
for label, path in sources:
    d = load(path)
    if d and "hooks" in d:
        print(f"=== hooks ({label}) ===")
        print(json.dumps(d["hooks"], indent=2))

# ── MCP from settings ──
print("=== MCP from settings ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    s = d.get("mcpServers", d.get("enabledMcpjsonServers", {}))
    if s:
        names = list(s.keys()) if isinstance(s, dict) else list(s)
        n = len(names)
        est = n * 25 * 200
        print(f"{label}: servers({n}): {names}, est_tokens: ~{est} ({round(est / 2000)}% of 200K)")

# ── MCP filesystem ──
print("=== MCP FILESYSTEM ===")
for label, path in [("~/.claude.json", os.path.expanduser("~/.claude.json")), (".mcp.json", os.path.join(PROJECT_DIR, ".mcp.json"))]:
    d = load(path)
    if not d:
        continue
    s = d.get("mcpServers", d)
    fs = s.get("filesystem") if isinstance(s, dict) else None
    a = []
    if isinstance(fs, dict):
        a = fs.get("allowedDirectories") or []
        if not a and isinstance(fs.get("args"), list):
            args = fs["args"]
            for i, v in enumerate(args):
                if v in ("--allowed-directories", "--allowedDirectories") and i + 1 < len(args):
                    a = [args[i + 1]]
                    break
            if not a:
                a = [v for v in args if v.startswith("/") or (v.startswith("~") and len(v) > 1)]
    print(f'{label}: filesystem={"yes" if fs else "no"} dirs={a or "(not detected)"}')

# ── Allowed tools count ──
print("=== allowedTools count ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    allow = d.get("permissions", {}).get("allow", [])
    deny = d.get("permissions", {}).get("deny", [])
    if allow or deny:
        print(f"{label}: allow={len(allow)} deny={len(deny)}")

# ── Auto mode ──
print("=== AUTO MODE ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    if "autoMode" in d:
        print(f'{label}: autoMode={json.dumps(d["autoMode"])}')
    if "disableAutoMode" in d:
        print(f'{label}: disableAutoMode={d["disableAutoMode"]}')
    dm = d.get("permissions", {}).get("defaultMode")
    if dm:
        print(f"{label}: defaultMode={dm}")

# ── Auto memory ──
print("=== AUTO MEMORY ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    if "autoMemoryEnabled" in d:
        print(f'{label}: autoMemoryEnabled={d["autoMemoryEnabled"]}')
    if "autoMemoryDirectory" in d:
        print(f'{label}: autoMemoryDirectory={d["autoMemoryDirectory"]}')

# ── Plugins ──
print("=== PLUGINS ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    if "enabledPlugins" in d:
        print(f'{label}: enabledPlugins={json.dumps(d["enabledPlugins"])}')
    if "extraKnownMarketplaces" in d:
        print(f'{label}: extraKnownMarketplaces={json.dumps(d["extraKnownMarketplaces"])}')

# ── CLAUDE.md excludes ──
print("=== CLAUDE MD EXCLUDES ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    if "claudeMdExcludes" in d:
        print(f'{label}: claudeMdExcludes={json.dumps(d["claudeMdExcludes"])}')

# ── Notable settings ──
print("=== NOTABLE SETTINGS ===")
for label, path in sources:
    d = load(path)
    if not d:
        continue
    for key in ["model", "effortLevel", "outputStyle", "agent", "includeGitInstructions",
                "cleanupPeriodDays", "enableAllProjectMcpServers", "disableAllHooks",
                "allowManagedHooksOnly", "allowManagedPermissionRulesOnly",
                "sandbox", "attribution", "includeCoAuthoredBy"]:
        if key in d:
            val = d[key]
            if isinstance(val, dict):
                val = json.dumps(val)
            print(f"{label}: {key}={val}")
