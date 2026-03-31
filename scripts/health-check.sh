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

# Source shared formatting helpers (optional — script directory may differ)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/error-fmt.sh
[[ -f "$SCRIPT_DIR/lib/error-fmt.sh" ]] && source "$SCRIPT_DIR/lib/error-fmt.sh"

PHASE=$(jq -r '.currentPhase // .phase // empty' "$STATE_FILE" 2>/dev/null)

# Terminal states — not stalled, nothing to do
case "$PHASE" in
  COMPLETED|FAILED|ESCALATED|"") exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Determine last-updated epoch
# Prefer updatedAt from state.json (ISO-8601); fall back to file mtime.
# ---------------------------------------------------------------------------
UPDATED_AT=$(jq -r '.updatedAt // empty' "$STATE_FILE" 2>/dev/null)

if [[ -n "$UPDATED_AT" ]]; then
  # Cross-platform ISO-8601 → epoch
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS: strip sub-second + timezone, parse with -jf
    _ts="${UPDATED_AT%.*}"          # drop fractional seconds if present
    _ts="${_ts%Z}"                  # drop trailing Z
    _ts="${_ts%+??:??}"             # drop +HH:MM offset if present
    FILE_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%S" "$_ts" +%s 2>/dev/null)
  else
    # Linux: date -d understands ISO-8601 natively
    FILE_EPOCH=$(date -d "$UPDATED_AT" +%s 2>/dev/null)
  fi
fi

# Fall back to file mtime if updatedAt was missing or unparseable
if [[ -z "$FILE_EPOCH" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    FILE_EPOCH=$(stat -f '%m' "$STATE_FILE" 2>/dev/null)
  else
    FILE_EPOCH=$(stat -c '%Y' "$STATE_FILE" 2>/dev/null)
  fi
fi

NOW_EPOCH=$(date +%s)
STALE_SEC=$(( NOW_EPOCH - FILE_EPOCH ))
STALE_MIN=$(( STALE_SEC / 60 ))

if [[ $STALE_MIN -ge $STALE_THRESHOLD_MIN ]]; then
  TARGET=$(jq -r '.targetProject // "unknown"' "$STATE_FILE" 2>/dev/null)
  STEP=$(jq -r '.currentStep // ""' "$STATE_FILE" 2>/dev/null)

  BODY="Phase: $PHASE | Project: $TARGET | No update for ${STALE_MIN}min"
  [[ -n "$STEP" ]] && BODY="$BODY (step $STEP)"
  HINT="Run 'claude /pilot resume' or check for a stuck subagent."

  # macOS notification
  if command -v osascript &>/dev/null; then
    osascript -e "display notification \"$BODY — $HINT\" with title \"pilot stalled\" sound name \"Ping\"" 2>/dev/null || true
  fi

  # Output for cron/hook consumption
  echo "WARNING STALLED: $BODY"
  echo "HINT: $HINT"
  exit 0
fi

# Not stale
echo "OK: phase=$PHASE, last update ${STALE_MIN}min ago"
exit 0
