#!/bin/bash
# Validates review.json: groundingCheck presence + ungrounded API gate
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Check: verdict field exists (is this a review.json?)
if ! jq -e '.verdict' "$FILE" >/dev/null 2>&1; then
  exit 0
fi

VERDICT=$(jq -r '.verdict' "$FILE")

# Check 1: groundingCheck must exist
if ! jq -e '.groundingCheck' "$FILE" >/dev/null 2>&1; then
  echo "BLOCKED: review.json must include groundingCheck field with apiChangesInDesign, groundedInAC, ungrounded counts." >&2
  exit 2
fi

# Check 2: ungrounded > 0 → verdict cannot be APPROVE
UNGROUNDED=$(jq '.groundingCheck.ungrounded // 0' "$FILE" 2>/dev/null)
if [ "${UNGROUNDED:-0}" -gt 0 ] && [ "$VERDICT" = "APPROVE" ]; then
  echo "BLOCKED: $UNGROUNDED ungrounded API change(s) found but verdict is APPROVE. Must be REVISE or ESCALATE." >&2
  exit 2
fi

exit 0
