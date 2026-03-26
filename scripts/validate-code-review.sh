#!/bin/bash
# Validates code-review.json: scoring constraints + rubric consistency
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block, warnings on stderr

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Check: verdict field exists (is this a code-review.json?)
if ! jq -e '.verdict' "$FILE" >/dev/null 2>&1; then
  exit 0
fi

VERDICT=$(jq -r '.verdict' "$FILE")
CONFIDENCE=$(jq -r '.confidence // 0' "$FILE")

# Check 1: FIX_REQUIRED → confidence ≤ 72
if [ "$VERDICT" = "FIX_REQUIRED" ] && [ "$CONFIDENCE" -gt 72 ]; then
  echo "BLOCKED: FIX_REQUIRED verdict with confidence $CONFIDENCE > 72. Lower confidence to reflect issues found." >&2
  exit 2
fi

# Check 2: rubricScores must exist with exactly 4 dimensions
RUBRIC_COUNT=$(jq '.rubricScores | keys | length' "$FILE" 2>/dev/null)
if [ "${RUBRIC_COUNT:-0}" -ne 4 ]; then
  echo "BLOCKED: rubricScores must have exactly 4 dimensions (correctness, completeness, convention, regression). Found: ${RUBRIC_COUNT:-0}." >&2
  exit 2
fi

# Check 3: Any rubric dimension < 5 → verdict must be FIX_REQUIRED
MIN_SCORE=$(jq '[.rubricScores[]] | min' "$FILE" 2>/dev/null)
if [ "${MIN_SCORE:-10}" -lt 5 ] && [ "$VERDICT" != "FIX_REQUIRED" ]; then
  echo "BLOCKED: Rubric score $MIN_SCORE < 5 requires FIX_REQUIRED verdict, got $VERDICT." >&2
  exit 2
fi

# Check 4: confidence ≈ floor(mean(rubricScores) * 10), tolerance ±5
EXPECTED=$(jq '[.rubricScores[]] | add / length * 10 | floor' "$FILE" 2>/dev/null)
if [ -n "$EXPECTED" ]; then
  DIFF=$(( CONFIDENCE - EXPECTED ))
  ABS_DIFF=${DIFF#-}
  if [ "$ABS_DIFF" -gt 5 ]; then
    echo "BLOCKED: confidence $CONFIDENCE diverges from rubric mean $EXPECTED by $ABS_DIFF (max ±5). Recalculate." >&2
    exit 2
  fi
fi

# Warning 5: Early-stop eligibility hint
if [ "$MIN_SCORE" -ge 8 ] && [ "$VERDICT" != "APPROVE" ]; then
  TEST_RESULT=$(jq -r '.testResult // "UNKNOWN"' "$FILE")
  LINT_RESULT=$(jq -r '.lintResult // "UNKNOWN"' "$FILE")
  QA_RESULT=$(jq -r '.qaResult // "SKIPPED"' "$FILE")
  if [ "$TEST_RESULT" = "PASS" ] && [ "$LINT_RESULT" = "PASS" ] && [ "$QA_RESULT" != "FAIL" ]; then
    echo "WARNING: All rubric scores ≥ 8, tests/lint pass, qa not failed — consider APPROVE." >&2
  fi
fi

# Warning 6: QA missing hint for web-hybrid
QA_RESULT=$(jq -r '.qaResult // "MISSING"' "$FILE")
if [ "$QA_RESULT" = "MISSING" ]; then
  AGENT_DEV_DIR=$(dirname "$FILE")
  STATE_FILE="$AGENT_DEV_DIR/state.json"
  if [ -f "$STATE_FILE" ]; then
    TARGET=$(jq -r '.targetProject // ""' "$STATE_FILE" 2>/dev/null)
    if [ "$TARGET" = "web-hybrid" ]; then
      echo "WARNING: web-hybrid project but qaResult missing from code-review.json." >&2
    fi
  fi
fi

exit 0
