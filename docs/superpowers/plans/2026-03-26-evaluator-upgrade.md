# Evaluator Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade pipeline evaluators with script-enforced scoring constraints, interactive QA via Chrome DevTools, iteration loop enhancements, and a structured architecture stress-test protocol.

**Architecture:** Four validation scripts (dispatched from a single PostToolUse Write hook) enforce scoring consistency, requirement traceability, and grounding checks via `exit 2` blocks. Code-reviewer gains Chrome DevTools MCP tools for interactive QA. Prompt-level few-shot calibration supplements the script gates.

**Tech Stack:** Bash/jq (validation scripts), Markdown (agent prompts), JSON (hooks config)

---

### Task 1: Create `validate-artifacts.sh` dispatcher

**Files:**
- Create: `scripts/validate-artifacts.sh`
- Modify: `scripts/patch-state-session.sh` (absorb into dispatcher)

This is the single PostToolUse(Write) entry point. It reads the written file path from stdin and routes to the correct validator. The existing `patch-state-session.sh` logic for state.json is inlined.

- [ ] **Step 1: Create the dispatcher script**

```bash
#!/bin/bash
# PostToolUse(Write) dispatcher — routes artifact writes to validators
# Exit 0 = pass, Exit 2 = block (message on stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# No file path → pass through
[ -z "$FILE" ] && exit 0

# Route based on file name within .agent-dev/
case "$FILE" in
  */.agent-dev/state.json)
    # Inline the existing patch-state-session logic
    [ ! -f "$FILE" ] && exit 0
    command -v jq &>/dev/null || exit 0
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
    [ -z "$SESSION_ID" ] && exit 0
    TMP="${FILE}.tmp.$$"
    jq --arg sid "$SESSION_ID" '.sessionId = $sid' "$FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$FILE"
    if ! jq -e '.phase and .pipelineId' "$FILE" >/dev/null 2>&1; then
      echo "WARNING: state.json missing required fields." >&2
    fi
    exit 0
    ;;
  */.agent-dev/plan.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-plan.sh"
    ;;
  */.agent-dev/code-review.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-code-review.sh"
    ;;
  */.agent-dev/review.json)
    echo "$INPUT" | bash "$SCRIPT_DIR/validate-review.sh"
    ;;
  *)
    exit 0
    ;;
esac
```

Write this to `scripts/validate-artifacts.sh`.

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/validate-artifacts.sh`

- [ ] **Step 3: Verify the script parses stdin correctly**

Run: `echo '{"tool_input":{"file_path":"/tmp/test/.agent-dev/state.json"},"session_id":"test-123"}' | bash scripts/validate-artifacts.sh; echo "exit: $?"`

Expected: `exit: 0` (state.json path → inline session patch, file doesn't exist → early exit 0)

- [ ] **Step 4: Commit**

```bash
git add scripts/validate-artifacts.sh
git commit -m "feat(scripts): add validate-artifacts.sh dispatcher for PostToolUse(Write)"
```

---

### Task 2: Create `validate-plan.sh`

**Files:**
- Create: `scripts/validate-plan.sh`

Validates plan.json writes: every non-scaffolding step must have non-empty `acRefs`, and all AC-N references must be within range of requirement.json's AC count.

- [ ] **Step 1: Create the validation script**

```bash
#!/bin/bash
# Validates plan.json: acRefs traceability + AC range check
# Called by validate-artifacts.sh — reads hook INPUT from stdin
# Exit 0 = pass, Exit 2 = block

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

[ -z "$FILE" ] || [ ! -f "$FILE" ] && exit 0
command -v jq &>/dev/null || exit 0

# Check: steps array exists
if ! jq -e '.steps' "$FILE" >/dev/null 2>&1; then
  exit 0  # Not a plan.json we recognize — pass through
fi

# Check 1: Every non-scaffolding step must have non-empty acRefs
EMPTY_REFS=$(jq '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0)] | length' "$FILE" 2>/dev/null)
if [ "${EMPTY_REFS:-0}" -gt 0 ]; then
  NAMES=$(jq -r '[.steps[] | select(.scaffolding != true) | select((.acRefs // []) | length == 0) | "Step \(.index): \(.title)"] | join(", ")' "$FILE" 2>/dev/null)
  echo "BLOCKED: $EMPTY_REFS step(s) have empty acRefs — each must trace to an AC or set scaffolding:true. Missing: $NAMES" >&2
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
      echo "BLOCKED: acRef AC-$MAX_REF exceeds requirement AC count ($AC_COUNT)." >&2
      exit 2
    fi
  fi
fi

exit 0
```

Write this to `scripts/validate-plan.sh`.

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/validate-plan.sh`

- [ ] **Step 3: Test — valid plan passes**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"acceptanceCriteria":["AC1","AC2","AC3"]}' > "$TMPDIR/.agent-dev/requirement.json"
echo '{"steps":[{"index":1,"title":"test","acRefs":["AC-1"],"scaffolding":false}]}' > "$TMPDIR/.agent-dev/plan.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/plan.json\"}}" | bash scripts/validate-plan.sh; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `exit: 0`

- [ ] **Step 4: Test — empty acRefs blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"acceptanceCriteria":["AC1"]}' > "$TMPDIR/.agent-dev/requirement.json"
echo '{"steps":[{"index":1,"title":"bad step","acRefs":[],"scaffolding":false}]}' > "$TMPDIR/.agent-dev/plan.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/plan.json\"}}" | bash scripts/validate-plan.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: 1 step(s) have empty acRefs` and `exit: 2`

- [ ] **Step 5: Test — scaffolding steps are exempt**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"acceptanceCriteria":["AC1"]}' > "$TMPDIR/.agent-dev/requirement.json"
echo '{"steps":[{"index":1,"title":"infra","acRefs":[],"scaffolding":true}]}' > "$TMPDIR/.agent-dev/plan.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/plan.json\"}}" | bash scripts/validate-plan.sh; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `exit: 0`

- [ ] **Step 6: Test — AC range overflow blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"acceptanceCriteria":["AC1","AC2"]}' > "$TMPDIR/.agent-dev/requirement.json"
echo '{"steps":[{"index":1,"title":"test","acRefs":["AC-5"],"scaffolding":false}]}' > "$TMPDIR/.agent-dev/plan.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/plan.json\"}}" | bash scripts/validate-plan.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: acRef AC-5 exceeds requirement AC count (2)` and `exit: 2`

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-plan.sh
git commit -m "feat(scripts): add validate-plan.sh — acRefs traceability gate"
```

---

### Task 3: Create `validate-code-review.sh`

**Files:**
- Create: `scripts/validate-code-review.sh`

Validates code-review.json: scoring consistency (FIX_REQUIRED ≤ 72), rubric completeness (4 dimensions), hard fail threshold (any < 5 → FIX_REQUIRED), confidence derivation (mean ± 5). Warns on early-stop eligibility and missing QA for web-hybrid.

- [ ] **Step 1: Create the validation script**

```bash
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
```

Write this to `scripts/validate-code-review.sh`.

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/validate-code-review.sh`

- [ ] **Step 3: Test — valid APPROVE passes**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":80,"rubricScores":{"correctness":8,"completeness":8,"convention":8,"regression":8},"testResult":"PASS","lintResult":"PASS"}' > "$TMPDIR/.agent-dev/code-review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/code-review.json\"}}" | bash scripts/validate-code-review.sh; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `exit: 0`

- [ ] **Step 4: Test — FIX_REQUIRED + confidence 88 blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"FIX_REQUIRED","confidence":88,"rubricScores":{"correctness":9,"completeness":5,"convention":8,"regression":9},"testResult":"PASS","lintResult":"PASS"}' > "$TMPDIR/.agent-dev/code-review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/code-review.json\"}}" | bash scripts/validate-code-review.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: FIX_REQUIRED verdict with confidence 88 > 72` and `exit: 2`

- [ ] **Step 5: Test — rubric score < 5 with APPROVE blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":65,"rubricScores":{"correctness":8,"completeness":4,"convention":7,"regression":7},"testResult":"PASS","lintResult":"PASS"}' > "$TMPDIR/.agent-dev/code-review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/code-review.json\"}}" | bash scripts/validate-code-review.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: Rubric score 4 < 5 requires FIX_REQUIRED verdict` and `exit: 2`

- [ ] **Step 6: Test — confidence diverges from rubric mean blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":90,"rubricScores":{"correctness":7,"completeness":7,"convention":7,"regression":7},"testResult":"PASS","lintResult":"PASS"}' > "$TMPDIR/.agent-dev/code-review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/code-review.json\"}}" | bash scripts/validate-code-review.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: confidence 90 diverges from rubric mean 70 by 20 (max ±5)` and `exit: 2`

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-code-review.sh
git commit -m "feat(scripts): add validate-code-review.sh — rubric scoring constraints"
```

---

### Task 4: Create `validate-review.sh`

**Files:**
- Create: `scripts/validate-review.sh`

Validates review.json: groundingCheck must exist, ungrounded > 0 blocks APPROVE.

- [ ] **Step 1: Create the validation script**

```bash
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
```

Write this to `scripts/validate-review.sh`.

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/validate-review.sh`

- [ ] **Step 3: Test — valid APPROVE passes**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":80,"groundingCheck":{"apiChangesInDesign":1,"groundedInAC":1,"ungrounded":0},"issues":[],"summary":"ok"}' > "$TMPDIR/.agent-dev/review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/review.json\"}}" | bash scripts/validate-review.sh; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `exit: 0`

- [ ] **Step 4: Test — missing groundingCheck blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":82,"issues":[],"summary":"ok"}' > "$TMPDIR/.agent-dev/review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/review.json\"}}" | bash scripts/validate-review.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: review.json must include groundingCheck field` and `exit: 2`

- [ ] **Step 5: Test — ungrounded + APPROVE blocks**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"verdict":"APPROVE","confidence":82,"groundingCheck":{"apiChangesInDesign":1,"groundedInAC":0,"ungrounded":1},"issues":[],"summary":"ok"}' > "$TMPDIR/.agent-dev/review.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/review.json\"}}" | bash scripts/validate-review.sh 2>&1; echo "exit: $?"
rm -rf "$TMPDIR"
```

Expected: `BLOCKED: 1 ungrounded API change(s) found but verdict is APPROVE` and `exit: 2`

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-review.sh
git commit -m "feat(scripts): add validate-review.sh — groundingCheck enforcement"
```

---

### Task 5: Update `hooks.json` — wire dispatcher

**Files:**
- Modify: `hooks/hooks.json`

Replace the PostToolUse Write hook entry from `patch-state-session.sh` to `validate-artifacts.sh`.

- [ ] **Step 1: Edit hooks.json**

In `hooks/hooks.json`, replace the PostToolUse section:

Old:
```json
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/patch-state-session.sh\"",
            "timeout": 5
          }
        ]
      }
    ],
```

New:
```json
    "PostToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/validate-artifacts.sh\"",
            "timeout": 5,
            "statusMessage": "Validating pipeline artifact..."
          }
        ]
      }
    ],
```

- [ ] **Step 2: Verify JSON is valid**

Run: `jq . hooks/hooks.json > /dev/null && echo "valid" || echo "invalid"`

Expected: `valid`

- [ ] **Step 3: End-to-end test — state.json session injection still works through dispatcher**

Run:
```bash
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/.agent-dev"
echo '{"pipelineId":"test","phase":"FETCH","sessionId":null}' > "$TMPDIR/.agent-dev/state.json"
echo "{\"tool_input\":{\"file_path\":\"$TMPDIR/.agent-dev/state.json\"},\"session_id\":\"new-session-id\"}" | bash scripts/validate-artifacts.sh
jq -r '.sessionId' "$TMPDIR/.agent-dev/state.json"
rm -rf "$TMPDIR"
```

Expected: `new-session-id`

- [ ] **Step 4: Commit**

```bash
git add hooks/hooks.json
git commit -m "feat(hooks): route PostToolUse(Write) through validate-artifacts dispatcher"
```

---

### Task 6: Update `code-reviewer.md` — rubricScores JSON + few-shot calibration + Interactive QA

**Files:**
- Modify: `agents/code-reviewer.md`

Three changes: (1) add structured `rubricScores` to JSON output, (2) add few-shot calibration examples, (3) add Chrome DevTools tools and Interactive QA section.

- [ ] **Step 1: Update frontmatter tools**

In `agents/code-reviewer.md`, change line 7:

Old: `tools: Read, Glob, Grep, Bash, LSP`
New: `tools: Read, Glob, Grep, Bash, LSP, mcp__plugin_agent-dev_chrome-devtools__*`

- [ ] **Step 2: Add Scoring Constraints section after Review Criteria**

Insert after the `## Review Criteria` section (after line 49), before `## Output Format`:

```markdown
## Scoring Constraints (script-enforced)

These constraints are validated by `validate-code-review.sh` — violating them blocks the write.

- **FIX_REQUIRED → confidence ≤ 72**. If issues need fixing, quality is not 80+.
- **Any rubric dimension < 5 → verdict must be FIX_REQUIRED**.
- **confidence = floor(mean(rubricScores) * 10)**, tolerance ±5.
- Missing tests specified in plan.json testSpec → Completeness ≤ 6/10.
- Missing ACs → Completeness = min(6, floor(10 * covered/total)).

### Double-Layer Review

**Layer 1 — Hard Gates** (check BEFORE scoring, any fail → FIX_REQUIRED):
1. Build/typecheck passes
2. All TESTABLE step tests pass (excluding baselineFailures)
3. Lint passes
4. Every plan.json step's files appear in the diff
5. Every TESTABLE step's testSpec.testFile exists

**Layer 2 — Quality Scoring** (only if all hard gates pass):
Score each rubric dimension 1-10 with the calibration anchors below.
```

- [ ] **Step 3: Add Calibration Examples section**

Insert after the new Scoring Constraints section:

```markdown
## Calibration Examples

### Example A: High score + FIX_REQUIRED (WRONG)

Scenario: All tests pass, lint passes, but tech design specified `RecsysRankerV2AbGroupTest.kt` unit tests which are missing from implementation.

```
❌ WRONG:
CONFIDENCE: 88
VERDICT: FIX_REQUIRED
RUBRIC_SCORES:
- Correctness: 9/10
- Completeness: 8/10  ← WRONG: missing required tests
- Convention: 9/10
- Regression: 9/10

✅ CORRECT:
CONFIDENCE: 68
VERDICT: FIX_REQUIRED
RUBRIC_SCORES:
- Correctness: 9/10 (logic correct, edge cases handled)
- Completeness: 5/10 (test file required by plan.json testSpec is missing)
- Convention: 8/10 (minor putLong → putInt inconsistency)
- Regression: 9/10 (all existing tests pass)
```

### Example B: Partial AC coverage + APPROVE (WRONG)

Scenario: 7 of 10 acceptance criteria implemented. No CRITICAL issues.

```
❌ WRONG:
CONFIDENCE: 75
VERDICT: APPROVE

✅ CORRECT:
CONFIDENCE: 55
VERDICT: FIX_REQUIRED
RUBRIC_SCORES:
- Correctness: 7/10 (implemented ACs work correctly)
- Completeness: 4/10 (3 ACs missing — AC-3, AC-7, AC-9)
- Convention: 6/10 (acceptable)
- Regression: 5/10 (insufficient test coverage for new code)
```
```

- [ ] **Step 4: Update Output Format — add rubricScores as JSON + QA fields**

Replace the existing `## Output Format (MUST follow exactly)` section with:

```markdown
## Output Format (MUST follow exactly)

Your output has TWO parts: structured text (for parent to parse) and JSON (for script validation).

### Part 1: Structured Text Output

```
TEST_RESULT: PASS|FAIL|SKIPPED (details if fail; SKIPPED if no test infra)
LINT_RESULT: PASS|FAIL (details if fail)
CONFIDENCE: <0-100>
VERDICT: APPROVE|FIX_REQUIRED

RUBRIC_SCORES:
- Correctness: X/10 (tests pass, logic correct, edge cases handled)
- Completeness: X/10 (N/M ACs covered, all testSpec tests exist)
- Convention: X/10 (follows project patterns from conventions)
- Regression: X/10 (anchor set green, no pre-existing tests broken)

ISSUES:
- [CRITICAL] file:line — description. Fix: suggestion
- [MAJOR] file:line — description. Fix: suggestion
- [MINOR] file:line — description. Fix: suggestion

REQUIREMENTS_COVERAGE:
- ✅ AC1: covered by <file>
- ❌ AC3: missing — <what's needed>

PLAN_COVERAGE:
- ✅ Step 1: "title" — implemented in <file>
- ❌ Step 7: "unit tests" — missing

TEST_COVERAGE:
- ✅ Step 1 (TESTABLE): myhome.test.ts — 3 assertions passing
- ⏭️ Step 2 (VERIFY_ONLY): no test required
- ❌ Step 5 (TESTABLE): test file missing

QA_RESULT: PASS|FAIL|SKIPPED
QA_DETAILS:
- AC-1 (click claim): PASS — button visible, adds to list
- AC-3 (responsive): FAIL — overlaps below 375px

SUMMARY: <one paragraph>
```

### Part 2: JSON Output

After the structured text, output a JSON block that the parent will write to `.agent-dev/code-review.json`:

```json
{
  "testResult": "PASS",
  "lintResult": "PASS",
  "confidence": 68,
  "verdict": "FIX_REQUIRED",
  "rubricScores": {
    "correctness": 9,
    "completeness": 5,
    "convention": 8,
    "regression": 9
  },
  "qaResult": "PASS|FAIL|SKIPPED",
  "qaDetails": [
    {"ac": "AC-1", "action": "click claim button", "result": "PASS", "note": "adds to list"}
  ],
  "visualMatch": {
    "verdict": "MATCH|MISMATCH|PARTIAL|SKIPPED",
    "matches": [],
    "mismatches": []
  },
  "issues": [
    {"severity": "MAJOR", "file": "path", "line": 42, "description": "...", "fix": "..."}
  ],
  "requirementsCoverage": {"covered": ["AC-1", "AC-2"], "missing": ["AC-3"]},
  "summary": "..."
}
```

If interactive QA was not triggered, set `qaResult` to `"SKIPPED"` and omit `qaDetails` / `visualMatch`, or set them to empty.
```

- [ ] **Step 5: Add Interactive QA section at the end of the file**

Append after the Output Format section:

```markdown
## Interactive QA (conditional)

You have access to Chrome DevTools MCP tools for browser-based functional testing.

### Trigger Conditions (ALL must be true)
- `qaCapabilities.web` is `true` in your prompt (parent determines this)
- Implementation diff includes `.vue`, `.scss`, or `.css` file changes
- Project has a dev server command (from `claudeMd`)

If any condition is false, set `qaResult: "SKIPPED"` and skip this section.

### Process

1. **Start dev server** — run the dev command from `claudeMd` (e.g., `pnpm dev`) in background.
   Wait for the port to be listening: `while ! curl -s http://localhost:3000 > /dev/null 2>&1; do sleep 1; done`

2. **Navigate** — use Chrome DevTools `navigate_page` to the affected route.
   Determine the URL from: `affectedRoutes` in your prompt, or infer from changed `.vue` filenames + project router.

3. **Functional verification** — for each AC that implies user interaction:
   - Use `click`, `fill`, `press_key` to execute the interaction
   - Use `take_screenshot` or `evaluate_script` to verify the outcome
   - Record: `AC-N: PASS/FAIL + what you observed`

4. **Visual comparison** (if `figmaScreenshot` provided in your prompt):
   - Use `take_screenshot` of the affected page
   - Compare layout, spacing, colors, typography against the Figma screenshot
   - Record matches and mismatches

5. **Cleanup** — kill the dev server process (find PID from the background job)

### Output

Include `QA_RESULT` and `QA_DETAILS` in both your structured text and JSON output.
Include `visualMatch` in JSON if visual comparison was performed.
```

- [ ] **Step 6: Commit**

```bash
git add agents/code-reviewer.md
git commit -m "feat(code-reviewer): add rubric scoring constraints, few-shot calibration, interactive QA"
```

---

### Task 7: Update `design-reviewer.md` — groundingCheck + few-shot calibration

**Files:**
- Modify: `agents/design-reviewer.md`

Add hard gates, groundingCheck output field, and calibration example.

- [ ] **Step 1: Add Hard Gates section after Review Checklist**

In `agents/design-reviewer.md`, insert after the `## Review Checklist` section (after line 34, before `## Output Format`):

```markdown
## Hard Gates (check BEFORE scoring — any fail → automatic REVISE)

1. **API/Backend Change Grounding Gate**:
   For EVERY item in the design's "API Changes" and "Data Model Changes" sections:
   → Find the specific AC in requirement.json that demands this change
   → If no AC references this change → flag as `[CRITICAL] Ungrounded assumption`
   → Increment `groundingCheck.ungrounded`

2. **Cross-System Coupling Gate**:
   If the design adds a new field/parameter sent from client → server:
   → Is there a simpler client-only alternative that satisfies the ACs?
   → If yes → flag as `[CRITICAL] Unnecessary cross-system coupling`

Any `groundingCheck.ungrounded > 0` → VERDICT must be REVISE (script-enforced by `validate-review.sh`).

## Calibration Example

### Ungrounded API Change (Android AB Test — real case)

Design adds `@Field("ab_group")` to the Retrofit API endpoint.
Requirement says: "CTR tracking" + "feature flag gated by Remote Config".
Remote Config is server-synced — backend already knows the user's group assignment.

```
❌ WRONG:
CONFIDENCE: 82
VERDICT: APPROVE
(reviewer notes "Consider if API field is needed" as MINOR)

✅ CORRECT:
CONFIDENCE: 52
VERDICT: REVISE
groundingCheck: { apiChangesInDesign: 1, groundedInAC: 0, ungrounded: 1 }
ISSUES:
- [CRITICAL] API Changes: Ungrounded assumption — no AC demands client→server
  ab_group transmission. Remote Config provides server-side group assignment.
  Suggestion: Remove @Field("ab_group") from API. Keep ab_group in analytics
  events only (which IS required by CTR tracking ACs).
```
```

- [ ] **Step 2: Update Output Format — add groundingCheck**

Replace the existing `## Output Format (MUST follow exactly)` section with:

```markdown
## Output Format (MUST follow exactly)

```
CONFIDENCE: <0-100>
VERDICT: <APPROVE|REVISE|ESCALATE>

GROUNDING_CHECK:
- API changes in design: N
- Grounded in AC: N
- Ungrounded: N

ISSUES:
- [CRITICAL] <area>: <description>. Suggestion: <fix>
- [MAJOR] <area>: <description>. Suggestion: <fix>
- [MINOR] <area>: <description>. Suggestion: <fix>

STRENGTHS:
- <what's good about this design>

SUMMARY:
<one paragraph overall assessment>
```

After the structured text, output a JSON block for the parent to write to `.agent-dev/review.json`:

```json
{
  "confidence": 75,
  "verdict": "APPROVE",
  "groundingCheck": {
    "apiChangesInDesign": 0,
    "groundedInAC": 0,
    "ungrounded": 0
  },
  "issues": [
    {"severity": "MINOR", "description": "...", "suggestion": "..."}
  ],
  "summary": "..."
}
```

If the design has no API Changes section (or it says "No API changes required"), set all `groundingCheck` values to 0.

Scoring guide:
- 90-100: Excellent, no issues (suspicious if no issues found — look harder)
- 70-89: Good, minor issues only
- 50-69: Acceptable but has major concerns
- 0-49: Significant problems, needs revision

BE HONEST. A score of 95 with no issues means you didn't look hard enough.
```

- [ ] **Step 3: Commit**

```bash
git add agents/design-reviewer.md
git commit -m "feat(design-reviewer): add groundingCheck enforcement, calibration example, hard gates"
```

---

### Task 8: Update `phases.md` — acRefs traceability, iteration changes, QA construction, code-review schema

**Files:**
- Modify: `skills/agent-dev/references/phases.md`

Four edits: (1) Phase 4 add acRefs + traceability check, (2) Phase 3 add early-stopping/fast-fail, (3) Phase 6a add qaCapabilities + code-review.json schema + limit 2→3, (4) Phase 6b simplify to fallback.

- [ ] **Step 1: Phase 4 — add requirement traceability step 5b and acRefs to plan.json schema**

In `skills/agent-dev/references/phases.md`, insert after the existing step 5 bullet about `dependsOn` (after line 215), before step 6:

```markdown
5b. **Requirement traceability check** — for each step in the plan:
    - Identify which AC(s) this step addresses → record as `acRefs: ["AC-1", "AC-5"]`
    - If a step cannot trace to ANY AC:
      → If it's infrastructure/scaffolding required by other steps → set `"scaffolding": true`, `acRefs: []`
      → If it's a standalone feature/API change with no AC backing → REMOVE the step.
        It is an ungrounded addition from the design phase.
    - If tech-design.md has API Changes marked `[ASSUMPTION]` → do NOT include in plan
      unless you independently verify an AC demands it
    - The `validate-plan.sh` script enforces: every non-scaffolding step must have non-empty `acRefs`
```

- [ ] **Step 2: Phase 4 — update plan.json example to include acRefs and scaffolding fields**

In the plan.json example (lines 232-265), update both step examples.

Replace step 1 example:
```json
      {
        "index": 1,
        "title": "MyHome Pinia store",
        "description": "...",
        "designSection": "UI Changes §1",
        "testability": "TESTABLE",
        "acRefs": ["AC-2", "AC-8"],
        "scaffolding": false,
        "testSpec": {
          "testFile": "packages/store/__tests__/myhome.test.ts",
          "testPatternRef": "packages/store/__tests__/watch.test.ts",
          "assertions": ["add() updates claimedIdSet", "remove() clears from set", "fetchList() populates homes"]
        },
        "filesCreate": ["packages/store/myhome.ts"],
        "filesModify": [],
        "patternRef": "packages/store/watch.ts",
        "dependsOn": [],
        "verification": "pnpm vitest run packages/store/__tests__/myhome.test.ts",
        "status": "pending"
      },
```

Replace step 2 example:
```json
      {
        "index": 2,
        "title": "i18n keys",
        "description": "...",
        "designSection": "i18n",
        "testability": "VERIFY_ONLY",
        "acRefs": ["AC-3"],
        "scaffolding": false,
        "filesCreate": [],
        "filesModify": ["packages/common/i18n/translation/en.ts"],
        "patternRef": null,
        "dependsOn": [],
        "verification": "pnpm vtsc:app",
        "status": "pending"
      }
```

Note: `testSpec.acRefs` is removed (moved to step-level `acRefs`). The `testSpec` now only contains `testFile`, `testPatternRef`, and `assertions`.

- [ ] **Step 3: Phase 3 — add early-stopping and fast-fail to decision tree**

In Phase 3 (lines 140-167), replace the decision tree (step 4) with:

```markdown
4. Decision tree (**VERDICT is primary, confidence is secondary**):
   - **VERDICT == APPROVE** + confidence ≥ 75 + `groundingCheck.ungrounded == 0`:
     → **Early-stop**: proceed to PLAN immediately
     → Update state.json: phase → PLAN, reviewConfidence → N
   - **VERDICT == APPROVE** + confidence ≥ 60 (but < 75 or has grounding notes):
     → Proceed to PLAN (standard path)
     → Update state.json: phase → PLAN, reviewConfidence → N
   - **VERDICT == APPROVE BUT confidence < 60**: warn user, ask to confirm or revise
   - **VERDICT == REVISE** + `groundingCheck.ungrounded > 0`:
     → **Fast-fail**: back to Phase 2 with TARGETED feedback — designer must ONLY
       remove/relocate ungrounded items, not full revision
     → Increment reviewRevisionCount in state.json
   - **VERDICT == REVISE** (other issues):
     → If reviewRevisionCount < 3 → back to Phase 2 with issues as feedback
     → Increment reviewRevisionCount in state.json
   - **VERDICT == ESCALATE** OR reviewRevisionCount >= 3:
     → Update state.json: phase → ESCALATED, metrics.interventions += 1
     → Present all issues to user
     → Ask: "要我修复特定问题？还是重新设计？还是手动批准？"
     → On user response: set phase back to DESIGN or PLAN accordingly
```

- [ ] **Step 4: Phase 3 — update review.json schema**

Replace the review.json example in Phase 3 step 3:

```json
   {
     "confidence": 82,
     "verdict": "APPROVE",
     "groundingCheck": {
       "apiChangesInDesign": 0,
       "groundedInAC": 0,
       "ungrounded": 0
     },
     "issues": [{"severity": "MINOR", "description": "..."}],
     "summary": "..."
   }
```

- [ ] **Step 5: Phase 6a — add qaCapabilities construction, update code-review.json schema, change limit 2→3**

In Phase 6a step 2, add qaCapabilities to the prompt construction list (after `baselineBuildFailure`):

```markdown
   - **`qaCapabilities`**: `{ "web": true, "mobile": false }` — set `web: true` when ALL of:
     (1) `targetProject == "web-hybrid"`,
     (2) `git diff --name-only` includes `.vue/.scss/.css` files,
     (3) `claudeMd` documents a dev server command.
     If Figma design exists, also pre-fetch screenshot via Figma MCP and pass as `figmaScreenshot`.
     Pass `devServerCommand`, `devUrl`, and `affectedRoutes` (inferred from diff + router).
```

Update the code-review.json example in step 4:

```json
   {
     "testResult": "PASS|FAIL",
     "lintResult": "PASS|FAIL",
     "confidence": 82,
     "verdict": "APPROVE",
     "rubricScores": {
       "correctness": 8,
       "completeness": 8,
       "convention": 8,
       "regression": 9
     },
     "qaResult": "PASS|FAIL|SKIPPED",
     "qaDetails": [],
     "visualMatch": {"verdict": "SKIPPED", "matches": [], "mismatches": []},
     "issues": [],
     "requirementsCoverage": {"covered": [], "missing": []},
     "summary": "..."
   }
```

In step 5 decision tree, change `codeReviewCount < 2` → `codeReviewCount < 3` and `codeReviewCount >= 2` → `codeReviewCount >= 3`.

- [ ] **Step 6: Phase 6b — add fallback logic at the top**

At the beginning of Phase 6b (after the phase title), insert:

```markdown
**Fallback mode**: If `code-review.json` contains `qaResult` that is NOT `"SKIPPED"` and NOT absent,
the code-reviewer already performed interactive QA. In this case:
1. Write `.agent-dev/visual-review.json`:
   ```json
   { "verdict": "DELEGATED_TO_CODE_REVIEWER", "qaResult": "<value from code-review.json>" }
   ```
2. Skip the rest of Phase 6b → proceed to Phase 7 (PR)

If `qaResult` is `"SKIPPED"` or absent, execute the full VISUAL_CHECK flow below.
```

- [ ] **Step 7: Commit**

```bash
git add skills/agent-dev/references/phases.md
git commit -m "feat(phases): add acRefs traceability, review early-stop, QA construction, code-review limit 2→3"
```

---

### Task 9: Update `SKILL.md` — plan.json example with acRefs

**Files:**
- Modify: `skills/agent-dev/SKILL.md`

Update the plan.json step example in the State Schema section to include `acRefs` and `scaffolding`.

- [ ] **Step 1: Find and update the plan.json step example in SKILL.md**

The plan.json is referenced indirectly in SKILL.md via the plan.json entry in the File Persistence Protocol section. The actual step schema example lives in `phases.md` (already updated in Task 8). However, SKILL.md's overview table mentions plan.json output.

Check if SKILL.md has an inline plan.json schema — if not, no change needed beyond ensuring the Phase Instructions reference is up to date.

Looking at SKILL.md: it does NOT have an inline plan.json schema. The schema lives only in `phases.md`. No change needed to SKILL.md.

- [ ] **Step 2: Skip — no plan.json schema in SKILL.md**

SKILL.md references `phases.md` for detailed phase instructions. The plan.json schema update in Task 8 is sufficient.

---

### Task 10: Update `CLAUDE.md` — stress test protocol + quality gates docs

**Files:**
- Modify: `CLAUDE.md`

Two changes: (1) replace Architecture Stress Testing with structured experiment protocol, (2) update quality gates documentation to reflect new script gates and code review limit.

- [ ] **Step 1: Replace Architecture Stress Testing section**

In `CLAUDE.md`, replace lines 142-150 (the existing `### Architecture Stress Testing` section):

Old:
```markdown
### Architecture Stress Testing

On each model upgrade, test whether pipeline components are still load-bearing:
- Can tech-designer + design-reviewer merge? (Is anti-sycophancy isolation still needed?)
- Can implementer self-review? (Is separate code-reviewer still needed?)
- Can any phase be skipped for standard tasks?
- Does the complexity router's "simple" threshold need adjustment?

Components encode assumptions about model limitations — re-validate as models improve.
```

New:
```markdown
### Architecture Stress Testing

Components encode assumptions about model limitations — re-validate as models improve.
On each model upgrade, run these experiments using the SAME requirement for comparability:

**Experiment 1: Designer + Reviewer Merge**
- Hypothesis: Single agent can generate design AND critically review it
- Control: Current pipeline (separate tech-designer + design-reviewer)
- Variant: Single agent, two-pass (generate → adversarial self-review with full checklist)
- Metric: Ungrounded assumptions caught (control vs variant)
- Pass: Variant catches ≥ 80% of what control catches
- Test requirement: One with known API scope boundaries (e.g., Android AB test)

**Experiment 2: Implementer Self-Review**
- Hypothesis: Implementer can catch its own code issues without separate code-reviewer
- Control: Current pipeline (implementer + code-reviewer)
- Variant: Implementer runs self-review checklist before returning
- Metric: Issues missed by variant that control caught
- Pass: 0 CRITICAL missed, ≤ 1 MAJOR missed

**Experiment 3: Implementer Context Persistence**
- Hypothesis: One invocation per step (fresh context) vs all steps in one invocation
- Control: Current (one invocation, all steps sequential in same context)
- Variant: One invocation per step (fresh context each time)
- Metric: Anchor regression count, total time, context window usage

**How to Run**: Pick a completed pipeline run → re-run same `requirement.json` with variant → compare artifacts (`review.json`, `code-review.json`, `git diff`) → record in `.agent-dev/experiments/<model>-<date>.md`
```

- [ ] **Step 2: Update quality gates documentation**

In `CLAUDE.md`, update the `### Enforcement: Scripts > Prompts` section (lines 60-64) to include the new gates:

Old:
```markdown
Critical gates enforced by hook scripts with `exit 2` (block):
- **Pre-PR gate** (`agent-dev-gate.sh pre-pr`): blocks `gh pr create` unless pipeline is in PR phase
- **Stop hook** (`stop-hook.sh`): prevents session exit mid-pipeline (session-isolated, anti-loop with 3-attempt limit)
- **Session patching** (`patch-state-session.sh`): auto-injects `sessionId` on every `state.json` write
- **Post-compact resume** (`post-compact-resume.sh`): restores pipeline context after compaction
```

New:
```markdown
Critical gates enforced by hook scripts with `exit 2` (block):
- **Pre-PR gate** (`agent-dev-gate.sh pre-pr`): blocks `gh pr create` unless pipeline is in PR phase
- **Stop hook** (`stop-hook.sh`): prevents session exit mid-pipeline (session-isolated, anti-loop with 3-attempt limit)
- **Artifact validation** (`validate-artifacts.sh`): PostToolUse(Write) dispatcher — routes to artifact-specific validators:
  - `validate-plan.sh`: blocks plan.json if any non-scaffolding step has empty `acRefs`
  - `validate-code-review.sh`: blocks code-review.json if FIX_REQUIRED + confidence > 72, rubric < 5 + APPROVE, or confidence diverges from rubric mean
  - `validate-review.sh`: blocks review.json if ungrounded API changes + APPROVE verdict
  - Also inlines session patching for state.json (previously `patch-state-session.sh`)
- **Post-compact resume** (`post-compact-resume.sh`): restores pipeline context after compaction
```

- [ ] **Step 3: Update code-reviewer quality gate description**

In the `### Quality Gates` section (line 70), update the Code-reviewer bullet:

Old:
```markdown
- **Code-reviewer**: RUBRIC_SCORES (Correctness/Completeness/Convention/Regression each X/10), PLAN_COVERAGE, TEST_COVERAGE, REQUIREMENTS_COVERAGE. Uses validated commands from PLAN (not raw CLAUDE.md). Baseline-aware test evaluation. On FIX_REQUIRED: re-invokes implementer in **fix mode** (not parent) — implementer reconstructs anchor set from git history, addresses issues by severity, commits fix. Max 2 rounds before ESCALATE.
```

New:
```markdown
- **Code-reviewer**: Double-layer review: Hard Gates (binary pass/fail) then RUBRIC_SCORES (Correctness/Completeness/Convention/Regression each X/10, script-enforced consistency). Interactive QA via Chrome DevTools MCP for web-hybrid (conditional). PLAN_COVERAGE, TEST_COVERAGE, REQUIREMENTS_COVERAGE. Uses validated commands from PLAN (not raw CLAUDE.md). Baseline-aware test evaluation. On FIX_REQUIRED: re-invokes implementer in **fix mode** (not parent) — implementer reconstructs anchor set from git history, addresses issues by severity, commits fix. Max 3 rounds before ESCALATE.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(CLAUDE): update quality gates for v1.6.0, add stress test experiment protocol"
```

---

### Task 11: Update `plugin.json` version

**Files:**
- Modify: `.claude-plugin/plugin.json`

- [ ] **Step 1: Bump version to 1.6.0**

In `.claude-plugin/plugin.json`, change:

Old: `"version": "1.5.0",`
New: `"version": "1.6.0",`

- [ ] **Step 2: Commit**

```bash
git add .claude-plugin/plugin.json
git commit -m "chore: bump version to v1.6.0"
```

---

### Task 12: Integration verification

No new files. Run all validation scripts against the real Android pipeline artifacts to verify they work on actual data.

- [ ] **Step 1: Test validate-plan.sh against Android plan.json**

Run:
```bash
echo "{\"tool_input\":{\"file_path\":\"/Users/lazyman/housesigma/housesigma-android-native/.agent-dev/plan.json\"}}" | bash scripts/validate-plan.sh 2>&1; echo "exit: $?"
```

Expected: `exit: 2` — the Android plan.json steps have no `acRefs` field (old schema). This confirms the gate would have caught the missing traceability.

- [ ] **Step 2: Test validate-code-review.sh against Android code-review.json**

Run:
```bash
echo "{\"tool_input\":{\"file_path\":\"/Users/lazyman/housesigma/housesigma-android-native/.agent-dev/code-review.json\"}}" | bash scripts/validate-code-review.sh 2>&1; echo "exit: $?"
```

Expected: `exit: 2` — the Android code-review.json has confidence 88 + FIX_REQUIRED (no rubricScores field either). This confirms the gate would have caught the scoring bias.

- [ ] **Step 3: Test validate-review.sh against Android review.json**

Run:
```bash
echo "{\"tool_input\":{\"file_path\":\"/Users/lazyman/housesigma/housesigma-android-native/.agent-dev/review.json\"}}" | bash scripts/validate-review.sh 2>&1; echo "exit: $?"
```

Expected: `exit: 2` — the Android review.json has no `groundingCheck` field. This confirms the gate would have caught the missing grounding check.

- [ ] **Step 4: Test dispatcher routing end-to-end**

Run:
```bash
echo "{\"tool_input\":{\"file_path\":\"/Users/lazyman/housesigma/housesigma-android-native/.agent-dev/plan.json\"}}" | bash scripts/validate-artifacts.sh 2>&1; echo "exit: $?"
```

Expected: `exit: 2` — dispatcher routes to validate-plan.sh which blocks the old-format plan.json.

- [ ] **Step 5: Verify all scripts are executable**

Run: `ls -la scripts/validate-*.sh`

Expected: all four scripts have `x` permission.

- [ ] **Step 6: No commit needed — this is verification only**
