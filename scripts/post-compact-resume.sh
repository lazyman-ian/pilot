#!/bin/bash
# Post-compaction context restoration for pilot pipeline
# Reads state.json and produces a resume context for the parent agent

# .pilot/ always lives in CWD (monorepo root)
STATE="$PWD/.pilot/state.json"
[ ! -f "$STATE" ] && STATE=""

# No pipeline active — nothing to inject
[ -z "$STATE" ] && exit 0

# Check jq
command -v jq &>/dev/null || exit 0

PILOT_DIR="$PWD/.pilot"

PHASE=$(jq -r '.phase // empty' "$STATE" 2>/dev/null)
PROJECT_DIR=$(jq -r '.projectDir // empty' "$STATE" 2>/dev/null)
TARGET=$(jq -r '.targetProject // empty' "$STATE" 2>/dev/null)
BRANCH=$(jq -r '.branch // empty' "$STATE" 2>/dev/null)
STEP=$(jq -r '.currentStep // empty' "$STATE" 2>/dev/null)
TOTAL=$(jq -r '.completedSteps | length' "$STATE" 2>/dev/null)
NOTION=$(jq -r '.notionUrl // empty' "$STATE" 2>/dev/null)
QUEUE_LEN=$(jq -r '.projectQueue | length // 0' "$STATE" 2>/dev/null)
QUEUE_IDX=$(jq -r '.currentProjectIndex // 0' "$STATE" 2>/dev/null)
COMPLETED_PROJECTS=$(jq -r '.completedProjects | length // 0' "$STATE" 2>/dev/null)
UPDATED_AT=$(jq -r '.updatedAt // empty' "$STATE" 2>/dev/null)

# Don't inject for completed/failed pipelines
case "$PHASE" in
  COMPLETED|FAILED|"") exit 0 ;;
esac

# ---------------------------------------------------------------------------
# Staleness warning
# ---------------------------------------------------------------------------
STALE_WARNING=""
TERMINAL_PHASES="COMPLETED FAILED ESCALATED"

is_terminal() {
  case "$1" in
    COMPLETED|FAILED|ESCALATED) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$UPDATED_AT" ] && ! is_terminal "$PHASE"; then
  NOW_EPOCH=$(date +%s 2>/dev/null)
  # Try macOS strptime format first, fall back to GNU date
  UPDATED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null)
  if [ -z "$UPDATED_EPOCH" ]; then
    UPDATED_EPOCH=$(date -d "$UPDATED_AT" +%s 2>/dev/null)
  fi

  if [ -n "$NOW_EPOCH" ] && [ -n "$UPDATED_EPOCH" ]; then
    ELAPSED=$(( NOW_EPOCH - UPDATED_EPOCH ))
    if [ "$ELAPSED" -gt 900 ]; then
      STALE_MINUTES=$(( ELAPSED / 60 ))
      STALE_WARNING="WARNING: state.json was last updated ${STALE_MINUTES}m ago — verify pipeline state before resuming."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Phase-specific artifact injection
# ---------------------------------------------------------------------------
ARTIFACT_CONTEXT=""

case "$PHASE" in
  DESIGN)
    DESIGN_FILE="$PILOT_DIR/tech-design.md"
    if [ -f "$DESIGN_FILE" ]; then
      DESIGN_HEAD=$(head -n 200 "$DESIGN_FILE" 2>/dev/null)
      ARTIFACT_CONTEXT="tech-design.md (first 200 lines):\n---\n${DESIGN_HEAD}\n---"
    fi
    ;;

  REVIEW)
    REVIEW_FILE="$PILOT_DIR/review.json"
    if [ -f "$REVIEW_FILE" ]; then
      VERDICT=$(jq -r '.verdict // "unknown"' "$REVIEW_FILE" 2>/dev/null)
      FINDINGS=$(jq -r '.keyFindings // .findings // [] | if type == "array" then .[:3] | map("  - " + .) | join("\n") else . end' "$REVIEW_FILE" 2>/dev/null)
      ARTIFACT_CONTEXT="review.json: verdict=${VERDICT}"
      [ -n "$FINDINGS" ] && ARTIFACT_CONTEXT="${ARTIFACT_CONTEXT}\nKey findings:\n${FINDINGS}"
    fi
    ;;

  IMPLEMENT)
    PLAN_FILE="$PILOT_DIR/plan.json"
    if [ -f "$PLAN_FILE" ]; then
      PLAN_STEPS=$(jq -r '.steps | length' "$PLAN_FILE" 2>/dev/null)
      CURRENT_STEP_IDX=$(jq -r '.currentStepIndex // "unknown"' "$PLAN_FILE" 2>/dev/null)
      ARTIFACT_CONTEXT="plan.json: ${PLAN_STEPS} steps total, current step index: ${CURRENT_STEP_IDX}"
    fi
    # Add last commit hash if in a git repo
    if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.git" ]; then
      LAST_COMMIT=$(git -C "$PROJECT_DIR" log --oneline -1 2>/dev/null)
      [ -n "$LAST_COMMIT" ] && ARTIFACT_CONTEXT="${ARTIFACT_CONTEXT}\nLast commit: ${LAST_COMMIT}"
    fi
    ;;

  CODE_REVIEW)
    CR_FILE="$PILOT_DIR/code-review.json"
    if [ -f "$CR_FILE" ]; then
      CR_VERDICT=$(jq -r '.verdict // "unknown"' "$CR_FILE" 2>/dev/null)
      CR_ITER=$(jq -r '.reviewIteration // 1' "$CR_FILE" 2>/dev/null)
      ARTIFACT_CONTEXT="code-review.json: verdict=${CR_VERDICT}, iteration=${CR_ITER}"
    fi
    ;;

  VISUAL_CHECK)
    VR_FILE="$PILOT_DIR/visual-review.json"
    if [ -f "$VR_FILE" ]; then
      VR_VERDICT=$(jq -r '.verdict // "unknown"' "$VR_FILE" 2>/dev/null)
      ARTIFACT_CONTEXT="visual-review.json: verdict=${VR_VERDICT}"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Build resume message
# ---------------------------------------------------------------------------
MSG="pilot pipeline is ACTIVE. DO NOT ask the user what to do — resume automatically."
MSG="$MSG\n\nCurrent state:"
MSG="$MSG\n- Phase: $PHASE"
[ -n "$TARGET" ] && MSG="$MSG\n- Project: $TARGET ($PROJECT_DIR)"
[ -n "$BRANCH" ] && MSG="$MSG\n- Branch: $BRANCH"
[ -n "$STEP" ] && MSG="$MSG\n- Current step: $STEP (completed: $TOTAL)"

[ "$QUEUE_LEN" -gt 1 ] 2>/dev/null && MSG="$MSG\n- Project queue: $((QUEUE_IDX + 1))/$QUEUE_LEN (completed: $COMPLETED_PROJECTS)"

# Inject artifact context if available
if [ -n "$ARTIFACT_CONTEXT" ]; then
  MSG="$MSG\n\nPhase artifact context:\n${ARTIFACT_CONTEXT}"
fi

# Inject staleness warning if applicable
if [ -n "$STALE_WARNING" ]; then
  MSG="$MSG\n\n${STALE_WARNING}"
fi

MSG="$MSG\n\nTo resume:"
MSG="$MSG\n1. Read $STATE for full pipeline state"
case "$PHASE" in
  FETCH)    MSG="$MSG\n2. Check if .pilot/requirement.json exists, continue FETCH" ;;
  RESOLVE)  MSG="$MSG\n2. Continue project resolution" ;;
  DESIGN)   MSG="$MSG\n2. MANDATORY: Read .pilot/requirement.json, invoke @pilot:tech-designer subagent. Do NOT write tech-design.md yourself." ;;
  REVIEW)   MSG="$MSG\n2. MANDATORY: Invoke @pilot:design-reviewer subagent. Do NOT review the design yourself." ;;
  ESCALATED)
    # Determine escalation source: code-review.json exists → code review escalation; otherwise design review
    if [ -f "$PWD/.pilot/code-review.json" ]; then
      MSG="$MSG\n2. Pipeline is WAITING FOR HUMAN. Read .pilot/code-review.json for issues. Ask user how to proceed."
    else
      MSG="$MSG\n2. Pipeline is WAITING FOR HUMAN. Read .pilot/review.json for issues. Ask user how to proceed."
    fi
    ;;
  PLAN)     MSG="$MSG\n2. Read .pilot/tech-design.md (if exists — simple tasks skip design) + requirement.json, generate plan" ;;
  IMPLEMENT)MSG="$MSG\n2. MANDATORY: Read .pilot/plan.json, then invoke @pilot:implementer subagent. Do NOT implement code yourself — you are the orchestrator. The implementer has Recovery logic to pick up from where it left off." ;;
  CODE_REVIEW) MSG="$MSG\n2. MANDATORY: Invoke @pilot:code-reviewer subagent. Do NOT review code yourself." ;;
  VISUAL_CHECK) MSG="$MSG\n2. Run visual check: Figma screenshot vs browser screenshot comparison" ;;
  PR)       MSG="$MSG\n2. Push branch and create draft PR" ;;
  PROJECT_TRANSITION) MSG="$MSG\n2. Archive artifacts, advance to next project in queue" ;;
esac

MSG="$MSG\n3. Read phases.md in the pilot skill references for detailed instructions"

# Output as hook JSON
ESCAPED=$(echo -e "$MSG" | jq -Rs .)
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostCompact\",\"additionalContext\":${ESCAPED}}}"
