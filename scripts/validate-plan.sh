#!/bin/bash
# Validates plan.json: acRefs traceability + AC range check
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Check: steps array exists
if ! jq -e '.steps' "$FILE" >/dev/null 2>&1; then
  exit 0  # Not a plan.json we recognize — pass through
fi

# Check 1: Every non-scaffolding step must have non-empty acRefs
EMPTY_REFS=$(jq '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0)] | length' "$FILE" 2>/dev/null)
if [ "${EMPTY_REFS:-0}" -gt 0 ]; then
  NAMES=$(jq -r '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0) | "Step \(.index): \(.title)"] | join(", ")' "$FILE" 2>/dev/null)
  echo "BLOCKED: $EMPTY_REFS step(s) have empty acRefs — each must trace to an AC or set scaffolding:true. Missing: $NAMES" >&2
  exit 2
fi

# Check 2: All AC-N references within range of requirement.json
AGENT_DEV_DIR=$(dirname "$FILE")
REQ_FILE="$AGENT_DEV_DIR/requirement.json"
if [ -f "$REQ_FILE" ]; then
  AC_COUNT=$(jq '.acceptanceCriteria | length' "$REQ_FILE" 2>/dev/null)
  if [ -n "$AC_COUNT" ] && [ "$AC_COUNT" -gt 0 ]; then
    MAX_REF=$(jq '[.steps[].acRefs[]? | select(startswith("AC-")) | ltrimstr("AC-") | tonumber] | if length > 0 then max else 0 end' "$FILE" 2>/dev/null)
    if [ "${MAX_REF:-0}" -gt "$AC_COUNT" ]; then
      echo "BLOCKED: acRef AC-$MAX_REF exceeds requirement AC count ($AC_COUNT)." >&2
      exit 2
    fi
  fi
fi

exit 0
