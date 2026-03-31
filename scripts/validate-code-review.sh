#!/bin/bash
# Validates code-review.json: scoring constraints + rubric consistency
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block, warnings on stderr

# Source shared formatting helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/error-fmt.sh
source "$SCRIPT_DIR/lib/error-fmt.sh"

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
  pilot_blocked \
    "FIX_REQUIRED verdict with confidence $CONFIDENCE > 72" \
    "High confidence contradicts FIX_REQUIRED — if issues are minor enough for high confidence, verdict should be APPROVE." \
    "Lower confidence to ≤ 72 to reflect the issues found, or change verdict to APPROVE if issues are resolved." >&2
  exit 2
fi

# Check 2: rubricScores must exist with exactly 4 dimensions
RUBRIC_COUNT=$(jq '.rubricScores | keys | length' "$FILE" 2>/dev/null)
if [ "${RUBRIC_COUNT:-0}" -ne 4 ]; then
  pilot_blocked \
    "rubricScores must have exactly 4 dimensions, found: ${RUBRIC_COUNT:-0}" \
    "The rubric requires: correctness, completeness, convention, regression." \
    "Add all 4 dimensions to rubricScores." >&2
  exit 2
fi

# Check 3: Any rubric dimension < 5 → verdict must be FIX_REQUIRED
MIN_SCORE=$(jq '[.rubricScores[]] | min' "$FILE" 2>/dev/null)
if [ "${MIN_SCORE:-10}" -lt 5 ] && [ "$VERDICT" != "FIX_REQUIRED" ]; then
  pilot_blocked \
    "Rubric score $MIN_SCORE < 5 requires FIX_REQUIRED verdict, got $VERDICT" \
    "A rubric dimension below 5 indicates a critical problem that must be fixed before approval." \
    "Change verdict to FIX_REQUIRED and describe the specific issues in the issues array." >&2
  exit 2
fi

# Check 4: confidence ≈ floor(mean(rubricScores) * 10), tolerance ±5
EXPECTED=$(jq '[.rubricScores[]] | add / length * 10 | floor' "$FILE" 2>/dev/null)
if [ -n "$EXPECTED" ]; then
  DIFF=$(( CONFIDENCE - EXPECTED ))
  ABS_DIFF=${DIFF#-}
  if [ "$ABS_DIFF" -gt 5 ]; then
    pilot_blocked \
      "confidence $CONFIDENCE diverges from rubric mean $EXPECTED by $ABS_DIFF (max ±5)" \
      "confidence must be approximately floor(mean(rubricScores) * 10) within ±5." \
      "Recalculate confidence as floor(mean(rubricScores) * 10) = $EXPECTED (±5 allowed)." >&2
    exit 2
  fi
fi

# Warning 5: Early-stop eligibility hint
if [ "${MIN_SCORE:-0}" -ge 8 ] && [ "$VERDICT" != "APPROVE" ]; then
  TEST_RESULT=$(jq -r '.testResult // "UNKNOWN"' "$FILE")
  LINT_RESULT=$(jq -r '.lintResult // "UNKNOWN"' "$FILE")
  QA_RESULT=$(jq -r '.qaResult // "SKIPPED"' "$FILE")
  if [ "$TEST_RESULT" = "PASS" ] && [ "$LINT_RESULT" = "PASS" ] && [ "$QA_RESULT" != "FAIL" ]; then
    pilot_warn "Early-stop eligible" "All rubric scores ≥ 8, tests/lint pass, qa not failed — consider APPROVE." >&2
  fi
fi

# Warning 6: QA missing hint for web-hybrid or iOS
QA_RESULT=$(jq -r '.qaResult // "MISSING"' "$FILE")
if [ "$QA_RESULT" = "MISSING" ]; then
  AGENT_DEV_DIR=$(dirname "$FILE")
  STATE_FILE="$AGENT_DEV_DIR/state.json"
  if [ -f "$STATE_FILE" ]; then
    TARGET=$(jq -r '.targetProject // ""' "$STATE_FILE" 2>/dev/null)
    if [ "$TARGET" = "web-hybrid" ]; then
      pilot_warn "qaResult missing" "web-hybrid project but qaResult missing from code-review.json." >&2
    elif echo "$TARGET" | grep -q "ios"; then
      pilot_warn "qaResult missing" "iOS project but qaResult missing from code-review.json." >&2
    fi
  fi
fi

# Warning 7: qaResult present but qaMethod missing
if [ "$QA_RESULT" != "SKIPPED" ] && [ "$QA_RESULT" != "MISSING" ]; then
  QA_METHOD=$(jq -r '.qaMethod // "MISSING"' "$FILE")
  if [ "$QA_METHOD" = "MISSING" ]; then
    pilot_warn "qaMethod missing" "qaResult is $QA_RESULT but qaMethod field is missing. Expected: chrome-devtools, xcode-mcp, or skipped." >&2
  fi
fi

# ── New checks for two-stage review fields ─────────────────────────────────

# Check 8 (§2.1): planCoverage enforcement — only when verdict=APPROVE
if [ "$VERDICT" = "APPROVE" ]; then
  HAS_PLAN_COVERAGE=$(jq -r '.planCoverage // empty' "$FILE" 2>/dev/null)
  if [ -z "$HAS_PLAN_COVERAGE" ]; then
    pilot_blocked \
      "APPROVE without planCoverage field" \
      "Two-stage review requires planCoverage proving all plan steps were completed (§2.1)" \
      "Add planCoverage object with total, completed, removed, and steps array" \
      ".pilot/code-review.json → planCoverage" >&2
    exit 2
  fi
  PLAN_TOTAL=$(jq -r '.planCoverage.total // 0' "$FILE" 2>/dev/null)
  if [ "${PLAN_TOTAL:-0}" -gt 0 ]; then
    PLAN_COMPLETED=$(jq -r '.planCoverage.completed // 0' "$FILE" 2>/dev/null)
    PLAN_REMOVED=$(jq -r '.planCoverage.removed // 0' "$FILE" 2>/dev/null)
    EFFECTIVE=$(( PLAN_COMPLETED + PLAN_REMOVED ))
    if [ "$EFFECTIVE" -lt "$PLAN_TOTAL" ]; then
      pilot_blocked \
        "planCoverage incomplete: $EFFECTIVE of $PLAN_TOTAL steps covered (completed=$PLAN_COMPLETED, removed=$PLAN_REMOVED)" \
        "APPROVE requires all plan steps to be either completed or explicitly removed." \
        "Mark remaining steps as completed or removed (with removedReason) before approving." \
        "planCoverage.total=$PLAN_TOTAL effective=$EFFECTIVE" >&2
      exit 2
    fi

    # Every step with status="removed" must have a non-empty removedReason
    MISSING_REASON=$(jq '[.planCoverage.steps // [] | .[] | select(.status == "removed" and (.removedReason == null or .removedReason == ""))] | length' "$FILE" 2>/dev/null)
    if [ "${MISSING_REASON:-0}" -gt 0 ]; then
      pilot_blocked \
        "planCoverage has $MISSING_REASON removed step(s) with no removedReason" \
        "Every step marked status=removed must explain why it was removed." \
        "Add a non-empty removedReason to each removed step." >&2
      exit 2
    fi
  fi
fi

# Check 9 (§2.3): verificationSummary enforcement — only when verdict=APPROVE
if [ "$VERDICT" = "APPROVE" ]; then
  VS_TYPE=$(jq -r '.verificationSummary.type // ""' "$FILE" 2>/dev/null)
  if [ -z "$VS_TYPE" ]; then
    pilot_blocked \
      "verificationSummary.type is missing or empty" \
      "APPROVE requires verificationSummary.type to document how the implementation was verified." \
      "Add verificationSummary.type (e.g. \"test\", \"build\", \"manual\") to code-review.json." >&2
    exit 2
  fi

  # Check command, output, exitCode are present
  VS_CMD=$(jq -r '.verificationSummary.command // empty' "$FILE" 2>/dev/null)
  VS_OUTPUT=$(jq -r '.verificationSummary.output // empty' "$FILE" 2>/dev/null)
  VS_EXIT=$(jq -r '.verificationSummary.exitCode // empty' "$FILE" 2>/dev/null)
  if [ -z "$VS_CMD" ] || [ -z "$VS_OUTPUT" ] || [ -z "$VS_EXIT" ]; then
    pilot_blocked \
      "APPROVE with incomplete verificationSummary" \
      "Verification Iron Law requires concrete evidence: command, output, and exitCode (§2.3)" \
      "Add all fields: {\"type\":\"test\",\"command\":\"npx vitest run\",\"output\":\"...\",\"exitCode\":0}" \
      ".pilot/code-review.json → verificationSummary" >&2
    exit 2
  fi

  # If plan.json exists and has any test-first step, verificationSummary.type must be "test"
  PILOT_DIR=$(dirname "$FILE")
  PLAN_FILE="$PILOT_DIR/plan.json"
  if [ -f "$PLAN_FILE" ]; then
    TEST_FIRST_COUNT=$(jq '[.steps // [] | .[] | select(.posture == "test-first")] | length' "$PLAN_FILE" 2>/dev/null)
    if [ "${TEST_FIRST_COUNT:-0}" -gt 0 ] && [ "$VS_TYPE" != "test" ]; then
      pilot_blocked \
        "verificationSummary.type is \"$VS_TYPE\" but plan has $TEST_FIRST_COUNT test-first step(s)" \
        "When the plan includes test-first (TDD) steps, verification must be confirmed via tests." \
        "Set verificationSummary.type to \"test\" to reflect TDD coverage." \
        "plan.json test-first steps=$TEST_FIRST_COUNT" >&2
      exit 2
    fi
  fi
fi

# Check 10 (§1.1): concernsResolution enforcement — only when verdict=APPROVE
PILOT_DIR=$(dirname "$FILE")
CONCERNS_FILE="$PILOT_DIR/concerns.json"
if [ -f "$CONCERNS_FILE" ] && [ "$VERDICT" = "APPROVE" ]; then
  CONCERNS_COUNT=$(jq '.concerns | length' "$CONCERNS_FILE" 2>/dev/null || echo 0)
  if [ "${CONCERNS_COUNT:-0}" -gt 0 ]; then
    # Check unique concernIndex coverage — each concern must have exactly one resolution
    UNIQUE_INDICES=$(jq '[.concernsResolution[]?.concernIndex] | unique | length' "$FILE" 2>/dev/null || echo 0)
    if [ "${UNIQUE_INDICES:-0}" -lt "${CONCERNS_COUNT:-0}" ]; then
      pilot_blocked \
        "APPROVE with incomplete concernsResolution ($UNIQUE_INDICES unique indices / $CONCERNS_COUNT concerns)" \
        "Every concern must have a unique concernIndex in concernsResolution (§1.1)" \
        "Ensure each concern has exactly one resolution entry with its concernIndex" \
        ".pilot/code-review.json → concernsResolution[].concernIndex" >&2
      exit 2
    fi

    # Any concern with resolution="confirmed" blocks APPROVE
    CONFIRMED_COUNT=$(jq '[.concernsResolution[]? | select(.resolution == "confirmed")] | length' "$FILE" 2>/dev/null || echo 0)
    if [ "${CONFIRMED_COUNT:-0}" -gt 0 ]; then
      pilot_blocked \
        "APPROVE with $CONFIRMED_COUNT confirmed (unresolved) concern(s)" \
        "Confirmed concerns indicate real issues — cannot APPROVE (§1.1)" \
        "Change verdict to FIX_REQUIRED or resolve the confirmed concerns" \
        ".pilot/code-review.json → concernsResolution[].resolution" >&2
      exit 2
    fi
  fi
fi

exit 0
