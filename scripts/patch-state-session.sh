#!/bin/bash
# PostToolUse(Write) hook: auto-inject sessionId into state.json
# Also validates state.json structure

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only act on state.json writes
echo "$FILE" | grep -q '.pilot/state.json' || exit 0
[ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Get session ID from hook input
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

# Always inject the real session ID (overwrite whatever the agent wrote)
TMP="${FILE}.tmp.$$"
jq --arg sid "$SESSION_ID" '.sessionId = $sid' "$FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$FILE"

# Validate required fields
if ! jq -e '.phase and .pipelineId' "$FILE" >/dev/null 2>&1; then
  echo "WARNING: state.json missing required fields." >&2
fi

exit 0
