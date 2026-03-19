#!/bin/bash
# Post-compaction context restoration for agent-dev pipeline
# Reads state.json and produces a resume context for the parent agent

# .agent-dev/ always lives in CWD (monorepo root)
STATE="$PWD/.agent-dev/state.json"
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

# Don't inject for completed/failed pipelines
case "$PHASE" in
  COMPLETED|FAILED|"") exit 0 ;;
esac

# Build resume message
MSG="agent-dev pipeline is ACTIVE. DO NOT ask the user what to do — resume automatically."
MSG="$MSG\n\nCurrent state:"
MSG="$MSG\n- Phase: $PHASE"
[ -n "$TARGET" ] && MSG="$MSG\n- Project: $TARGET ($PROJECT_DIR)"
[ -n "$BRANCH" ] && MSG="$MSG\n- Branch: $BRANCH"
[ -n "$STEP" ] && MSG="$MSG\n- Current step: $STEP (completed: $TOTAL)"

MSG="$MSG\n\nTo resume:"
MSG="$MSG\n1. Read $STATE for full pipeline state"
case "$PHASE" in
  FETCH)    MSG="$MSG\n2. Check if .agent-dev/requirement.json exists, continue FETCH" ;;
  RESOLVE)  MSG="$MSG\n2. Continue project resolution" ;;
  DESIGN)   MSG="$MSG\n2. Read .agent-dev/requirement.json, invoke @agent-dev:tech-designer" ;;
  REVIEW)   MSG="$MSG\n2. Read .agent-dev/tech-design.md, invoke @agent-dev:design-reviewer" ;;
  ESCALATED)MSG="$MSG\n2. Pipeline is WAITING FOR HUMAN. Read .agent-dev/review.json for issues. Ask user how to proceed." ;;
  PLAN)     MSG="$MSG\n2. Read .agent-dev/tech-design.md + review.json, generate plan" ;;
  IMPLEMENT)MSG="$MSG\n2. Read .agent-dev/plan.json for step $STEP details, continue implementing" ;;
  CODE_REVIEW) MSG="$MSG\n2. Invoke @agent-dev:code-reviewer" ;;
  VISUAL_CHECK) MSG="$MSG\n2. Run visual check: Figma screenshot vs browser screenshot comparison" ;;
  PR)       MSG="$MSG\n2. Push branch and create draft PR" ;;
esac

MSG="$MSG\n3. Read phases.md in the agent-dev skill references for detailed instructions"

# Output as hook JSON
ESCAPED=$(echo -e "$MSG" | jq -Rs .)
echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostCompact\",\"additionalContext\":${ESCAPED}}}"
