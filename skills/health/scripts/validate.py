#!/usr/bin/env python3
"""
Deterministic health checks that don't need LLM judgment.
Run after collect.sh; reads the same settings/skills/agents files directly.
Outputs structured findings as === sections for the subagents to consume.

Usage: python3 validate.py <project_dir>
"""
import json, os, re, sys, glob as globmod
from pathlib import Path

P = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
HOME = Path.home()
findings = {"critical": [], "structural": [], "incremental": []}


def discover_plugin_dirs():
    """Read installed_plugins.json and return list of enabled plugin install paths."""
    installed = HOME / ".claude" / "plugins" / "installed_plugins.json"
    dirs = []
    try:
        d = json.load(open(installed))
        for name, entries in d.get("plugins", {}).items():
            for e in entries:
                p = e.get("installPath", "")
                if p and Path(p).is_dir():
                    dirs.append(Path(p))
    except Exception:
        pass
    return dirs


PLUGIN_DIRS = discover_plugin_dirs()


def add(severity, check, detail):
    findings[severity].append(f"[{check}] {detail}")


def load_json(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


# ── Known valid fields ──

SKILL_FIELDS = {
    "name", "description", "argument-hint", "disable-model-invocation",
    "user-invocable", "allowed-tools", "model", "effort", "context",
    "agent", "hooks", "paths", "shell",
}

AGENT_FIELDS = {
    "name", "description", "tools", "disallowedTools", "model",
    "permissionMode", "maxTurns", "skills", "mcpServers", "hooks",
    "memory", "background", "effort", "isolation", "initialPrompt",
}

HOOK_EVENTS = {
    "SessionStart", "InstructionsLoaded", "UserPromptSubmit",
    "PreToolUse", "PermissionRequest", "PostToolUse", "PostToolUseFailure",
    "Notification", "SubagentStart", "SubagentStop",
    "TaskCreated", "TaskCompleted", "TeammateIdle",
    "Stop", "StopFailure",
    "ConfigChange", "CwdChanged", "FileChanged",
    "PreCompact", "PostCompact",
    "Elicitation", "ElicitationResult",
    "WorktreeCreate", "WorktreeRemove", "SessionEnd",
}

HOOK_HANDLER_TYPES = {"command", "http", "prompt", "agent"}

HOOK_COMMON_FIELDS = {"type", "if", "timeout", "statusMessage", "once"}
HOOK_TYPE_FIELDS = {
    "command": {"command", "async", "shell"},
    "http": {"url", "headers", "allowedEnvVars"},
    "prompt": {"prompt", "model"},
    "agent": {"prompt"},
}

DEPRECATED_SETTINGS = {"includeCoAuthoredBy"}
MANAGED_ONLY_SETTINGS = {"allowManagedPermissionRulesOnly", "allowManagedHooksOnly",
                         "allowManagedMcpServersOnly", "channelsEnabled"}

# ── 1. Parse YAML frontmatter ──

def parse_frontmatter(filepath):
    """Extract YAML frontmatter as dict. Returns (fields_dict, raw_lines) or (None, None)."""
    try:
        lines = open(filepath).readlines()
    except Exception:
        return None, None
    if not lines or lines[0].strip() != "---":
        return None, None
    end = -1
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            end = i
            break
    if end < 0:
        return None, None
    # Simple key: value parsing (no nested YAML)
    fields = {}
    for line in lines[1:end]:
        m = re.match(r'^(\S[\w-]*):\s*(.*)', line)
        if m:
            fields[m.group(1)] = m.group(2).strip()
    return fields, len(lines)


# ── 2. Validate skills ──

def validate_skills():
    skill_dirs = [P / ".claude" / "skills", HOME / ".claude" / "skills"]
    for pd in PLUGIN_DIRS:
        skill_dirs.append(pd / "skills")
    for sd in skill_dirs:
        if not sd.is_dir():
            continue
        for skill_md in sd.rglob("SKILL.md"):
            if "health" in str(skill_md):
                continue
            rel = str(skill_md)
            fields, total_lines = parse_frontmatter(skill_md)
            if fields is None:
                add("structural", "skill-frontmatter", f"Missing frontmatter: {rel}")
                continue
            # Unknown fields
            unknown = set(fields.keys()) - SKILL_FIELDS
            if unknown:
                add("structural", "skill-frontmatter", f"Unknown fields {unknown} in {rel}")
            # Description check
            desc = fields.get("description", "")
            if not desc:
                add("structural", "skill-description", f"No description: {rel}")
            elif len(desc) > 250:
                add("incremental", "skill-description", f"Description >{len(desc)} chars (>250 truncated): {rel}")
            # Size check
            if total_lines and total_lines > 500:
                add("structural", "skill-bloat", f"SKILL.md {total_lines} lines (>500): {rel}")
            # context: fork without task
            if fields.get("context") == "fork":
                # Check if body has actionable content (very rough heuristic)
                try:
                    body = open(skill_md).read()
                    # After second ---, count non-whitespace lines
                    parts = body.split("---", 2)
                    if len(parts) >= 3:
                        body_lines = [l for l in parts[2].strip().split("\n") if l.strip()]
                        if len(body_lines) < 3:
                            add("structural", "skill-fork", f"context:fork with minimal body ({len(body_lines)} lines): {rel}")
                except Exception:
                    pass


# ── 3. Validate agents ──

def validate_agents():
    agent_dirs = [P / ".claude" / "agents", HOME / ".claude" / "agents"]
    for pd in PLUGIN_DIRS:
        agent_dirs.append(pd / "agents")
    for ad in agent_dirs:
        if not ad.is_dir():
            continue
        for agent_md in ad.glob("*.md"):
            rel = str(agent_md)
            fields, total_lines = parse_frontmatter(agent_md)
            if fields is None:
                add("structural", "agent-frontmatter", f"Missing frontmatter: {rel}")
                continue
            # Required fields
            if "name" not in fields:
                add("structural", "agent-frontmatter", f"Missing required 'name': {rel}")
            if "description" not in fields:
                add("structural", "agent-frontmatter", f"Missing required 'description': {rel}")
            # Unknown fields
            unknown = set(fields.keys()) - AGENT_FIELDS
            if unknown:
                add("structural", "agent-frontmatter", f"Unknown fields {unknown} in {rel}")
            # maxTurns
            if "maxTurns" not in fields:
                add("structural", "agent-maxTurns", f"No maxTurns (runaway risk): {rel}")
            # bypassPermissions
            if fields.get("permissionMode") == "bypassPermissions":
                add("critical", "agent-bypass", f"permissionMode: bypassPermissions: {rel}")
            # Body size
            if total_lines and total_lines > 300:
                add("incremental", "agent-bloat", f"Agent {total_lines} lines (>300): {rel}")


# ── 4. Validate hooks ──

def validate_hooks_in(hooks_dict, source_label):
    if not isinstance(hooks_dict, dict):
        return
    for event_name, matchers in hooks_dict.items():
        if event_name not in HOOK_EVENTS:
            add("structural", "hook-event", f"Unknown event '{event_name}' in {source_label}")
        if not isinstance(matchers, list):
            add("structural", "hook-schema", f"Event '{event_name}' value is not array in {source_label}")
            continue
        for mg in matchers:
            if not isinstance(mg, dict):
                continue
            hooks_arr = mg.get("hooks", [])
            if not isinstance(hooks_arr, list):
                add("structural", "hook-schema", f"'hooks' not array in {event_name} matcher in {source_label}")
                continue
            for hook in hooks_arr:
                if not isinstance(hook, dict):
                    continue
                htype = hook.get("type")
                if htype not in HOOK_HANDLER_TYPES:
                    add("critical", "hook-type", f"Invalid handler type '{htype}' in {event_name} ({source_label})")
                    continue
                # Check fields
                allowed = HOOK_COMMON_FIELDS | HOOK_TYPE_FIELDS.get(htype, set())
                unknown = set(hook.keys()) - allowed
                if unknown:
                    add("incremental", "hook-fields", f"Unknown hook fields {unknown} in {event_name}.{htype} ({source_label})")
                # Command hook must have command
                if htype == "command" and "command" not in hook:
                    add("structural", "hook-missing-cmd", f"Command hook without 'command' in {event_name} ({source_label})")
                # HTTP hook must have url
                if htype == "http" and "url" not in hook:
                    add("structural", "hook-missing-url", f"HTTP hook without 'url' in {event_name} ({source_label})")
                # Prompt/agent hook must have prompt
                if htype in ("prompt", "agent") and "prompt" not in hook:
                    add("structural", "hook-missing-prompt", f"{htype} hook without 'prompt' in {event_name} ({source_label})")


def validate_hooks():
    for label, path in [("user", HOME / ".claude" / "settings.json"),
                        ("project", P / ".claude" / "settings.json"),
                        ("local", P / ".claude" / "settings.local.json")]:
        d = load_json(path)
        if d and "hooks" in d:
            validate_hooks_in(d["hooks"], f"settings ({label})")
    # Plugin hooks (hooks.json files — may wrap events under a "hooks" key)
    for pd in PLUGIN_DIRS:
        hooks_json = pd / "hooks" / "hooks.json"
        d = load_json(hooks_json)
        if d:
            plugin_label = f"plugin:{pd.parent.name}/{pd.name}"
            # hooks.json can be {"hooks": {...events...}} or flat {...events...}
            hooks_data = d.get("hooks", d) if isinstance(d, dict) else d
            validate_hooks_in(hooks_data, plugin_label)


# ── 5. Context budget ──

def calc_context_budget():
    def word_count(path):
        try:
            return len(open(path).read().split())
        except Exception:
            return 0

    global_words = word_count(HOME / ".claude" / "CLAUDE.md")
    local_words = word_count(P / "CLAUDE.md") + word_count(P / ".claude" / "CLAUDE.md")
    rules_words = sum(word_count(f) for f in (P / ".claude" / "rules").rglob("*.md")) if (P / ".claude" / "rules").is_dir() else 0

    # Skill descriptions (rough)
    skill_desc_words = 0
    all_skill_dirs = [P / ".claude" / "skills", HOME / ".claude" / "skills"]
    for pd in PLUGIN_DIRS:
        all_skill_dirs.append(pd / "skills")
    for sd in all_skill_dirs:
        if sd.is_dir():
            for sm in sd.rglob("SKILL.md"):
                fm, _ = parse_frontmatter(sm)
                if fm and "description" in fm:
                    skill_desc_words += len(fm["description"].split())

    text_tokens = int((global_words + local_words + rules_words + skill_desc_words) * 1.3)

    # MCP tokens (count servers)
    mcp_count = 0
    claude_json = load_json(HOME / ".claude.json")
    if claude_json and "mcpServers" in claude_json:
        mcp_count += len(claude_json["mcpServers"])
    mcp_json = load_json(P / ".mcp.json")
    if mcp_json:
        servers = mcp_json.get("mcpServers", mcp_json)
        # Flat format: each top-level key is a server (exclude non-dict values)
        mcp_count += sum(1 for v in servers.values() if isinstance(v, dict))
    # Plugin MCP servers
    for pd in PLUGIN_DIRS:
        plugin_mcp = load_json(pd / ".mcp.json")
        if plugin_mcp:
            servers = plugin_mcp.get("mcpServers", plugin_mcp)
            mcp_count += sum(1 for v in servers.values() if isinstance(v, dict))
    mcp_tokens = mcp_count * 25 * 200

    total = text_tokens + mcp_tokens

    print(f"=== CONTEXT BUDGET ===")
    print(f"text_tokens: ~{text_tokens} (global={global_words}w local={local_words}w rules={rules_words}w skill_desc={skill_desc_words}w)")
    print(f"mcp_tokens: ~{mcp_tokens} ({mcp_count} servers × 25 tools × 200 tok)")
    print(f"total_startup: ~{total} tokens ({round(total/2000)}% of 200K)")

    if total > 30000:
        add("critical", "context-budget", f"Startup context ~{total} tokens (>30K): high pressure before first message")
    if (global_words + local_words) > 3800:
        add("structural", "claude-md-size", f"CLAUDE.md ~{global_words + local_words} words (>3800 ≈ 5K tokens): oversized")
    if mcp_count > 6:
        add("critical", "mcp-count", f"{mcp_count} MCP servers: likely >12.5% context overhead")
    elif mcp_tokens > 20000:
        add("structural", "mcp-tokens", f"MCP estimated ~{mcp_tokens} tokens (>10% of 200K)")


# ── 6. Settings conflicts ──

def validate_settings():
    levels = {}
    for label, path in [("user", HOME / ".claude" / "settings.json"),
                        ("project", P / ".claude" / "settings.json"),
                        ("local", P / ".claude" / "settings.local.json")]:
        d = load_json(path)
        if d:
            levels[label] = d

    if not levels:
        return

    # Deprecated settings
    for label, d in levels.items():
        for dep in DEPRECATED_SETTINGS:
            if dep in d:
                add("structural", "deprecated-setting", f"'{dep}' in {label} settings (use 'attribution' instead)")

    # Managed-only at wrong level
    for label, d in levels.items():
        for ms in MANAGED_ONLY_SETTINGS:
            if ms in d:
                add("critical", "managed-only", f"'{ms}' set in {label} settings (managed-only, will be ignored)")

    # Cross-level conflicts
    all_keys = set()
    for d in levels.values():
        all_keys |= set(d.keys())
    for key in all_keys:
        vals = {label: d[key] for label, d in levels.items() if key in d}
        if len(vals) > 1:
            # Check if values actually differ
            v_list = list(vals.values())
            if any(json.dumps(v, sort_keys=True) != json.dumps(v_list[0], sort_keys=True) for v in v_list[1:]):
                if key in ("permissions", "hooks", "env"):
                    continue  # These intentionally layer/merge
                add("incremental", "settings-conflict", f"'{key}' set at {list(vals.keys())} with different values")

    # Dangerous defaults
    for label, d in levels.items():
        pm = d.get("permissions", {}).get("defaultMode")
        if pm == "bypassPermissions" and label == "project":
            add("critical", "bypass-project", f"defaultMode: bypassPermissions in project settings (affects all contributors)")
        if d.get("cleanupPeriodDays") == 0:
            add("structural", "no-persistence", f"cleanupPeriodDays: 0 in {label} (disables session persistence)")
        if d.get("includeGitInstructions") is False:
            add("incremental", "no-git-instructions", f"includeGitInstructions: false in {label} (ensure custom git skill exists)")
        if d.get("enableAllProjectMcpServers") is True and label == "project":
            add("structural", "auto-approve-mcp", f"enableAllProjectMcpServers: true in {label} (auto-approves untrusted servers)")


# ── 7. Permission wildcard redundancy (from config-review) ──

def validate_permission_redundancy():
    user_d = load_json(HOME / ".claude" / "settings.json")
    local_d = load_json(P / ".claude" / "settings.local.json")
    if not user_d or not local_d:
        return
    user_allow = set(user_d.get("permissions", {}).get("allow", []))
    local_allow = local_d.get("permissions", {}).get("allow", [])
    if not user_allow or not local_allow:
        return
    # Check if local rules are already covered by user-level wildcards
    user_wildcards = [r for r in user_allow if r.endswith("*)") or r.endswith(":*)")]
    for local_rule in local_allow:
        for wc in user_wildcards:
            # Extract prefix: "Bash(git:*)" → "Bash(git:"
            prefix = wc.rstrip("*)")
            if local_rule.startswith(prefix) and local_rule != wc:
                add("incremental", "permission-redundant",
                    f"Local '{local_rule}' already covered by user wildcard '{wc}'")
                break


# ── 8. Hook script robustness (from config-review) ──

def validate_hook_scripts():
    hook_dirs = [P / ".claude" / "hooks"]
    for pd in PLUGIN_DIRS:
        hook_dirs.append(pd / "hooks")
    for hooks_dir in hook_dirs:
        if not hooks_dir.is_dir():
            continue
        for script in hooks_dir.glob("*.sh"):
            try:
                content = open(script).read()
            except Exception:
                continue
            rel = str(script)
            # Check for fragile jq field extraction (only one path variant)
            if "jq" in content:
                if '.tool_input.file_path' in content and '// .tool_input.filePath' not in content:
                    if '.tool_input.filePath' not in content:
                        add("incremental", "hook-fragile-jq",
                            f"jq in {rel} uses only .tool_input.file_path without filePath fallback")


# ── 9. Security pattern scan ──

SECURITY_PATTERNS = [
    ("prompt-injection", re.compile(r'(ignore|disregard|forget)\s+(all\s+)?(previous|prior|above)\s+(instructions|context|rules)', re.I)),
    ("prompt-injection", re.compile(r'you\s+are\s+now\s+', re.I)),
    ("prompt-injection", re.compile(r'new\s+system\s+prompt', re.I)),
    ("destructive", re.compile(r'rm\s+-rf\s+(/|\$HOME|\$\{?HOME)', re.I)),
    ("destructive", re.compile(r'git\s+push\s+--force\s+(origin\s+)?(main|master)', re.I)),
    ("safety-override", re.compile(r'(bypass|disable|skip|ignore)\s+(safety|security|hooks|verification|checks)', re.I)),
    ("credential", re.compile(r'(?:api[_-]?key|secret|token|password)\s*[=:]\s*["\']?[A-Za-z0-9+/=]{20,}', re.I)),
    ("obfuscation", re.compile(r'(eval|exec)\s*\$\(', re.I)),
    ("obfuscation", re.compile(r'base64\s+(-d|--decode)\s*\|', re.I)),
    ("exfiltration", re.compile(r'curl\s+.*-X\s*POST.*\$\{?\w*(KEY|SECRET|TOKEN|PASS)', re.I)),
]


def scan_security():
    targets = []
    skill_dirs = [P / ".claude" / "skills", HOME / ".claude" / "skills"]
    agent_dirs = [P / ".claude" / "agents", HOME / ".claude" / "agents"]
    for pd in PLUGIN_DIRS:
        skill_dirs.append(pd / "skills")
        agent_dirs.append(pd / "agents")
    for sd in skill_dirs:
        if sd.is_dir():
            for f in sd.rglob("*.md"):
                if "health" in str(f):
                    continue
                targets.append(f)
    for ad in agent_dirs:
        if ad.is_dir():
            for f in ad.glob("*.md"):
                targets.append(f)
    # Also scan plugin hook scripts
    for pd in PLUGIN_DIRS:
        hooks_dir = pd / "hooks"
        if hooks_dir.is_dir():
            for f in hooks_dir.glob("*.sh"):
                targets.append(f)
        scripts_dir = pd / "scripts"
        if scripts_dir.is_dir():
            for f in scripts_dir.glob("*.sh"):
                targets.append(f)

    for filepath in targets:
        try:
            content = open(filepath).read()
        except Exception:
            continue
        for category, pattern in SECURITY_PATTERNS:
            matches = pattern.findall(content)
            if matches:
                # Check if it's in a code fence discussing the pattern vs actually using it
                # Simple heuristic: if the match is inside a list item starting with "Flag" or "Check", it's discussion
                for m in pattern.finditer(content):
                    line_start = content.rfind("\n", 0, m.start()) + 1
                    line = content[line_start:m.end() + 50]
                    if re.match(r'\s*[-*]\s*(Flag|Check|Do NOT|Avoid|NEVER|Block|Note|Plugin)', line, re.I):
                        continue  # Discussion, not usage
                    # Also skip lines that describe what something "ignores" or "cannot"
                    if re.search(r'\b(agents?\s+ignore|cannot|don.t\s+support|security\s+limitation)', line, re.I):
                        continue  # Documenting a limitation, not exploiting it
                    add("critical", f"security-{category}", f"Pattern match in {filepath}: ...{content[max(0,m.start()-20):m.end()+20]}...")
                    break  # One finding per pattern per file


# ── Run all checks ──

print("=== AUTOMATED VALIDATION ===")
validate_skills()
validate_agents()
validate_hooks()
calc_context_budget()
validate_settings()
validate_permission_redundancy()
validate_hook_scripts()
scan_security()

# ── Output findings ──
print("\n=== VALIDATION FINDINGS ===")
for severity in ("critical", "structural", "incremental"):
    items = findings[severity]
    label = {"critical": "☻ Critical", "structural": "◎ Structural", "incremental": "○ Incremental"}[severity]
    if items:
        print(f"\n{label} ({len(items)}):")
        for item in items:
            print(f"  - {item}")

total = sum(len(v) for v in findings.values())
if total == 0:
    print("\n✓ All automated checks passed.")
else:
    print(f"\nTotal: {total} findings (☻{len(findings['critical'])} ◎{len(findings['structural'])} ○{len(findings['incremental'])})")
