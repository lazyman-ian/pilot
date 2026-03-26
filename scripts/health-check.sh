#!/bin/bash
# pilot pipeline health check
# Detects stalled pipelines and sends macOS notification
# Usage: called by cron/loop monitoring, or standalone
#   health-check.sh [stale_threshold_minutes]

STALE_THRESHOLD_MIN="${1:-10}"
STATE_FILE="$PWD/.pilot/state.json"

# No pipeline active
[[ ! -f "$STATE_FILE" ]] && exit 0
command -v jq &>/dev/null || exit 0

PHASE=$(jq -r '.phase // empty' "$STATE_FILE" 2>/dev/null)

# Terminal states — no check needed
case "$PHASE" in
  COMPLETED|FAILED|ESCALATED|"") exit 0 ;;
esac

# Check staleness: compare state.json mtime vs now
if [[ "$(uname)" == "Darwin" ]]; then
  FILE_EPOCH=$(stat -f '%m' "$STATE_FILE" 2>/dev/null)
else
  FILE_EPOCH=$(stat -c '%Y' "$STATE_FILE" 2>/dev/null)
fi
NOW_EPOCH=$(date +%s)
STALE_SEC=$(( NOW_EPOCH - FILE_EPOCH ))
STALE_MIN=$(( STALE_SEC / 60 ))

if [[ $STALE_MIN -ge $STALE_THRESHOLD_MIN ]]; then
  TARGET=$(jq -r '.targetProject // "unknown"' "$STATE_FILE" 2>/dev/null)
  STEP=$(jq -r '.currentStep // ""' "$STATE_FILE" 2>/dev/null)

  MSG="Pipeline stalled: phase=$PHASE, project=$TARGET, no update for ${STALE_MIN}min"
  [[ -n "$STEP" ]] && MSG="$MSG (step $STEP)"

  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$MSG\" with title \"pilot\" sound name \"Ping\""
  fi

  # Output for cron/hook consumption
  echo "WARNING STALLED: $MSG"
  exit 0
fi

# Not stale
echo "OK: phase=$PHASE, last update ${STALE_MIN}min ago"
exit 0
