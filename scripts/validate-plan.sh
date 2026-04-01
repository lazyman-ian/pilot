#!/bin/bash
# Validates plan.json: acRefs traceability + AC range check + no-placeholders + non-empty files
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block

# shellcheck source=lib/error-fmt.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/error-fmt.sh"

INPUT=$(cat)
_FILE_FROM_STDIN=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
# Fall back to FILE env var when not invoked via stdin (manual fixture tests)
FILE="${_FILE_FROM_STDIN:-${FILE:-}}"

[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Check: steps array exists
if ! jq -e '.steps' "$FILE" >/dev/null 2>&1; then
  exit 0  # Not a plan.json we recognize — pass through
fi

# Check 1: Every non-scaffolding step must have non-empty acRefs
EMPTY_REFS=$(jq '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0)] | length' "$FILE" 2>/dev/null)
if [ "${EMPTY_REFS:-0}" -gt 0 ]; then
  NAMES=$(jq -r '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0) | "Step \(.index // "?"): \(.title // .description // "untitled")"] | join(", ")' "$FILE" 2>/dev/null)
  pilot_blocked \
    "plan.json has $EMPTY_REFS step(s) with empty acRefs" \
    "Every non-scaffolding step must trace to at least one AC, or set scaffolding:true." \
    "Add acRefs (e.g. [\"AC-1\"]) to each listed step, or mark it scaffolding:true." \
    "Missing: $NAMES" >&2
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
      pilot_blocked \
        "plan.json references AC-$MAX_REF which exceeds requirement AC count ($AC_COUNT)" \
        "acRefs must only reference ACs that exist in requirement.json." \
        "Lower the acRef to AC-$AC_COUNT or below, or add the missing AC to requirement.json." >&2
      exit 2
    fi
  fi
fi

# Check 3: No placeholder language in step descriptions
PLACEHOLDER_PATTERN='(TBD|TODO|待定|后续补充|implement later|add appropriate)'
PLACEHOLDER_COUNT=$(jq --arg pat "$PLACEHOLDER_PATTERN" \
  '[.steps[] | select(.scaffolding != true) | select(.description // "" | test($pat; "i"))] | length' \
  "$FILE" 2>/dev/null)
if [ "${PLACEHOLDER_COUNT:-0}" -gt 0 ]; then
  OFFENDERS=$(jq -r --arg pat "$PLACEHOLDER_PATTERN" \
    '[.steps[] | select(.scaffolding != true) | select(.description // "" | test($pat; "i")) | "Step \(.index // "?"): \(.title // "untitled") — \(.description // "")"] | join("\n")' \
    "$FILE" 2>/dev/null)
  pilot_blocked \
    "plan.json has $PLACEHOLDER_COUNT step(s) with placeholder descriptions" \
    "Step descriptions must be concrete — placeholder language (TBD, TODO, 待定, 后续补充, implement later, add appropriate) is not allowed." \
    "Replace placeholder text with a specific, actionable description of what the step implements." \
    "$OFFENDERS" >&2
  exit 2
fi

# Check 4: Non-empty files array for every non-scaffolding step
EMPTY_FILES=$(jq '[.steps[] | select(.scaffolding != true) | select((.files // []) | length == 0)] | length' "$FILE" 2>/dev/null)
if [ "${EMPTY_FILES:-0}" -gt 0 ]; then
  OFFENDERS=$(jq -r '[.steps[] | select(.scaffolding != true) | select((.files // []) | length == 0) | "Step \(.index // "?"): \(.title // .description // "untitled")"] | join(", ")' "$FILE" 2>/dev/null)
  pilot_blocked \
    "plan.json has $EMPTY_FILES step(s) with empty files arrays" \
    "Every non-scaffolding step must list at least one file it creates or modifies." \
    "Add the relevant file paths to the files array for each listed step, or mark the step scaffolding:true if it produces no file output." \
    "Missing: $OFFENDERS" >&2
  exit 2
fi

exit 0
