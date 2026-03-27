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

# Don't inject for completed/failed pipelines
case "$PHASE" in
  COMPLETED|FAILED|"") exit 0 ;;
esac

# Build resume message
MSG="pilot pipeline is ACTIVE. DO NOT ask the user what to do — resume automatically."
MSG="$MSG\n\nCurrent state:"
MSG="$MSG\n- Phase: $PHASE"
[ -n "$TARGET" ] && MSG="$MSG\n- Project: $TARGET ($PROJECT_DIR)"
[ -n "$BRANCH" ] && MSG="$MSG\n- Branch: $BRANCH"
[ -n "$STEP" ] && MSG="$MSG\n- Current step: $STEP (completed: $TOTAL)"

[ "$QUEUE_LEN" -gt 1 ] 2>/dev/null && MSG="$MSG\n- Project queue: $((QUEUE_IDX + 1))/$QUEUE_LEN (completed: $COMPLETED_PROJECTS)"

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
