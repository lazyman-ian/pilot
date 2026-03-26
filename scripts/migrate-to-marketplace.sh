#!/bin/bash
# Migrate agent-dev plugin into housesigma/claude-plugins marketplace monorepo.
#
# What it does:
#   1. Clones claude-plugins (or uses existing clone)
#   2. Copies plugin files into claude-plugins/agent-dev/
#   3. Adds agent-dev entry to marketplace.json
#   4. Commits and creates a PR
#
# Usage:
#   bash scripts/migrate-to-marketplace.sh [/path/to/claude-plugins]
#
# If no path given, clones to a temp directory.

set -euo pipefail

AGENT_DEV_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_NAME="agent-dev"
PLUGIN_VERSION=$(jq -r '.version' "$AGENT_DEV_ROOT/.claude-plugin/plugin.json")
BRANCH="feat/add-${PLUGIN_NAME}-v${PLUGIN_VERSION}"

# --- Resolve claude-plugins path ---
if [ -n "${1:-}" ] && [ -d "$1" ]; then
  MARKETPLACE_ROOT="$(cd "$1" && pwd)"
  echo "Using existing clone: $MARKETPLACE_ROOT"
else
  MARKETPLACE_ROOT=$(mktemp -d)/claude-plugins
  echo "Cloning housesigma/claude-plugins..."
  git clone --depth 1 git@github.com:housesigma/claude-plugins.git "$MARKETPLACE_ROOT"
fi

TARGET_DIR="$MARKETPLACE_ROOT/$PLUGIN_NAME"

# --- Safety check ---
if [ -d "$TARGET_DIR" ] && [ "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
  echo "WARNING: $TARGET_DIR already exists and is not empty."
  echo "This will REPLACE its contents. Continue? [y/N]"
  read -r CONFIRM
  [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "Aborted."; exit 1; }
  rm -rf "$TARGET_DIR"
fi

# --- Copy plugin files (exclude dev-only artifacts) ---
echo "Copying plugin files to $TARGET_DIR..."
mkdir -p "$TARGET_DIR"

# Directories to copy
for dir in .claude-plugin agents commands hooks scripts skills; do
  [ -d "$AGENT_DEV_ROOT/$dir" ] && cp -R "$AGENT_DEV_ROOT/$dir" "$TARGET_DIR/$dir"
done

# Root files to copy
for file in .mcp.json .lsp.json CLAUDE.md README.md LICENSE .gitignore; do
  [ -f "$AGENT_DEV_ROOT/$file" ] && cp "$AGENT_DEV_ROOT/$file" "$TARGET_DIR/$file"
done

# --- Excluded (dev-only, not copied): ---
# TEST-RESULTS*.md, articles/, docs/superpowers/, .claude/ (project memory)
echo "Excluded dev-only files: TEST-RESULTS*, articles/, docs/, .claude/"

# --- Update marketplace.json ---
MARKETPLACE_JSON="$MARKETPLACE_ROOT/.claude-plugin/marketplace.json"
if [ -f "$MARKETPLACE_JSON" ]; then
  # Check if agent-dev already in marketplace
  EXISTING=$(jq -r ".plugins[] | select(.name == \"$PLUGIN_NAME\") | .name" "$MARKETPLACE_JSON" 2>/dev/null)
  if [ -n "$EXISTING" ]; then
    echo "Updating existing '$PLUGIN_NAME' entry in marketplace.json (version → $PLUGIN_VERSION)..."
    TMP="${MARKETPLACE_JSON}.tmp.$$"
    jq --arg name "$PLUGIN_NAME" --arg ver "$PLUGIN_VERSION" \
      '(.plugins[] | select(.name == $name)).version = $ver' \
      "$MARKETPLACE_JSON" > "$TMP" && mv "$TMP" "$MARKETPLACE_JSON"
  else
    echo "Adding '$PLUGIN_NAME' to marketplace.json..."
    DESCRIPTION=$(jq -r '.description' "$AGENT_DEV_ROOT/.claude-plugin/plugin.json")
    AUTHOR=$(jq -r '.author.name' "$AGENT_DEV_ROOT/.claude-plugin/plugin.json")
    TMP="${MARKETPLACE_JSON}.tmp.$$"
    jq --arg name "$PLUGIN_NAME" \
       --arg desc "$DESCRIPTION" \
       --arg ver "$PLUGIN_VERSION" \
       --arg author "$AUTHOR" \
       --arg source "./$PLUGIN_NAME" \
       '.plugins += [{
         "name": $name,
         "description": $desc,
         "version": $ver,
         "author": { "name": $author },
         "source": $source
       }]' "$MARKETPLACE_JSON" > "$TMP" && mv "$TMP" "$MARKETPLACE_JSON"
  fi
else
  echo "ERROR: marketplace.json not found at $MARKETPLACE_JSON" >&2
  exit 1
fi

# --- Git operations ---
cd "$MARKETPLACE_ROOT"

echo ""
echo "=== Files staged ==="
git add "$PLUGIN_NAME/" .claude-plugin/marketplace.json
git status --short

echo ""
echo "Create branch '$BRANCH' and commit? [y/N]"
read -r CONFIRM
if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
  git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"
  git commit -m "feat: add $PLUGIN_NAME plugin v$PLUGIN_VERSION

Autonomous development pipeline: Notion requirement → draft PR.
Migrated from housesigma/agent-dev standalone repo."

  echo ""
  echo "Push and create PR? [y/N]"
  read -r CONFIRM_PR
  if [ "$CONFIRM_PR" = "y" ] || [ "$CONFIRM_PR" = "Y" ]; then
    git push -u origin "$BRANCH"
    gh pr create --title "feat: add $PLUGIN_NAME plugin v$PLUGIN_VERSION" --body "$(cat <<EOF
## Summary
- Add \`$PLUGIN_NAME\` plugin to marketplace (v$PLUGIN_VERSION)
- Autonomous development pipeline: Notion requirement → draft PR
- Migrated from \`housesigma/agent-dev\` standalone repo

## Plugin capabilities
- 9-phase pipeline: FETCH → RESOLVE → DESIGN → REVIEW → PLAN → IMPLEMENT → CODE_REVIEW → PR
- 4 Opus subagents: tech-designer, design-reviewer, implementer, code-reviewer
- Script-enforced quality gates (validate-artifacts.sh dispatcher)
- Interactive QA via Chrome DevTools MCP
- Multi-project support with cross-project context

## Installation
\`\`\`
claude plugin install github:housesigma/claude-plugins --name agent-dev
\`\`\`
EOF
)"
    echo ""
    echo "✅ PR created."
  fi
else
  echo ""
  echo "Skipped commit. Files are staged in: $MARKETPLACE_ROOT"
  echo "You can review and commit manually."
fi

echo ""
echo "=== Migration summary ==="
echo "Source:      $AGENT_DEV_ROOT"
echo "Target:      $TARGET_DIR"
echo "Version:     $PLUGIN_VERSION"
echo "Marketplace: $MARKETPLACE_JSON"
echo ""
echo "Next steps after merge:"
echo "  1. Archive housesigma/agent-dev repo (Settings → Archive)"
echo "  2. Update CLAUDE.md repository URL"
echo "  3. Future development happens in claude-plugins/agent-dev/"
