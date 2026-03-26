#!/bin/bash
# pilot Stop Hook
# Prevents the PIPELINE SESSION from stopping mid-pipeline.
# Session isolation: only blocks the session that started the pipeline.
# Anti-loop: if blocked 3+ times without state change, allow exit.

set -euo pipefail

HOOK_INPUT=$(cat)

STATE_FILE="$PWD/.pilot/state.json"
COUNTER_FILE="$PWD/.pilot/.stop-hook-counter"

[[ ! -f "$STATE_FILE" ]] && exit 0
command -v jq &>/dev/null || exit 0

PHASE=$(jq -r '.phase // empty' "$STATE_FILE" 2>/dev/null)

# Allow exit for terminal states
case "$PHASE" in
  COMPLETED|FAILED|ESCALATED|"") exit 0 ;;
esac

# Session isolation: only block the session that owns this pipeline
PIPELINE_SESSION=$(jq -r '.sessionId // empty' "$STATE_FILE" 2>/dev/null)
HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# Session isolation: only block the session that owns this pipeline
# If no session ID recorded → can't isolate → don't block anyone (safe default)
if [[ -z "$PIPELINE_SESSION" ]]; then
  exit 0
fi
if [[ -n "$HOOK_SESSION" ]] && [[ "$PIPELINE_SESSION" != "$HOOK_SESSION" ]]; then
  exit 0
fi

# Anti-loop: track consecutive blocks without state change
UPDATED=$(jq -r '.updatedAt // empty' "$STATE_FILE" 2>/dev/null)
PREV_UPDATED=""
BLOCK_COUNT=0
if [[ -f "$COUNTER_FILE" ]]; then
  PREV_UPDATED=$(head -1 "$COUNTER_FILE" 2>/dev/null || echo "")
  BLOCK_COUNT=$(tail -1 "$COUNTER_FILE" 2>/dev/null || echo "0")
  [[ ! "$BLOCK_COUNT" =~ ^[0-9]+$ ]] && BLOCK_COUNT=0
fi

if [[ "$UPDATED" == "$PREV_UPDATED" ]]; then
  BLOCK_COUNT=$((BLOCK_COUNT + 1))
else
  BLOCK_COUNT=1
fi

echo "$UPDATED" > "$COUNTER_FILE"
echo "$BLOCK_COUNT" >> "$COUNTER_FILE"

# Stuck 3+ times → let it exit
if [[ $BLOCK_COUNT -ge 3 ]]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Build resume prompt
CURRENT_STEP=$(jq -r '.currentStep // empty' "$STATE_FILE" 2>/dev/null)
RESUME="pilot pipeline active (phase: $PHASE). Continue NOW."
RESUME="$RESUME Read .pilot/state.json and phases.md."

case "$PHASE" in
  FETCH)     RESUME="$RESUME Proceed to RESOLVE." ;;
  RESOLVE)   RESUME="$RESUME Resolve project and proceed to DESIGN." ;;
  DESIGN)    RESUME="$RESUME Invoke @pilot:tech-designer." ;;
  REVIEW)    RESUME="$RESUME Invoke @pilot:design-reviewer." ;;
  PLAN)      RESUME="$RESUME Generate plan and proceed to IMPLEMENT." ;;
  IMPLEMENT) RESUME="$RESUME Invoke @pilot:implementer with plan." ;;
  CODE_REVIEW) RESUME="$RESUME Invoke @pilot:code-reviewer." ;;
  VISUAL_CHECK) RESUME="$RESUME Run visual design check (Figma + Chrome DevTools)." ;;
  PR)        RESUME="$RESUME Create draft PR." ;;
  PROJECT_TRANSITION) RESUME="$RESUME Archive artifacts and advance to next project." ;;
esac

jq -n \
  --arg reason "$RESUME" \
  --arg msg "[pilot] pipeline active ($PHASE) — auto-continuing (attempt $BLOCK_COUNT/3)" \
  '{ "decision": "block", "reason": $reason, "systemMessage": $msg }'

exit 0
