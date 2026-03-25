#!/bin/bash
# agent-dev setup: merge sub-project .claude/ capabilities into monorepo root
# Creates symlinks for rules/skills/steering/agents and merges settings.json hooks
set -euo pipefail

ROOT="$PWD"
CLAUDE_DIR="$ROOT/.claude"
MANIFEST="$CLAUDE_DIR/.agent-dev-setup.json"

# Ensure .claude/ exists
mkdir -p "$CLAUDE_DIR"/{rules,skills,steering,agents,commands}

# Track created symlinks
LINKS=()
MERGED_HOOKS_SESSION_START=()
MERGED_HOOKS_PRE=()
MERGED_HOOKS_POST=()
MERGED_HOOKS_STOP=()
MERGED_HOOKS_SUBAGENT_STOP=()
MERGED_HOOKS_COMPACT=()

echo "Scanning sub-projects..."

for dir in "$ROOT"/*/; do
  project=$(basename "$dir")
  project_claude="$dir.claude"

  # Skip if not a sub-project (no .git or no .claude)
  [ -d "$dir.git" ] || continue
  [ -d "$project_claude" ] || continue

  echo "  Found: $project"

  # Symlink rules
  if [ -d "$project_claude/rules" ]; then
    for f in "$project_claude/rules"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      link="$CLAUDE_DIR/rules/${project}--${fname}"
      target="../../${project}/.claude/rules/${fname}"
      if [ ! -e "$link" ]; then
        ln -sf "$target" "$link"
        LINKS+=("rules/${project}--${fname}")
        echo "    rules/${project}--${fname}"
      fi
    done
  fi

  # Symlink skills (directories)
  if [ -d "$project_claude/skills" ]; then
    for d in "$project_claude/skills"/*/; do
      [ -d "$d" ] || continue
      sname=$(basename "$d")
      link="$CLAUDE_DIR/skills/${project}--${sname}"
      target="../../${project}/.claude/skills/${sname}"
      if [ ! -e "$link" ]; then
        ln -sf "$target" "$link"
        LINKS+=("skills/${project}--${sname}")
        echo "    skills/${project}--${sname}"
      fi
    done
  fi

  # Symlink steering
  if [ -d "$project_claude/steering" ]; then
    for f in "$project_claude/steering"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      link="$CLAUDE_DIR/steering/${project}--${fname}"
      target="../../${project}/.claude/steering/${fname}"
      if [ ! -e "$link" ]; then
        ln -sf "$target" "$link"
        LINKS+=("steering/${project}--${fname}")
        echo "    steering/${project}--${fname}"
      fi
    done
  fi

  # Symlink agents
  if [ -d "$project_claude/agents" ]; then
    for f in "$project_claude/agents"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      link="$CLAUDE_DIR/agents/${project}--${fname}"
      target="../../${project}/.claude/agents/${fname}"
      if [ ! -e "$link" ]; then
        ln -sf "$target" "$link"
        LINKS+=("agents/${project}--${fname}")
        echo "    agents/${project}--${fname}"
      fi
    done
  fi

  # Symlink commands
  if [ -d "$project_claude/commands" ]; then
    for f in "$project_claude/commands"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      link="$CLAUDE_DIR/commands/${project}--${fname}"
      target="../../${project}/.claude/commands/${fname}"
      if [ ! -e "$link" ]; then
        ln -sf "$target" "$link"
        LINKS+=("commands/${project}--${fname}")
        echo "    commands/${project}--${fname}"
      fi
    done
  fi

  # Collect hooks from settings.json (for later merging)
  if [ -f "$project_claude/settings.json" ]; then
    ABS_PROJECT_DIR=$(cd "$dir" && pwd)

    # Extract and rewrite hooks: replace $CLAUDE_PROJECT_DIR with absolute path
    for hook_type in SessionStart PreToolUse PostToolUse Stop SubagentStop PostCompact; do
      hooks=$(jq -r --arg ht "$hook_type" --arg pd "$ABS_PROJECT_DIR" \
        '.hooks[$ht] // [] | map(
          .hooks = [.hooks[]? | .command = (.command | gsub("\\$CLAUDE_PROJECT_DIR"; $pd) | gsub("\\${CLAUDE_PROJECT_DIR}"; $pd))]
        ) | if length > 0 then . else empty end' \
        "$project_claude/settings.json" 2>/dev/null) || continue

      [ -z "$hooks" ] && continue

      case "$hook_type" in
        SessionStart) MERGED_HOOKS_SESSION_START+=("$hooks") ;;
        PreToolUse) MERGED_HOOKS_PRE+=("$hooks") ;;
        PostToolUse) MERGED_HOOKS_POST+=("$hooks") ;;
        Stop) MERGED_HOOKS_STOP+=("$hooks") ;;
        SubagentStop) MERGED_HOOKS_SUBAGENT_STOP+=("$hooks") ;;
        PostCompact) MERGED_HOOKS_COMPACT+=("$hooks") ;;
      esac
      echo "    hooks: $hook_type (from $project)"
    done
  fi
done

# Merge hooks into root settings.json
SETTINGS="$CLAUDE_DIR/settings.json"
HOOKS_BACKUP="$CLAUDE_DIR/.agent-dev-hooks-backup.json"
if [ -f "$SETTINGS" ]; then
  # Restore user's original hooks (before any previous setup merge)
  if [ -f "$HOOKS_BACKUP" ]; then
    EXISTING=$(jq --argjson orig "$(cat "$HOOKS_BACKUP")" '.hooks = $orig' "$SETTINGS")
  else
    # First run: backup current hooks as the user's original
    jq '.hooks // {}' "$SETTINGS" > "$HOOKS_BACKUP"
    EXISTING=$(cat "$SETTINGS")
  fi
else
  echo '{}' > "$HOOKS_BACKUP"
  EXISTING='{"hooks":{}}'
fi

# Build merged hooks JSON
MERGED_JSON="$EXISTING"
for hook_type in SessionStart PreToolUse PostToolUse Stop SubagentStop PostCompact; do
  case "$hook_type" in
    SessionStart) arr=("${MERGED_HOOKS_SESSION_START[@]+"${MERGED_HOOKS_SESSION_START[@]}"}") ;;
    PreToolUse) arr=("${MERGED_HOOKS_PRE[@]+"${MERGED_HOOKS_PRE[@]}"}") ;;
    PostToolUse) arr=("${MERGED_HOOKS_POST[@]+"${MERGED_HOOKS_POST[@]}"}") ;;
    Stop) arr=("${MERGED_HOOKS_STOP[@]+"${MERGED_HOOKS_STOP[@]}"}") ;;
    SubagentStop) arr=("${MERGED_HOOKS_SUBAGENT_STOP[@]+"${MERGED_HOOKS_SUBAGENT_STOP[@]}"}") ;;
    PostCompact) arr=("${MERGED_HOOKS_COMPACT[@]+"${MERGED_HOOKS_COMPACT[@]}"}") ;;
  esac

  [ ${#arr[@]} -eq 0 ] && continue

  # Combine all project hook arrays into one
  COMBINED="["
  first=true
  for h in "${arr[@]}"; do
    if [ "$first" = true ]; then
      COMBINED="${COMBINED}${h}"
      first=false
    else
      # Strip outer brackets and append
      inner=$(echo "$h" | sed 's/^\[//;s/\]$//')
      COMBINED="${COMBINED},${inner}"
    fi
  done
  COMBINED="${COMBINED}]"

  # Flatten: we have array of arrays, need single array
  FLAT=$(echo "$COMBINED" | jq 'flatten')

  # Merge into existing settings (append to existing hook arrays)
  MERGED_JSON=$(echo "$MERGED_JSON" | jq --arg ht "$hook_type" --argjson hooks "$FLAT" \
    '.hooks[$ht] = ((.hooks[$ht] // []) + $hooks)')
done

echo "$MERGED_JSON" | jq '.' > "$SETTINGS"

# Write manifest
jq -n \
  --argjson links "$(printf '%s\n' "${LINKS[@]+"${LINKS[@]}"}" | jq -R . | jq -s .)" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{createdAt: $timestamp, links: $links}' > "$MANIFEST"

echo ""
echo "Setup complete:"
echo "  Symlinks: ${#LINKS[@]}"
echo "  Hooks merged into: $SETTINGS"
echo "  Manifest: $MANIFEST"
echo ""
echo "Reload with /reload to apply. Re-run /agent-dev setup to refresh."
