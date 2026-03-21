#!/bin/bash
# Write pipeline telemetry to global TSV after pipeline completion
# Usage: write-telemetry.sh <state.json-path> [plugin-version]
# Appends one row per pipeline run to ~/.agent-dev-telemetry.tsv

set -euo pipefail

STATE="${1:?Usage: write-telemetry.sh <state.json-path> [version]}"
VERSION="${2:-unknown}"
TSV="$HOME/.agent-dev-telemetry.tsv"

command -v jq &>/dev/null || { echo "jq required" >&2; exit 1; }
[ -f "$STATE" ] || { echo "state.json not found: $STATE" >&2; exit 1; }

# Create TSV with header if it doesn't exist
if [ ! -f "$TSV" ]; then
  printf 'timestamp\tpipeline_id\tversion\tproject\tnotion_url\tdesign_rounds\tcode_review_rounds\tinterventions\treview_confidence\tcode_review_confidence\ttotal_minutes\tscore\tstatus\n' > "$TSV"
fi

# Extract fields from state.json
PIPELINE_ID=$(jq -r '.pipelineId // "unknown"' "$STATE")
PROJECT=$(jq -r '.targetProject // "unknown"' "$STATE")
NOTION_URL=$(jq -r '.notionUrl // ""' "$STATE")
PHASE=$(jq -r '.phase // "UNKNOWN"' "$STATE")
REVIEW_REVISION_COUNT=$(jq -r '.reviewRevisionCount // 0' "$STATE")
CODE_REVIEW_COUNT=$(jq -r '.codeReviewCount // 0' "$STATE")
INTERVENTIONS=$(jq -r '.metrics.interventions // 0' "$STATE")
REVIEW_CONFIDENCE=$(jq -r '.reviewConfidence // 0' "$STATE")
CODE_REVIEW_CONFIDENCE=$(jq -r '.codeReviewConfidence // 0' "$STATE")
CREATED_AT=$(jq -r '.createdAt // ""' "$STATE")
COMPLETED_AT=$(jq -r '.metrics.completedAt // ""' "$STATE")

# Compute derived metrics
DESIGN_ROUNDS=$((REVIEW_REVISION_COUNT + 1))
CODE_REVIEW_ROUNDS=$((CODE_REVIEW_COUNT + 1))

# Compute total minutes
TOTAL_MINUTES=0
if [ -n "$CREATED_AT" ] && [ -n "$COMPLETED_AT" ]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    START_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${CREATED_AT%%.*}" "+%s" 2>/dev/null || echo 0)
    END_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${COMPLETED_AT%%.*}" "+%s" 2>/dev/null || echo 0)
  else
    START_EPOCH=$(date -d "$CREATED_AT" "+%s" 2>/dev/null || echo 0)
    END_EPOCH=$(date -d "$COMPLETED_AT" "+%s" 2>/dev/null || echo 0)
  fi
  if [ "$START_EPOCH" -gt 0 ] && [ "$END_EPOCH" -gt 0 ]; then
    TOTAL_MINUTES=$(( (END_EPOCH - START_EPOCH) / 60 ))
  fi
fi

# Compute pipeline score (0-100)
# completion: 40pts (COMPLETED=40, FAILED=0)
# interventions: 30pts (0=30, 1=20, 2=10, 3+=0)
# design first-pass: 15pts (1 round=15, 2=10, 3=5, 4+=0)
# code review first-pass: 15pts (1 round=15, 2=10, 3+=0)
COMPLETION_PTS=0
STATUS="failed"
if [ "$PHASE" = "COMPLETED" ] || [ "$PHASE" = "PROJECT_TRANSITION" ]; then
  COMPLETION_PTS=40
  STATUS="completed"
elif [ "$PHASE" = "ESCALATED" ]; then
  STATUS="escalated"
fi

INTERVENTION_PTS=$(( 30 - INTERVENTIONS * 10 ))
[ "$INTERVENTION_PTS" -lt 0 ] && INTERVENTION_PTS=0

DESIGN_PTS=$(( 15 - (DESIGN_ROUNDS - 1) * 5 ))
[ "$DESIGN_PTS" -lt 0 ] && DESIGN_PTS=0

CODE_REVIEW_PTS=$(( 15 - (CODE_REVIEW_ROUNDS - 1) * 5 ))
[ "$CODE_REVIEW_PTS" -lt 0 ] && CODE_REVIEW_PTS=0

SCORE=$(( COMPLETION_PTS + INTERVENTION_PTS + DESIGN_PTS + CODE_REVIEW_PTS ))

# Write row
TIMESTAMP=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
printf '%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n' \
  "$TIMESTAMP" "$PIPELINE_ID" "$VERSION" "$PROJECT" "$NOTION_URL" \
  "$DESIGN_ROUNDS" "$CODE_REVIEW_ROUNDS" "$INTERVENTIONS" \
  "$REVIEW_CONFIDENCE" "$CODE_REVIEW_CONFIDENCE" \
  "$TOTAL_MINUTES" "$SCORE" "$STATUS" >> "$TSV"

echo "Telemetry written: score=$SCORE (completion=$COMPLETION_PTS intervention=$INTERVENTION_PTS design=$DESIGN_PTS code_review=$CODE_REVIEW_PTS)"
