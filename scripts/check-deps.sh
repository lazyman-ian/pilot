#!/bin/bash
# Check agent-dev plugin dependencies and setup freshness on session start

WARNINGS=""

# LSP servers
command -v typescript-language-server &>/dev/null || WARNINGS="$WARNINGS typescript-language-server(npm i -g typescript-language-server typescript)"
command -v sourcekit-lsp &>/dev/null || true  # optional, Xcode-only
command -v kotlin-language-server &>/dev/null || true  # optional
command -v intelephense &>/dev/null || true  # optional

# Required tools
command -v jq &>/dev/null || WARNINGS="$WARNINGS jq(brew install jq)"
command -v gh &>/dev/null || WARNINGS="$WARNINGS gh(brew install gh)"

# Check if monorepo setup is stale
MANIFEST="$PWD/.claude/.agent-dev-setup.json"
if [ -f "$MANIFEST" ]; then
  # Get manifest creation time (epoch)
  if [ "$(uname)" = "Darwin" ]; then
    MANIFEST_EPOCH=$(stat -f '%m' "$MANIFEST" 2>/dev/null || echo 0)
  else
    MANIFEST_EPOCH=$(stat -c '%Y' "$MANIFEST" 2>/dev/null || echo 0)
  fi

  # Find newest file in any sub-project's .claude/
  NEWEST=0
  for dir in "$PWD"/*/; do
    [ -d "$dir.git" ] && [ -d "$dir.claude" ] || continue
    if [ "$(uname)" = "Darwin" ]; then
      ts=$(find "$dir.claude" -type f -exec stat -f '%m' {} \; 2>/dev/null | sort -rn | head -1)
    else
      ts=$(find "$dir.claude" -type f -exec stat -c '%Y' {} \; 2>/dev/null | sort -rn | head -1)
    fi
    [ -n "$ts" ] && [ "$ts" -gt "$NEWEST" ] && NEWEST=$ts
  done

  if [ "$NEWEST" -gt "$MANIFEST_EPOCH" ]; then
    WARNINGS="$WARNINGS | Setup stale: sub-project .claude/ changed. Run /agent-dev setup to refresh."
  fi
elif ls "$PWD"/*/.claude/settings.json &>/dev/null 2>&1; then
  # Manifest doesn't exist but sub-projects have .claude/ — suggest initial setup
  WARNINGS="$WARNINGS | Monorepo detected with sub-project .claude/ configs. Run /agent-dev setup to merge capabilities."
fi

if [ -n "$WARNINGS" ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"agent-dev:$WARNINGS\"}}"
fi

exit 0
