#!/usr/bin/env bash
# Health skill data collector — run from project root
# Usage: bash collect.sh [project_dir]
set -uo pipefail
# NOTE: do NOT use set -e — many commands legitimately return non-zero (find, grep, ls on missing paths)

P="${1:-$(pwd)}"
SETTINGS_LOCAL="$P/.claude/settings.local.json"
SETTINGS_PROJECT="$P/.claude/settings.json"
SETTINGS_USER="$HOME/.claude/settings.json"

# ── Discover enabled plugin install paths ──
PLUGIN_DIRS=()
INSTALLED_PLUGINS="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$INSTALLED_PLUGINS" ] && command -v python3 &>/dev/null; then
  while IFS= read -r pdir; do
    [ -d "$pdir" ] && PLUGIN_DIRS+=("$pdir")
  done < <(python3 -c "
import json, sys
try:
    d = json.load(open('$INSTALLED_PLUGINS'))
    for name, entries in d.get('plugins', {}).items():
        for e in entries:
            p = e.get('installPath', '')
            if p: print(p)
except: pass
" 2>/dev/null)
fi

# ── Tier metrics ──
echo "=== TIER METRICS ==="
echo "project_files: $(git -C "$P" ls-files 2>/dev/null | wc -l || find "$P" -type f -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/build/*" | wc -l)"
echo "contributors: $(git -C "$P" log -n 500 --format='%ae' 2>/dev/null | sort -u | wc -l)"
echo "ci_workflows:  $(ls "$P/.github/workflows/"*.yml "$P/.github/workflows/"*.yaml 2>/dev/null | wc -l)"
echo "skills:        $(find "$P/.claude/skills" -name "SKILL.md" 2>/dev/null | grep -v '/health/SKILL.md' | wc -l)"
echo "claude_md_lines: $(wc -l < "$P/CLAUDE.md" 2>/dev/null || echo 0)"

# ── CLAUDE.md files ──
echo "=== CLAUDE.md (global) ===" ; cat ~/.claude/CLAUDE.md 2>/dev/null || echo "(none)"
echo "=== CLAUDE.md (local) ===" ; cat "$P/CLAUDE.md" 2>/dev/null || echo "(none)"
echo "=== CLAUDE.md (.claude/CLAUDE.md) ===" ; cat "$P/.claude/CLAUDE.md" 2>/dev/null || echo "(none)"

# ── Settings files ──
echo "=== settings.json (user) ===" ; cat "$SETTINGS_USER" 2>/dev/null || echo "(none)"
echo "=== settings.json (project) ===" ; cat "$SETTINGS_PROJECT" 2>/dev/null || echo "(none)"
echo "=== settings.local.json ===" ; cat "$SETTINGS_LOCAL" 2>/dev/null || echo "(none)"

# ── Rules ──
echo "=== rules/ ===" ; find "$P/.claude/rules" -name "*.md" 2>/dev/null | while IFS= read -r f; do echo "--- $f ---"; cat "$f"; done
echo "=== user rules/ ===" ; find "$HOME/.claude/rules" -name "*.md" 2>/dev/null | while IFS= read -r f; do echo "--- $f ---"; cat "$f"; done

# ── Skill descriptions ──
echo "=== skill descriptions ===" ; {
  [ -d "$P/.claude/skills" ] && grep -r "^description:" "$P/.claude/skills" 2>/dev/null
  grep -r "^description:" ~/.claude/skills 2>/dev/null
  for pdir in "${PLUGIN_DIRS[@]}"; do
    [ -d "$pdir/skills" ] && grep -r "^description:" "$pdir/skills" 2>/dev/null
  done
} | sort -u

# ── Startup context estimate ──
echo "=== STARTUP CONTEXT ESTIMATE ==="
echo "global_claude_words: $(wc -w < ~/.claude/CLAUDE.md 2>/dev/null | tr -d ' ' || echo 0)"
echo "local_claude_words: $(wc -w < "$P/CLAUDE.md" 2>/dev/null | tr -d ' ' || echo 0)"
echo "rules_words: $(find "$P/.claude/rules" -name "*.md" 2>/dev/null | while IFS= read -r f; do cat "$f"; done | wc -w | tr -d ' ')"
echo "skill_desc_words: $({
  [ -d "$P/.claude/skills" ] && grep -r "^description:" "$P/.claude/skills" 2>/dev/null
  grep -r "^description:" ~/.claude/skills 2>/dev/null
  for pdir in "${PLUGIN_DIRS[@]}"; do
    [ -d "$pdir/skills" ] && grep -r "^description:" "$pdir/skills" 2>/dev/null
  done
} | wc -w | tr -d ' ')"

# ── MCP (project .mcp.json) ──
echo "=== .mcp.json (project) ===" ; cat "$P/.mcp.json" 2>/dev/null || echo "(none)"

# ── MCP (user ~/.claude.json) + settings parsing (python) ──
echo "=== .claude.json MCP ===" ; python3 -c "
import json
try:
    d = json.load(open('$HOME/.claude.json'))
    s = d.get('mcpServers', {})
    print(json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'env'} for k, v in s.items()}, indent=2))
except: print('(unavailable)')
" 2>/dev/null || echo "(unavailable)"

# ── Structured settings analysis (hooks, MCP, permissions, auto mode, plugins) ──
python3 "$(dirname "$0")/parse_settings.py" "$SETTINGS_LOCAL" "$SETTINGS_PROJECT" "$SETTINGS_USER" "$P" 2>/dev/null || echo "(python3 unavailable)"

# ── Nested CLAUDE.md ──
echo "=== NESTED CLAUDE.md ===" ; find "$P" -maxdepth 4 -name "CLAUDE.md" -not -path "$P/CLAUDE.md" -not -path "$P/.claude/CLAUDE.md" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null || echo "(none)"

# ── Gitignore check ──
echo "=== GITIGNORE ==="
_GITIGNORE_HIT=$(git -C "$P" check-ignore -v .claude/settings.local.json 2>/dev/null || true)
if [ -n "$_GITIGNORE_HIT" ]; then
  _GITIGNORE_SOURCE=${_GITIGNORE_HIT%%:*}
  case "$_GITIGNORE_SOURCE" in
    .gitignore|.claude/.gitignore) echo "settings.local.json: gitignored" ;;
    *) echo "settings.local.json: ignored only by non-project rule ($_GITIGNORE_SOURCE) -- add a repo-local ignore rule" ;;
  esac
else
  echo "settings.local.json: NOT gitignored -- risk of committing tokens/credentials"
fi

# ── Agents ──
_AGENT_DIRS=("$P/.claude/agents" "$HOME/.claude/agents")
for pdir in "${PLUGIN_DIRS[@]}"; do _AGENT_DIRS+=("$pdir/agents"); done
echo "=== AGENTS ===" ; find "${_AGENT_DIRS[@]}" -name "*.md" 2>/dev/null | while IFS= read -r f; do
  echo "--- $f ---"
  head -30 "$f"
done

# ── Handoff / Memory ──
echo "=== HANDOFF.md ===" ; cat "$P/HANDOFF.md" 2>/dev/null || echo "(none)"
echo "=== MEMORY.md ===" ; cat "$HOME/.claude/projects/-$(pwd | sed 's|[/_]|-|g; s|^-||')/memory/MEMORY.md" 2>/dev/null | head -50 || echo "(none)"

# ── Conversation files ──
PROJECT_PATH=$(pwd | sed 's|[/_]|-|g; s|^-||')
CONVO_DIR=~/.claude/projects/-${PROJECT_PATH}

echo "=== CONVERSATION FILES ==="
ls -lhS "$CONVO_DIR"/*.jsonl 2>/dev/null | head -10

echo "=== CONVERSATION EXTRACT (up to 3 most recent, confidence improves with more files) ==="
_PREV_FILES=$(ls -t "$CONVO_DIR"/*.jsonl 2>/dev/null | tail -n +2 | head -3)
if [ -n "$_PREV_FILES" ]; then
  echo "$_PREV_FILES" | while IFS= read -r F; do
    [ -f "$F" ] || continue
    echo "--- file: $F ---"
    head -c 2097152 "$F" | jq -r '
      if .type == "user" then "USER: " + ((.message.content // "") | if type == "array" then map(select(.type == "text") | .text) | join(" ") else . end)
      elif .type == "assistant" then
        "ASSISTANT: " + ((.message.content // []) | map(select(.type == "text") | .text) | join("\n"))
      else empty
      end
    ' 2>/dev/null | grep -v "^ASSISTANT: $" | head -300 || echo "(unavailable: jq not installed or parse error)"
  done
else
  echo "(no conversation files)"
fi

echo "=== MCP ACCESS DENIALS ==="
ls -t "$CONVO_DIR"/*.jsonl 2>/dev/null | head -5 | while IFS= read -r F; do
  head -c 1048576 "$F" | grep -Em 2 'Access denied - path outside allowed directories|tool-results/.+ not in ' 2>/dev/null
done | head -20

# ── Skill scan (exclude self) ──
SELF_SKILL=$( (grep -rl '^name: health$' "$P/.claude/skills" "$HOME/.claude/skills" 2>/dev/null || true) | grep 'SKILL.md' | head -1)
[ -z "$SELF_SKILL" ] && SELF_SKILL="health/SKILL.md"

_SKILL_DIRS=("$P/.claude/skills" "$HOME/.claude/skills")
for pdir in "${PLUGIN_DIRS[@]}"; do _SKILL_DIRS+=("$pdir/skills"); done

echo "=== SKILL INVENTORY ==="
for DIR in "${_SKILL_DIRS[@]}"; do
  [ -d "$DIR" ] || continue
  find -L "$DIR" -name "SKILL.md" 2>/dev/null | grep -v "$SELF_SKILL" | while IFS= read -r f; do
    WORDS=$(wc -w < "$f" | tr -d ' ')
    IS_LINK="no"; LINK_TARGET=""
    SKILL_DIR=$(dirname "$f")
    if [ -L "$SKILL_DIR" ]; then IS_LINK="yes"; LINK_TARGET=$(readlink -f "$SKILL_DIR"); fi
    # Tag plugin source
    SOURCE="local"
    case "$f" in */.claude/plugins/cache/*) SOURCE="plugin:$(echo "$f" | sed 's|.*/cache/\([^/]*/[^/]*\)/.*|\1|')" ;; esac
    echo "path=$f words=$WORDS symlink=$IS_LINK target=$LINK_TARGET source=$SOURCE"
  done
done

echo "=== SKILL FRONTMATTER ==="
for DIR in "${_SKILL_DIRS[@]}"; do
  [ -d "$DIR" ] || continue
  find -L "$DIR" -name "SKILL.md" 2>/dev/null | grep -v "$SELF_SKILL" | while IFS= read -r f; do
    if head -1 "$f" | grep -q '^---'; then
      echo "frontmatter=yes path=$f"
      sed -n '2,/^---$/p' "$f" | head -15
    else
      echo "frontmatter=MISSING path=$f"
    fi
  done
done

echo "=== SKILL SYMLINK PROVENANCE ==="
for DIR in "$P/.claude/skills" "$HOME/.claude/skills"; do
  [ -d "$DIR" ] || continue
  find "$DIR" -maxdepth 1 -type l 2>/dev/null | while IFS= read -r link; do
    TARGET=$(readlink -f "$link")
    echo "link=$(basename "$link") target=$TARGET"
    if [ -d "$TARGET/.git" ]; then
      REMOTE=$(git -C "$TARGET" remote get-url origin 2>/dev/null || echo "unknown")
      COMMIT=$(git -C "$TARGET" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      echo "  git_remote=$REMOTE commit=$COMMIT"
    fi
  done
done

echo "=== SKILL FULL CONTENT (sample: up to 5 skills, 80 lines each) ==="
{ for DIR in "${_SKILL_DIRS[@]}"; do
    [ -d "$DIR" ] || continue
    find -L "$DIR" -name "SKILL.md" 2>/dev/null | grep -v "$SELF_SKILL"
  done
} | head -5 | while IFS= read -r f; do
  echo "--- FULL: $f ---"
  head -80 "$f"
done

echo "=== AGENT FRONTMATTER ==="
for DIR in "${_AGENT_DIRS[@]}"; do
  [ -d "$DIR" ] || continue
  find "$DIR" -name "*.md" 2>/dev/null | while IFS= read -r f; do
    if head -1 "$f" | grep -q '^---'; then
      echo "frontmatter=yes path=$f"
      sed -n '2,/^---$/p' "$f" | head -20
    else
      echo "frontmatter=MISSING path=$f"
    fi
  done
done

# ── Plugin hooks + CLAUDE.md ──
echo "=== PLUGIN HOOKS ==="
for pdir in "${PLUGIN_DIRS[@]}"; do
  PLUGIN_NAME=$(basename "$(dirname "$pdir")")/$(basename "$pdir")
  HOOKS_FILE="$pdir/hooks/hooks.json"
  if [ -f "$HOOKS_FILE" ]; then
    echo "--- plugin: $PLUGIN_NAME ---"
    cat "$HOOKS_FILE"
  fi
done

echo "=== PLUGIN CLAUDE.md ==="
for pdir in "${PLUGIN_DIRS[@]}"; do
  PLUGIN_NAME=$(basename "$(dirname "$pdir")")/$(basename "$pdir")
  if [ -f "$pdir/CLAUDE.md" ]; then
    echo "--- plugin: $PLUGIN_NAME ---"
    head -50 "$pdir/CLAUDE.md"
  fi
done
