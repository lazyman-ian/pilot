#!/bin/bash
# agent-dev pipeline gate checker
# Usage: agent-dev-gate.sh <gate-name> [cwd]
# Exit 0 = pass, Exit 2 = block (message on stderr)

GATE="$1"
CWD="${2:-$PWD}"

# Find .agent-dev/state.json by walking up from CWD
STATE=""
DIR="$CWD"
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/.agent-dev/state.json" ]; then
    STATE="$DIR/.agent-dev/state.json"
    break
  fi
  DIR=$(dirname "$DIR")
done

# No state file = no pipeline active, allow everything
[ -z "$STATE" ] && exit 0

# Check jq is available
if ! command -v jq &>/dev/null; then
  echo "WARNING: jq not installed, agent-dev gate check skipped" >&2
  exit 0
fi

PHASE=$(jq -r '.phase // empty' "$STATE" 2>/dev/null)

case "$GATE" in
  pre-pr)
    # Gate: can't create PR without code review
    case "$PHASE" in
      PR|COMPLETED) exit 0 ;;
      *)
        echo "BLOCKED: Cannot create PR — pipeline is in phase '$PHASE', expected PR." >&2
        echo "Complete code review first." >&2
        exit 2
        ;;
    esac
    ;;
  validate-state)
    # Gate: state.json must be valid JSON with required fields
    if ! jq -e '.phase and .pipelineId' "$STATE" >/dev/null 2>&1; then
      echo "WARNING: state.json is malformed or missing required fields." >&2
    fi
    # Don't block on validation, just warn
    exit 0
    ;;
  *)
    # Unknown gate, allow
    exit 0
    ;;
esac
