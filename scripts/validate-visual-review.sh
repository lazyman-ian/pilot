#!/usr/bin/env bash
# scripts/validate-visual-review.sh
# Validates visual-review.json — scoring consistency for static comparison.
# §3.1: staticComparison.verdict MATCH but any dimension < 5 → exit 2

set -euo pipefail
FILE="${1:?Usage: validate-visual-review.sh <file>}"
source "$(dirname "$0")/lib/error-fmt.sh"

VERDICT=$(jq -r '.staticComparison.verdict // empty' "$FILE")
[ -z "$VERDICT" ] && exit 0  # No static comparison — skip (SKIPPED_NO_FIGMA etc.)

if [ "$VERDICT" = "MATCH" ]; then
  LOW_DIMS=$(jq -r '
    .staticComparison.dimensions | to_entries[] |
    select(.value.score < 5) |
    "\(.key): \(.value.score)/10"
  ' "$FILE" 2>/dev/null)

  if [ -n "$LOW_DIMS" ]; then
    pilot_blocked \
      "visual-review.json: MATCH verdict with low dimension scores" \
      "Verdict MATCH requires all dimensions >= 5 (§3.1 scoring consistency)" \
      "Either lower the verdict to MINOR_DEVIATION or re-evaluate dimension scores" \
      ".pilot/visual-review.json -> staticComparison.dimensions"
    echo "$LOW_DIMS"
    exit 2
  fi
fi
