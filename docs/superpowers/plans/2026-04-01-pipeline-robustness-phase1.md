# Pipeline Robustness Phase 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the pilot pipeline with fault tolerance, review quality gates, and infrastructure for BDD (Phase 2).

**Architecture:** Phase 1 is purely additive — modifies existing scripts, agent prompts, and phase instructions. No new pipeline phases. Changes fall into 4 layers: (1) validation scripts get stricter checks + AI-friendly errors, (2) agent prompts gain four-status protocol + anti-rationalization + verification iron law, (3) phases.md gets two-stage review + command discovery + compaction recovery, (4) hook scripts get enhanced timeout/recovery. All changes are backward-compatible with existing pipeline runs.

**Tech Stack:** Bash (scripts), Markdown (agent prompts/phases), JSON (artifact schemas), jq (validation)

**Spec:** `docs/superpowers/specs/2026-03-31-pipeline-robustness-design.md`

---

## File Structure

### Scripts (modified)
- `scripts/validate-plan.sh` — add no-placeholders + command validation
- `scripts/validate-code-review.sh` — add planCoverage, verificationSummary, concernsResolution, reviewIteration checks
- `scripts/validate-artifacts.sh` — add status enum routing + concerns.json routing
- `scripts/validate-review.sh` — minor grounding consistency enhancement
- `scripts/post-compact-resume.sh` — phase-specific recovery bundles
- `scripts/health-check.sh` — updatedAt-based staleness + ESCALATED exemption
- `scripts/write-telemetry.sh` — add escalationCount field
- `scripts/agent-dev-gate.sh` — add visual-check pre-gate

### Scripts (new)
- `scripts/validate-visual-review.sh` — validates visual-review.json scoring consistency
- `scripts/lib/error-fmt.sh` — shared AI-friendly error formatting function

### Agent prompts (modified)
- `agents/implementer.md` — four-status protocol, verificationEvidence, NEEDS_CONTEXT payload
- `agents/code-reviewer.md` — two-stage review, anti-rationalization, verificationSummary, planCoverage, concernsResolution, groundingChecks
- `agents/design-reviewer.md` — anti-rationalization table, grounding strictness
- `agents/tech-designer.md` — no-placeholders rule, reference dimensions section

### Phase instructions (modified)
- `skills/pilot/references/phases.md` — two-stage review, command discovery, testInfra generalization, project-capabilities scan, compaction recovery, timeout protection
- `skills/pilot/SKILL.md` — new critical rules, state schema updates

### Plugin metadata
- `CLAUDE.md` — document Phase 1 changes
- `.claude-plugin/plugin.json` — version bump

---

## Task 1: Shared Error Formatting Library

**Files:**
- Create: `scripts/lib/error-fmt.sh`

This is used by all validation scripts. Must come first.

- [ ] **Step 1: Create error formatting helper**

```bash
#!/usr/bin/env bash
# scripts/lib/error-fmt.sh
# Shared AI-friendly error formatting for validation scripts.
# Source this file, then call blocked/warn functions.

pilot_blocked() {
  local reason="$1" why="$2" fix="$3" context="$4"
  echo "[BLOCKED] $reason"
  echo "WHY: $why"
  echo "FIX: $fix"
  [ -n "$context" ] && echo "CONTEXT: $context"
}

pilot_warn() {
  local reason="$1" detail="$2"
  echo "[WARNING] $reason"
  [ -n "$detail" ] && echo "DETAIL: $detail"
}
```

- [ ] **Step 2: Verify it sources cleanly**

Run: `bash -n scripts/lib/error-fmt.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/error-fmt.sh
git commit -m "feat(scripts): add shared AI-friendly error formatting library"
```

---

## Task 2: Enhance validate-plan.sh — No Placeholders + Files Check

**Files:**
- Modify: `scripts/validate-plan.sh`

- [ ] **Step 1: Read current validate-plan.sh**

Read `scripts/validate-plan.sh` to understand the existing jq validation structure.

- [ ] **Step 2: Add no-placeholders validation**

After the existing acRefs check, add:

```bash
# §5.2 No Placeholders Rule
source "$(dirname "$0")/lib/error-fmt.sh"

# Check step descriptions for placeholder patterns
PLACEHOLDER_HITS=$(jq -r '
  .steps | to_entries[] |
  select(.value.scaffolding != true) |
  select(
    (.value.description | test("(?i)(TBD|TODO|待定|后续补充|implement later|add appropriate)"))
  ) |
  "step \(.key): \(.value.description[0:80])"
' "$FILE" 2>/dev/null)

if [ -n "$PLACEHOLDER_HITS" ]; then
  pilot_blocked \
    "plan.json contains placeholder descriptions" \
    "Non-scaffolding steps must have concrete descriptions (§5.2 No Placeholders)" \
    "Replace TBD/TODO/待定/后续补充 with actual implementation details" \
    ".pilot/plan.json → steps[].description"
  echo "$PLACEHOLDER_HITS"
  exit 2
fi

# Check step files arrays are non-empty
EMPTY_FILES=$(jq -r '
  .steps | to_entries[] |
  select(.value.scaffolding != true) |
  select((.value.files | length) == 0) |
  "step \(.key): missing files list"
' "$FILE" 2>/dev/null)

if [ -n "$EMPTY_FILES" ]; then
  pilot_blocked \
    "plan.json steps have empty files arrays" \
    "Every non-scaffolding step must list which files it changes (§5.2)" \
    "Add files array with exact paths, e.g. [\"src/components/Foo.vue\"]" \
    ".pilot/plan.json → steps[].files"
  echo "$EMPTY_FILES"
  exit 2
fi
```

- [ ] **Step 3: Convert existing error messages to AI-friendly format**

Replace existing `echo "ERROR: ..."` lines with `pilot_blocked` calls using the same source import.

- [ ] **Step 4: Test with a valid plan.json**

Run: `echo '{"steps":[{"description":"Add save button","files":["src/Foo.vue"],"acRefs":["AC-1"],"scaffolding":false}]}' | jq '.' > /tmp/test-plan.json && FILE=/tmp/test-plan.json bash scripts/validate-plan.sh; echo "exit: $?"`
Expected: exit 0 (no errors)

- [ ] **Step 5: Test with a plan.json containing placeholder**

Run: `echo '{"steps":[{"description":"TBD implement later","files":[],"acRefs":["AC-1"],"scaffolding":false}]}' | jq '.' > /tmp/test-plan-bad.json && FILE=/tmp/test-plan-bad.json bash scripts/validate-plan.sh 2>&1; echo "exit: $?"`
Expected: `[BLOCKED]` message + exit 2

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-plan.sh
git commit -m "feat(validation): add no-placeholders rule + empty files check to validate-plan.sh"
```

---

## Task 3: Enhance validate-code-review.sh — Two-Stage Review Fields

**Files:**
- Modify: `scripts/validate-code-review.sh`

- [ ] **Step 1: Read current validate-code-review.sh**

Read `scripts/validate-code-review.sh` to understand the existing validation structure.

- [ ] **Step 2: Add planCoverage validation**

After existing checks, add:

```bash
source "$(dirname "$0")/lib/error-fmt.sh"

VERDICT=$(jq -r '.verdict' "$FILE")

# §2.1 PLAN_COVERAGE enforcement
PLAN_COVERAGE=$(jq -r '.planCoverage.total // 0' "$FILE")
PLAN_COMPLETED=$(jq -r '.planCoverage.completed // 0' "$FILE")
PLAN_REMOVED=$(jq -r '.planCoverage.removed // 0' "$FILE")

if [ "$VERDICT" = "APPROVE" ] && [ "$PLAN_COVERAGE" -gt 0 ]; then
  EFFECTIVE=$((PLAN_COMPLETED + PLAN_REMOVED))
  if [ "$EFFECTIVE" -lt "$PLAN_COVERAGE" ]; then
    pilot_blocked \
      "APPROVE with incomplete plan coverage ($EFFECTIVE/$PLAN_COVERAGE)" \
      "All plan steps must be completed or explicitly removed with reason (§2.1)" \
      "Complete remaining steps or add removedReason for skipped steps" \
      ".pilot/code-review.json → planCoverage"
    exit 2
  fi
  # Check removed steps have reasons
  MISSING_REASON=$(jq -r '
    .planCoverage.steps[]? |
    select(.status == "removed" and (.removedReason == null or .removedReason == "")) |
    "step \(.stepIndex)"
  ' "$FILE")
  if [ -n "$MISSING_REASON" ]; then
    pilot_blocked \
      "Removed plan steps missing removedReason" \
      "Steps removed during implementation must explain why (§2.1)" \
      "Add removedReason field to each removed step" \
      ".pilot/code-review.json → planCoverage.steps[]"
    echo "$MISSING_REASON"
    exit 2
  fi
fi
```

- [ ] **Step 3: Add verificationSummary validation**

```bash
# §2.3 Verification Iron Law
if [ "$VERDICT" = "APPROVE" ]; then
  VS_TYPE=$(jq -r '.verificationSummary.type // empty' "$FILE")
  if [ -z "$VS_TYPE" ]; then
    pilot_blocked \
      "APPROVE without verificationSummary" \
      "Any completion claim must have verification evidence (§2.3 Verification Iron Law)" \
      "Add verificationSummary with type (test|build|fileCheck), command, output, exitCode" \
      ".pilot/code-review.json → verificationSummary"
    exit 2
  fi
  # If plan has test-first steps, verification must be type=test
  if [ -f ".pilot/plan.json" ]; then
    HAS_TEST_FIRST=$(jq '[.steps[]? | select(.posture == "test-first")] | length' .pilot/plan.json 2>/dev/null)
    if [ "${HAS_TEST_FIRST:-0}" -gt 0 ] && [ "$VS_TYPE" != "test" ]; then
      pilot_blocked \
        "APPROVE with non-test verification but plan has test-first steps" \
        "Plan has test-first steps — verificationSummary.type must be 'test' (§2.3)" \
        "Run the test suite and include results in verificationSummary" \
        ".pilot/code-review.json → verificationSummary.type"
      exit 2
    fi
  fi
fi
```

- [ ] **Step 4: Add concernsResolution validation**

```bash
# §1.1 Concerns Resolution
if [ -f ".pilot/concerns.json" ] && [ "$VERDICT" = "APPROVE" ]; then
  CONCERN_COUNT=$(jq '.concerns | length' .pilot/concerns.json 2>/dev/null || echo 0)
  RESOLUTION_COUNT=$(jq '.concernsResolution | length // 0' "$FILE" 2>/dev/null || echo 0)
  if [ "$RESOLUTION_COUNT" -lt "$CONCERN_COUNT" ]; then
    pilot_blocked \
      "APPROVE with unresolved concerns ($RESOLUTION_COUNT/$CONCERN_COUNT)" \
      "Every concern in concerns.json must be resolved in code-review.json (§1.1)" \
      "Add concernsResolution[] entry for each concern (addressed/acknowledged/confirmed)" \
      ".pilot/code-review.json → concernsResolution"
    exit 2
  fi
  # Check for confirmed concerns blocking APPROVE
  CONFIRMED=$(jq '[.concernsResolution[]? | select(.resolution == "confirmed")] | length' "$FILE" 2>/dev/null || echo 0)
  if [ "$CONFIRMED" -gt 0 ]; then
    pilot_blocked \
      "APPROVE with $CONFIRMED confirmed (unresolved) concerns" \
      "Confirmed concerns indicate real issues — cannot APPROVE (§1.1)" \
      "Change verdict to FIX_REQUIRED or resolve the confirmed concerns" \
      ".pilot/code-review.json → concernsResolution[].resolution"
    exit 2
  fi
fi
```

- [ ] **Step 5: Convert existing error messages to AI-friendly format**

Replace all existing `echo "..."` error lines with `pilot_blocked` calls.

- [ ] **Step 6: Test with a minimal valid code-review.json**

Create a test fixture and verify the script passes for a valid APPROVE verdict with all required fields.

- [ ] **Step 7: Test that APPROVE without verificationSummary is blocked**

Create a fixture missing verificationSummary, verify exit 2 + `[BLOCKED]` output.

- [ ] **Step 8: Commit**

```bash
git add scripts/validate-code-review.sh
git commit -m "feat(validation): add planCoverage, verificationSummary, concernsResolution checks"
```

---

## Task 4: Enhance validate-artifacts.sh — Status Enum + New Artifact Routing

**Files:**
- Modify: `scripts/validate-artifacts.sh`

- [ ] **Step 1: Read current validate-artifacts.sh**

Read `scripts/validate-artifacts.sh` to understand the dispatcher routing structure.

- [ ] **Step 2: Add concerns.json routing**

After existing routes, add a route for concerns.json validation (existence check only — schema is lightweight):

```bash
*concerns.json)
  # Validate concerns.json schema: must have "concerns" array
  source "$(dirname "$0")/lib/error-fmt.sh"
  if ! jq -e '.concerns | type == "array"' "$FILE" >/dev/null 2>&1; then
    pilot_blocked \
      "concerns.json missing concerns array" \
      "concerns.json must contain a 'concerns' array (§1.1)" \
      "Ensure the file has format: {\"phase\":\"...\",\"concerns\":[...]}" \
      "$FILE"
    exit 2
  fi
  ;;
```

- [ ] **Step 3: Add visual-review.json routing**

```bash
*visual-review.json)
  exec "$(dirname "$0")/validate-visual-review.sh" "$FILE"
  ;;
```

- [ ] **Step 4: Add state.json updatedAt injection**

In the existing state.json handler, add updatedAt timestamp:

```bash
*state.json)
  # Existing sessionId patch ...
  # Add updatedAt timestamp for §1.4 timeout detection
  UPDATED=$(jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.updatedAt = $ts' "$FILE")
  echo "$UPDATED" > "$FILE"
  ;;
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n scripts/validate-artifacts.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-artifacts.sh
git commit -m "feat(validation): add concerns.json + visual-review.json routing + state.json updatedAt"
```

---

## Task 5: Create validate-visual-review.sh

**Files:**
- Create: `scripts/validate-visual-review.sh`

- [ ] **Step 1: Write the validator**

```bash
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
      "Verdict MATCH requires all dimensions ≥ 5 (§3.1 scoring consistency)" \
      "Either lower the verdict to MINOR_DEVIATION or re-evaluate dimension scores" \
      ".pilot/visual-review.json → staticComparison.dimensions"
    echo "$LOW_DIMS"
    exit 2
  fi
fi
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/validate-visual-review.sh && bash -n scripts/validate-visual-review.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Test with MATCH + all dimensions ≥ 5**

Run: `echo '{"staticComparison":{"verdict":"MATCH","dimensions":{"layout":{"score":8},"spacing":{"score":7},"color":{"score":6},"typography":{"score":5},"components":{"score":9}}}}' > /tmp/test-vr.json && FILE=/tmp/test-vr.json bash scripts/validate-visual-review.sh; echo "exit: $?"`
Expected: exit 0

- [ ] **Step 4: Test with MATCH + a dimension < 5**

Run: `echo '{"staticComparison":{"verdict":"MATCH","dimensions":{"layout":{"score":8},"spacing":{"score":3},"color":{"score":6},"typography":{"score":5},"components":{"score":9}}}}' > /tmp/test-vr-bad.json && FILE=/tmp/test-vr-bad.json bash scripts/validate-visual-review.sh 2>&1; echo "exit: $?"`
Expected: `[BLOCKED]` + exit 2

- [ ] **Step 5: Commit**

```bash
git add scripts/validate-visual-review.sh
git commit -m "feat(validation): add validate-visual-review.sh for static comparison scoring consistency"
```

---

## Task 6: Enhance post-compact-resume.sh — Phase-Specific Recovery

**Files:**
- Modify: `scripts/post-compact-resume.sh`

- [ ] **Step 1: Read current post-compact-resume.sh**

Read `scripts/post-compact-resume.sh` to understand the current resume context generation.

- [ ] **Step 2: Add phase-specific artifact injection**

After the existing state.json reading logic, add a case statement that selects the appropriate artifact bundle based on current phase:

```bash
# §1.3 Phase-specific recovery context
PHASE=$(jq -r '.currentPhase // "UNKNOWN"' "$STATE_FILE")
RECOVERY_CONTEXT=""

case "$PHASE" in
  DESIGN)
    [ -f "$PILOT_DIR/design.md" ] && \
      RECOVERY_CONTEXT="Design artifact (first 200 lines):\n$(head -200 "$PILOT_DIR/design.md")"
    ;;
  REVIEW)
    [ -f "$PILOT_DIR/review.json" ] && \
      RECOVERY_CONTEXT="Review verdict: $(jq -r '.verdict // "unknown"' "$PILOT_DIR/review.json")\nKey findings: $(jq -r '.issues[:3] | .[].description // empty' "$PILOT_DIR/review.json" 2>/dev/null)"
    ;;
  IMPLEMENT)
    if [ -f "$PILOT_DIR/plan.json" ]; then
      CURRENT_STEP=$(jq -r '.currentStepIndex // 0' "$STATE_FILE")
      TOTAL_STEPS=$(jq '.steps | length' "$PILOT_DIR/plan.json")
      LAST_COMMIT=$(git log -1 --format="%h %s" 2>/dev/null || echo "unknown")
      RECOVERY_CONTEXT="Plan: step $CURRENT_STEP/$TOTAL_STEPS\nLast commit: $LAST_COMMIT"
    fi
    ;;
  CODE_REVIEW)
    [ -f "$PILOT_DIR/code-review.json" ] && \
      RECOVERY_CONTEXT="Code review verdict: $(jq -r '.verdict // "unknown"' "$PILOT_DIR/code-review.json")\nReview iteration: $(jq -r '.reviewIteration // 1' "$PILOT_DIR/code-review.json")"
    ;;
esac
```

- [ ] **Step 3: Add staleness warning**

```bash
# §1.4 Staleness detection
UPDATED_AT=$(jq -r '.updatedAt // empty' "$STATE_FILE")
if [ -n "$UPDATED_AT" ]; then
  UPDATED_EPOCH=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  STALE_SECONDS=$(( NOW_EPOCH - UPDATED_EPOCH ))
  if [ "$STALE_SECONDS" -gt 900 ] && [ "$PHASE" != "COMPLETED" ] && [ "$PHASE" != "FAILED" ]; then
    RECOVERY_CONTEXT="$RECOVERY_CONTEXT\n\n⚠ WARNING: Pipeline may have stalled ($((STALE_SECONDS / 60)) min since last update in phase $PHASE)"
  fi
fi
```

- [ ] **Step 4: Inject recovery context into hook output**

Add `$RECOVERY_CONTEXT` to the existing JSON output that the hook returns.

- [ ] **Step 5: Verify syntax**

Run: `bash -n scripts/post-compact-resume.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/post-compact-resume.sh
git commit -m "feat(recovery): add phase-specific context bundles + staleness warning to post-compact-resume"
```

---

## Task 7: Enhance health-check.sh — updatedAt + ESCALATED Exemption

**Files:**
- Modify: `scripts/health-check.sh`

- [ ] **Step 1: Read current health-check.sh**

Read `scripts/health-check.sh` to understand the current staleness detection.

- [ ] **Step 2: Switch staleness detection from mtime to updatedAt**

Replace file mtime check with state.json `updatedAt` field check:

```bash
source "$(dirname "$0")/lib/error-fmt.sh"

# §1.4 Use semantic updatedAt instead of file mtime
UPDATED_AT=$(jq -r '.updatedAt // empty' "$STATE_FILE")
if [ -z "$UPDATED_AT" ]; then
  # Fallback to file mtime if updatedAt not set (backward compat)
  LAST_UPDATE=$(stat -f %m "$STATE_FILE" 2>/dev/null || stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)
else
  LAST_UPDATE=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || date -d "$UPDATED_AT" +%s 2>/dev/null || echo 0)
fi
```

- [ ] **Step 3: Add ESCALATED + terminal phase exemption**

```bash
PHASE=$(jq -r '.currentPhase // "UNKNOWN"' "$STATE_FILE")
# Don't flag ESCALATED (waiting for human) or terminal phases
case "$PHASE" in
  COMPLETED|FAILED|ESCALATED)
    exit 0
    ;;
esac
```

- [ ] **Step 4: Improve notification message**

```bash
if [ "$STALE_SECONDS" -gt "$THRESHOLD" ]; then
  MSG="Pipeline stalled in phase $PHASE (${STALE_MIN}min). Run 'claude /pilot resume' or check for stuck subagent."
  # macOS notification
  osascript -e "display notification \"$MSG\" with title \"Pilot Pipeline\"" 2>/dev/null || true
fi
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n scripts/health-check.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add scripts/health-check.sh
git commit -m "feat(health): use updatedAt for staleness, exempt ESCALATED/terminal phases"
```

---

## Task 8: Enhance Agent Prompts — Four-Status Protocol

**Files:**
- Modify: `agents/implementer.md`
- Modify: `agents/code-reviewer.md`
- Modify: `agents/design-reviewer.md`
- Modify: `agents/tech-designer.md`

- [ ] **Step 1: Read all four agent files**

Read `agents/implementer.md`, `agents/code-reviewer.md`, `agents/design-reviewer.md`, `agents/tech-designer.md`.

- [ ] **Step 2: Add four-status protocol to implementer.md**

At the end of the output format section, add:

```markdown
## Completion Status (MANDATORY)

Your final output MUST include a `status` field with one of these values:

| Status | When to use |
|--------|------------|
| `DONE` | All steps completed successfully |
| `DONE_WITH_CONCERNS` | Completed but you have doubts. Include `concerns[]` array with `{step, description, severity, suggestedCheck}` for each concern. |
| `NEEDS_CONTEXT` | Cannot proceed without more information. Include `requestedContext[]` array with `{type: "file"|"grep", path/pattern, scope}` entries. Max 2 retry attempts before auto-escalation. |
| `BLOCKED` | Unrecoverable issue. Include `blockReason` string explaining what went wrong. |

### NEEDS_CONTEXT payload example
```json
{
  "status": "NEEDS_CONTEXT",
  "reason": "Cannot find the API endpoint for saving favorites",
  "requestedContext": [
    { "type": "file", "path": "src/api/favorites.ts" },
    { "type": "grep", "pattern": "saveFavorite", "scope": "src/" }
  ],
  "retryHint": "Provide the favorites API module path"
}
```

### verificationEvidence (per step, MANDATORY)
Each step in STEP_STATUSES must include `verificationEvidence`:
- `test-first` steps: `{ "type": "test", "command": "...", "output": "Tests: N passed", "exitCode": 0 }`
- `build-verify` steps: `{ "type": "build", "command": "...", "output": "Build succeeded", "exitCode": 0 }`
- `scaffold` steps: `{ "type": "fileCheck", "files": ["path/created.ts"], "allExist": true }`
```

- [ ] **Step 3: Add four-status protocol to code-reviewer.md**

Add the same status table to the code-reviewer output format section. Additionally, add the `verificationSummary`, `planCoverage`, `concernsResolution`, and `groundingChecks` fields to the JSON output block.

- [ ] **Step 4: Add four-status protocol to design-reviewer.md and tech-designer.md**

Add the status table to both. For design-reviewer, the typical statuses are `DONE` (review complete) or `BLOCKED` (cannot assess). For tech-designer, add `DONE_WITH_CONCERNS` for cases where the design is complete but references uncertain APIs.

- [ ] **Step 5: Commit**

```bash
git add agents/implementer.md agents/code-reviewer.md agents/design-reviewer.md agents/tech-designer.md
git commit -m "feat(agents): add four-status reporting protocol to all subagents"
```

---

## Task 9: Enhance Agent Prompts — Anti-Rationalization + Verification Iron Law

**Files:**
- Modify: `agents/code-reviewer.md`
- Modify: `agents/design-reviewer.md`

- [ ] **Step 1: Add anti-rationalization table to code-reviewer.md**

After the rubric scoring section, add:

```markdown
## Anti-Rationalization Calibration

Do NOT accept these rationalizations:

| If you think... | Stop. Instead... |
|----------------|-----------------|
| "This difference is minor" | Document it. Minor diffs accumulate. |
| "Should be fine" / "Looks correct" | No test run = no evidence = cannot pass. |
| "Tests are too hard to write" | If worth implementing, worth verifying. |
| "This is a framework limitation" | Verify it IS a limitation, not an unfound correct usage. |
| "The original code did it this way" | Original code ≠ acceptance standard. The spec is. |
| "It works in my testing" | Ad-hoc ≠ structured verification. Run the full suite. |
| "This edge case won't happen" | If it can't, the test is free. If it can, you need it. |
```

- [ ] **Step 2: Add anti-rationalization table to design-reviewer.md**

Add the same table plus a design-specific entry:

```markdown
| "The designer probably intended X" | You don't know intent — only what the spec says. Flag ambiguity. |
```

- [ ] **Step 3: Add two-stage review structure to code-reviewer.md**

Restructure the review flow section to enforce Stage 1 → Stage 2 ordering:

```markdown
## Review Structure (Two-Stage, Fixed Order)

### Stage 1: SPEC_COMPLIANCE (must pass before Stage 2)
1. REQUIREMENTS_COVERAGE: verify every AC is implemented
2. PLAN_COVERAGE: verify every plan step is completed (output `planCoverage` object)
3. CONCERNS_RESOLUTION: if `.pilot/concerns.json` exists, verify each concern (output `concernsResolution[]`)
4. GROUNDING_CHECKS: for each `apiRefs` in plan.json, verify API exists (output `groundingChecks[]`)

If ANY Stage 1 check fails → verdict MUST be FIX_REQUIRED. Do NOT proceed to Stage 2 scoring.

### Stage 2: CODE_QUALITY (only if Stage 1 passes)
Score each dimension 1-10:
- Correctness, Convention, Regression, Performance
```

- [ ] **Step 4: Commit**

```bash
git add agents/code-reviewer.md agents/design-reviewer.md
git commit -m "feat(agents): add anti-rationalization tables + two-stage review to reviewers"
```

---

## Task 10: Enhance phases.md — Command Discovery + testInfra + Project Capabilities

**Files:**
- Modify: `skills/pilot/references/phases.md`

This is the largest single change — phases.md is 682 lines. Changes touch RESOLVE, PLAN, IMPLEMENT, and CODE_REVIEW phases.

- [ ] **Step 1: Read PLAN phase section of phases.md**

Read the PLAN phase (approximately lines 200-350) to find the health check and testInfra detection logic.

- [ ] **Step 2: Add project-capabilities scan to RESOLVE phase**

After the existing RESOLVE complexity classification, add:

```markdown
#### Project Capability Scan

After determining projectDir, scan the project and write `.pilot/project-capabilities.json`:

```json
{
  "stack": "<detected from package.json/Podfile/build.gradle>",
  "buildSystem": "<vite|webpack|xcodebuild|gradle|make>",
  "testInfra": {
    "framework": "<vitest|jest|xctest|junit|phpunit>",
    "runCommand": "<full CLI command>",
    "configFile": "<path or null>",
    "testPattern": "<glob>",
    "detected": true
  },
  "hasDevServer": <bool>,
  "devServerCommand": "<command or null>",
  "hasFigmaDesigns": <bool from requirement>,
  "hasExistingTests": <bool>,
  "conventionFiles": ["<paths to .claude/rules/*.md etc>"],
  "qaCapabilities": {
    "web": { "chromeDevTools": <bool>, "devServer": <bool> },
    "ios": { "xcodeMcp": <bool>, "simulator": <bool> }
  }
}
```

**Discovery protocol** (§6.1):
1. **Level 1**: Read CLAUDE.md for explicit `buildCommand`, `testCommand`, `lintCommand`, `devServerCommand`. If found, use directly.
2. **Level 2**: Probe config files — `package.json` scripts, `Makefile`, `build.gradle`, `.xcodeproj`, `composer.json`. Extract commands.
3. **Level 3**: Mark as `UNKNOWN`. Implementer discovers in first step.
```

- [ ] **Step 3: Enhance PLAN phase health check with generalized testInfra**

Update the PLAN health check section to use `project-capabilities.json` instead of hardcoded framework detection:

```markdown
#### Health Check (enhanced)

1. Read `.pilot/project-capabilities.json` (created in RESOLVE)
2. Validate `testInfra.runCommand` by dry-run: `bash -c "<command> --help" 2>/dev/null`
3. Validate `buildCommand` similarly
4. Record results in `plan.json`:
   - `verificationCommand`: from capabilities or CLAUDE.md
   - `lintCommand`: from capabilities or CLAUDE.md
   - `testInfra`: structured object from capabilities
```

- [ ] **Step 4: Add compaction recovery instructions per phase**

Add a new section after the state schema:

```markdown
### Compaction Recovery Instructions

Each phase has specific resume instructions (used by post-compact-resume.sh):

| Phase | Key Artifact | Resume Instruction |
|-------|-------------|-------------------|
| DESIGN | design.md | Re-read design.md, continue from where design left off. Do NOT restart. |
| REVIEW | review.json | Read review verdict. If REVISE, prepare next design iteration. |
| IMPLEMENT | plan.json + step index | Read plan.json, check STEP_STATUSES, resume from first incomplete step. Reconstruct anchor set via `git diff`. |
| CODE_REVIEW | code-review.json | Read verdict + reviewIteration. If FIX_REQUIRED, invoke implementer fix mode. |
| VISUAL_CHECK | visual-review.json | Read verdict. If MAJOR_DEVIATION, invoke implementer UI fix mode. |
```

- [ ] **Step 5: Add three-fix escape hatch to CODE_REVIEW phase**

In the CODE_REVIEW fix loop section, add:

```markdown
#### Three-Fix Architectural Escape Hatch (§1.2)

If fix round 3 verdict is still FIX_REQUIRED:
1. Collect diffs from all 3 fix rounds + reviewer comments
2. Write `.pilot/architectural-concern.md` analyzing patterns
3. Set phase → ESCALATED
4. DO NOT retry — escalate to user with the analysis
```

- [ ] **Step 6: Commit**

```bash
git add skills/pilot/references/phases.md
git commit -m "feat(phases): add command discovery, testInfra generalization, compaction recovery, 3-fix escape hatch"
```

---

## Task 11: Update SKILL.md — New Rules + State Schema

**Files:**
- Modify: `skills/pilot/SKILL.md`

- [ ] **Step 1: Read current SKILL.md**

Read `skills/pilot/SKILL.md`.

- [ ] **Step 2: Add new critical rules**

In the Critical Rules section, add:

```markdown
8. **Four-Status Protocol**: Every subagent output MUST include `status` field: DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED. Parent validates enum. NEEDS_CONTEXT max 2 retries, then auto-BLOCKED.
9. **Three-Fix Limit**: After 3 FIX_REQUIRED rounds in CODE_REVIEW (or 3 REVISE in DESIGN/REVIEW), auto-escalate with `.pilot/architectural-concern.md`. DO NOT retry.
10. **Verification Iron Law**: No "completion" claim without verification evidence. Implementer: verificationEvidence per step. Code-reviewer: verificationSummary in output. Design-reviewer: AC coverage points.
11. **No Placeholders**: plan.json steps must not contain TBD/TODO/待定. Script-enforced via validate-plan.sh.
```

- [ ] **Step 3: Update state schema with updatedAt**

Add `updatedAt` field to the state.json schema:

```markdown
### State Schema (updated)
- `updatedAt`: ISO 8601 timestamp, auto-set by validate-artifacts.sh on every state.json write
- `anchorSet`: array of test file paths from last implementer run (used for compaction recovery)
```

- [ ] **Step 4: Commit**

```bash
git add skills/pilot/SKILL.md
git commit -m "feat(skill): add four-status, three-fix, verification iron law, no-placeholders rules"
```

---

## Task 12: Update CLAUDE.md + Version Bump

**Files:**
- Modify: `CLAUDE.md`
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Read current CLAUDE.md Quality Gates section**

Read `CLAUDE.md` around the Quality Gates section.

- [ ] **Step 2: Update Quality Gates documentation**

Add Phase 1 enhancements to the Quality Gates section:

```markdown
### Quality Gates (Phase 1 Enhanced)

- **PLAN**: no-placeholders rule (script-enforced: TBD/TODO/待定 → blocked), empty files check, project-capabilities scan, framework-agnostic command discovery (3-level protocol)
- **Implementer**: four-status protocol (DONE/DONE_WITH_CONCERNS/NEEDS_CONTEXT/BLOCKED), verificationEvidence per step, NEEDS_CONTEXT auto-escalation after 2 retries
- **Code-reviewer**: Two-stage review (Stage 1: SPEC_COMPLIANCE → Stage 2: CODE_QUALITY), anti-rationalization tables, Verification Iron Law (verificationSummary required for APPROVE), planCoverage validation, concernsResolution, groundingChecks
- **Design-reviewer**: Anti-rationalization tables, AC grounding enforcement
- **Recovery**: Phase-specific compaction recovery bundles, updatedAt-based staleness detection (15min threshold), ESCALATED phase exemption
- **Three-Fix Limit**: 3 FIX_REQUIRED rounds → architectural-concern.md → ESCALATE
```

- [ ] **Step 3: Bump version in plugin.json**

Read `.claude-plugin/plugin.json`, bump version to 2.0.0 (major version — Phase 1 is a breaking enhancement to pipeline protocol).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md .claude-plugin/plugin.json
git commit -m "docs: update CLAUDE.md quality gates for Phase 1, bump version to v2.0.0"
```

---

## Task 13: Enhance write-telemetry.sh — Add escalationCount

**Files:**
- Modify: `scripts/write-telemetry.sh`

- [ ] **Step 1: Read current write-telemetry.sh**

Read `scripts/write-telemetry.sh` to understand the TSV format.

- [ ] **Step 2: Add escalationCount field**

After existing metric fields, add:

```bash
# §1.2 Track escalation events
ESCALATION_COUNT=$(jq -r '.metrics.escalationCount // 0' "$STATE_FILE")
```

Add `$ESCALATION_COUNT` to the TSV row output.

- [ ] **Step 3: Verify syntax**

Run: `bash -n scripts/write-telemetry.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/write-telemetry.sh
git commit -m "feat(telemetry): add escalationCount field for three-fix escape hatch tracking"
```

---

## Verification Plan

After all tasks are complete:

1. **Syntax check all scripts**: `for f in scripts/*.sh scripts/lib/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done`
2. **Validate plan.sh with good/bad fixtures**: create test JSON files, verify correct exit codes
3. **Validate code-review.sh with good/bad fixtures**: same approach
4. **Validate visual-review.sh with good/bad fixtures**: same approach
5. **Read all agent .md files**: verify four-status protocol, anti-rationalization tables, verification iron law are present and consistent across all 4 agents
6. **Read phases.md**: verify command discovery, compaction recovery, three-fix escape hatch sections exist
7. **Read SKILL.md**: verify rules 8-11 added
8. **Read CLAUDE.md**: verify Quality Gates section updated
