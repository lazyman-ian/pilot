#!/bin/bash
# PostToolUse(Write) dispatcher — routes artifact writes to validators
# Exit 0 = pass, Exit 2 = block (message on stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# No file path → pass through
[ -z "$FILE" ] && exit 0

# Route based on file name within .pilot/
case "$FILE" in
  */.pilot/state.json)
    # Inline the existing patch-state-session logic
    [ ! -f "$FILE" ] && exit 0
    command -v jq &>/dev/null || exit 0
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    [ -z "$SESSION_ID" ] && exit 0
    TMP="${FILE}.tmp.$$"
    jq --arg sid "$SESSION_ID" '.sessionId = $sid' "$FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$FILE"
    if ! jq -e '.phase and .pipelineId' "$FILE" >/dev/null 2>&1; then
      echo "WARNING: state.json missing required fields." >&2
    fi
    exit 0
    ;;
  */.pilot/plan.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-plan.sh"
    ;;
  */.pilot/code-review.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-code-review.sh"
    ;;
  */.pilot/review.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-review.sh"
    ;;
  *)
    exit 0
    ;;
esac
