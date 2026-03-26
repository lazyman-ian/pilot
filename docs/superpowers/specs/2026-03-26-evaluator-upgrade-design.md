# Evaluator Upgrade: Calibration + Interactive QA + Iteration Enhancement

**Date**: 2026-03-26
**Version target**: v1.6.0
**Source**: Gap analysis against [Anthropic: Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps)
**Scope**: 4 scripts new, 6 files modified, 0 new agents, 0 architecture topology changes

---

## Problem Statement

Pipeline evaluators (code-reviewer, design-reviewer) have three systemic issues:

1. **Scoring bias**: code-reviewer produces high confidence (82-88) with FIX_REQUIRED verdict. Android test: 88 + FIX_REQUIRED with missing unit tests. This is the "talk itself into approval" pattern Anthropic describes.

2. **Hallucinated features**: tech-designer invents plausible API changes not in requirements. design-reviewer fails to catch them. PLAN faithfully implements the hallucination. Android test: `ab_group` API field added to `RequestApiService.getRecommendList` — no AC demanded this.

3. **No functional verification**: code-reviewer only runs CLI tests and reads diffs. Cannot detect "button doesn't work", "state doesn't update", "route doesn't navigate" — bugs that only surface in a running application.

### Evidence

| Run | Problem | Root Cause |
|-----|---------|------------|
| Android v1.5.0 | confidence 88 + FIX_REQUIRED | No scoring constraints, rubric scores not structured |
| Android v1.5.0 | `ab_group` API field hallucinated | No requirement traceability in PLAN, reviewer missed ungrounded assumption |
| v0.8.1 web-hybrid | confidence 82 + FIX_REQUIRED | Same scoring bias pattern |
| v0.1-v0.3 | 7/10 ACs covered but APPROVE | No hard gate linking AC coverage to verdict |

### Anti-sycophancy research finding

Self-preference bias (LLM favors its own output due to lower perplexity) is architecturally inherent, not fixable by RLHF alone (EMNLP 2025: "Self-Preference Bias in LLM-as-a-Judge"). Anthropic's own guidance: "Tuning a standalone evaluator to be skeptical is far more tractable than making a generator critical of its own work." Designer/reviewer remain separate. Context strategy changes deferred to structured A/B experiments on model upgrades.

---

## §1: Evaluator Calibration — Script-Enforced Scoring

### Principle

`Scripts > Prompts`. Structurally validatable constraints go in scripts (exit 2 = block). Semantic guidance stays in prompts as auxiliary.

### 1.1 JSON Schema Changes

**code-review.json** — add `rubricScores` as structured object:

```json
{
  "testResult": "PASS|FAIL|SKIPPED",
  "lintResult": "PASS|FAIL",
  "confidence": 68,
  "verdict": "FIX_REQUIRED|APPROVE",
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
    {"severity": "CRITICAL|MAJOR|MINOR", "file": "path", "line": 0, "description": "...", "fix": "..."}
  ],
  "requirementsCoverage": {"covered": [], "missing": []},
  "summary": "..."
}
```

**review.json** — add `groundingCheck`:

```json
{
  "confidence": 52,
  "verdict": "REVISE|APPROVE|ESCALATE",
  "groundingCheck": {
    "apiChangesInDesign": 1,
    "groundedInAC": 0,
    "ungrounded": 1
  },
  "issues": [
    {"severity": "CRITICAL|MAJOR|MINOR", "description": "...", "suggestion": "..."}
  ],
  "summary": "..."
}
```

**plan.json steps** — add mandatory `acRefs`:

```json
{
  "index": 1,
  "title": "...",
  "acRefs": ["AC-1", "AC-5"],
  "scaffolding": false,
  "testability": "TESTABLE|VERIFY_ONLY",
  ...
}
```

Steps with no AC mapping must set `"scaffolding": true` (infrastructure required by other steps).

### 1.2 Validation Scripts

#### `scripts/validate-artifacts.sh` (NEW — dispatcher)

PostToolUse(Write) hook. Replaces `patch-state-session.sh` as the single Write hook entry point. Routes based on file path:

- `**/state.json` → call `patch-state-session.sh` inline (existing sessionId injection logic, moved into dispatcher)
- `**/plan.json` → `validate-plan.sh`
- `**/code-review.json` → `validate-code-review.sh`
- `**/review.json` → `validate-review.sh`
- Others → exit 0

Only one PostToolUse(Write) hook in hooks.json — `validate-artifacts.sh` is the sole entry point. `patch-state-session.sh` is called as a function, not a separate hook.

#### `scripts/validate-plan.sh` (NEW)

| Check | Condition | Action |
|-------|-----------|--------|
| acRefs present | Every step (where `scaffolding != true`) has non-empty `acRefs` | exit 2 |
| AC range valid | All AC-N references ≤ requirement.json AC count | exit 2 |

#### `scripts/validate-code-review.sh` (NEW)

| Check | Condition | Action |
|-------|-----------|--------|
| Scoring consistency | FIX_REQUIRED → confidence ≤ 72 | exit 2 |
| Rubric completeness | `rubricScores` has exactly 4 dimensions | exit 2 |
| Hard fail threshold | Any rubric dimension < 5 → verdict must be FIX_REQUIRED | exit 2 |
| Confidence derivation | confidence diverges from `floor(mean(rubricScores) * 10)` by > 5 | exit 2 |
| Early-stop hint | All rubric ≥ 8 + PASS tests/lint but verdict ≠ APPROVE | warn (no block) |
| QA missing hint | web-hybrid project but qaResult absent | warn (no block) |

#### `scripts/validate-review.sh` (NEW)

| Check | Condition | Action |
|-------|-----------|--------|
| groundingCheck present | `groundingCheck` field must exist | exit 2 |
| Ungrounded → REVISE | `ungrounded > 0` but verdict is APPROVE | exit 2 |

### 1.3 hooks.json Change

Add `validate-artifacts.sh` to PostToolUse(Write). Existing `patch-state-session.sh` becomes a sub-call within the dispatcher (only for state.json writes).

### 1.4 Prompt Changes (auxiliary)

**code-reviewer.md** additions:

- Calibration Examples section with two few-shot examples:
  - Example A: "88 + FIX_REQUIRED → WRONG. 68 + FIX_REQUIRED → CORRECT" (Android case)
  - Example B: "7/10 ACs + APPROVE → WRONG. 55 + FIX_REQUIRED → CORRECT" (v0.1 case)
- Scoring Constraints section (text description of what scripts enforce)
- Double-layer review process: Hard Gates (binary) checked before Quality Scoring (rubric)

**design-reviewer.md** additions:

- Hard Gates section: API/backend change grounding gate, cross-system coupling gate
- Calibration Example: ungrounded `ab_group` API field (Android case)
- `groundingCheck` output field specification

**phases.md** Phase 4 addition:

- Step 5b: Requirement traceability check — each step must trace to AC(s), record as `acRefs`
- Steps that cannot trace to any AC and are not scaffolding → remove from plan
- `[ASSUMPTION]`-tagged items from tech-design.md → do NOT include unless independently verified

### 1.5 Files Affected

| File | Change Type | Description |
|------|-------------|-------------|
| `scripts/validate-artifacts.sh` | NEW | Dispatcher routing writes to validators |
| `scripts/validate-plan.sh` | NEW | acRefs non-empty + AC range check |
| `scripts/validate-code-review.sh` | NEW | Rubric consistency + scoring constraints |
| `scripts/validate-review.sh` | NEW | groundingCheck + ungrounded block |
| `hooks/hooks.json` | MODIFY | Add validate-artifacts to PostToolUse(Write) |
| `agents/code-reviewer.md` | MODIFY | +rubricScores output + few-shot + constraints + double-layer process |
| `agents/design-reviewer.md` | MODIFY | +groundingCheck output + few-shot + hard gates |
| `skills/pilot/references/phases.md` | MODIFY | Phase 4 +acRefs + traceability check |
| `skills/pilot/SKILL.md` | MODIFY | plan.json example update (acRefs) |

---

## §2: Interactive QA — Code-Reviewer Browser Capability

### 2.1 Architecture Decision

Merge VISUAL_CHECK capability into code-reviewer. Rationale:

- Anthropic's evaluator combines code review + Playwright interaction in one agent
- Separation causes information gap: code-reviewer lacks runtime context, parent doing visual check lacks code context
- Unified evaluator can: read diff → run tests → start app → interact → screenshot → holistic judgment

VISUAL_CHECK phase retained as fallback when code-reviewer skips interactive QA.

### 2.2 Code-Reviewer Tool Change

Current: `Read, Glob, Grep, Bash, LSP`

New: `Read, Glob, Grep, Bash, LSP, mcp__plugin_pilot_chrome-devtools__*`

### 2.3 Interactive QA Protocol

Added to code-reviewer.md as conditional section.

**Trigger** (all must be true):
- `qaCapabilities.web == true` in prompt (parent determines this)
- Implementation diff includes `.vue/.scss/.css` files
- Project has a dev server command (from claudeMd)

**Process**:
1. Start dev server in background, wait for port
2. Navigate to affected page (inferred from requirement + changed files + claudeMd dev URL)
3. Functional verification: for each AC implying user interaction, execute and verify
4. Visual comparison (if figmaScreenshot provided): screenshot + compare against Figma
5. Kill dev server

**Output fields** in code-review.json:
- `qaResult`: PASS|FAIL|SKIPPED
- `qaDetails`: array of `{ac, action, result, note}`
- `visualMatch`: `{verdict, matches, mismatches}`

### 2.4 Parent Prompt Construction

Phase 6a code-reviewer invocation injects:

```json
{
  "qaCapabilities": { "web": true, "mobile": false },
  "figmaScreenshot": "<base64 or path, if Figma design exists>",
  "devServerCommand": "pnpm dev",
  "devUrl": "http://localhost:3000",
  "affectedRoutes": ["/listing/123"]
}
```

`qaCapabilities.web` = true when ALL of:
1. `targetProject == "web-hybrid"`
2. `git diff` includes `.vue/.scss/.css` files
3. `claudeMd` documents a dev server command

Parent fetches Figma screenshot (via Figma MCP) before invoking code-reviewer, since MCP auth doesn't propagate to subagents.

### 2.5 VISUAL_CHECK Phase Simplification

```
If code-review.json has qaResult != SKIPPED:
  → Skip VISUAL_CHECK, write visual-review.json:
    { "verdict": "DELEGATED_TO_CODE_REVIEWER", "qaResult": "<reference>" }
  → Proceed to PR

If qaResult == SKIPPED or absent:
  → Execute existing VISUAL_CHECK flow (parent does screenshot comparison)
```

### 2.6 Mobile Extensibility

`qaCapabilities.mobile` reserved for future. When implemented:
- Android: `adb shell` + screenshot via Chrome DevTools remote debugging
- iOS: `xcrun simctl` + screenshot
- code-reviewer.md would get platform-specific QA subsections

### 2.7 Files Affected

| File | Change Type | Description |
|------|-------------|-------------|
| `agents/code-reviewer.md` | MODIFY | +Chrome DevTools tools + Interactive QA section + qa output fields |
| `skills/pilot/references/phases.md` | MODIFY | Phase 6a +qaCapabilities construction, Phase 6b simplified to fallback |
| `scripts/validate-code-review.sh` | MODIFY | +qaResult warning for web-hybrid |

---

## §3: Iteration Loop Enhancement

### 3.1 Design Principle

Requirements are fine-grained with clear ACs — many rounds are not typical. Focus on per-round precision (§1 calibration) and smart early/fast termination.

### 3.2 Design Review Changes

**Limits**: max 3 rounds (unchanged).

**Early-stopping** (new):
- Round 1 APPROVE + confidence ≥ 75 + `groundingCheck.ungrounded == 0` → skip further rounds, proceed to PLAN

**Fast-fail** (new):
- Round 1 has `groundingCheck.ungrounded > 0` → targeted fix request to designer (remove/relocate ungrounded items only, not full revision)

### 3.3 Code Review Changes

**Limits**: max 2 → 3 rounds.

**Early-stopping** (new, script-hinted):
- All 4 rubric dimensions ≥ 8 + qaResult ≠ FAIL + testResult == PASS + lintResult == PASS → APPROVE on first review

**Fix routing**: All FIX_REQUIRED → implementer fix mode → re-invoke code-reviewer. No MINOR/MAJOR split — implementer handles all fixes (has code context), code-reviewer always re-reviews (single JSON write pattern, no state merging complexity).

### 3.4 Files Affected

| File | Change Type | Description |
|------|-------------|-------------|
| `skills/pilot/references/phases.md` | MODIFY | Phase 3 +early-stopping/fast-fail, Phase 6a code review limit 2→3 |
| `scripts/validate-code-review.sh` | MODIFY | +early-stopping hint (warn, no block) |

---

## §4: Context Strategy — Experiment Protocol

### 4.1 Decision

Keep designer/reviewer separate. Self-preference bias is architecturally inherent (perplexity-based, not RLHF-solvable). Anthropic's production systems (Claude Code Review, harness blog) all use separate context windows.

### 4.2 Structured Experiment Protocol

Replace descriptive text in CLAUDE.md `### Architecture Stress Testing` with executable protocol:

#### Experiment 1: Designer + Reviewer Merge
- **Hypothesis**: Single agent can generate AND critically review design
- **Control**: Current pipeline (separate agents)
- **Variant**: Single agent, two-pass (generate → adversarial self-review)
- **Metric**: Ungrounded assumptions caught (control vs variant)
- **Pass**: Variant catches ≥ 80% of what control catches
- **Test requirement**: One with known API scope boundaries (e.g., Android AB test)

#### Experiment 2: Implementer Self-Review
- **Hypothesis**: Implementer can catch its own code issues
- **Control**: Current pipeline (implementer + code-reviewer)
- **Variant**: Implementer self-review checklist before returning
- **Metric**: Issues missed by variant that control caught
- **Pass**: 0 CRITICAL missed, ≤ 1 MAJOR missed

#### Experiment 3: Implementer Context Persistence
- **Hypothesis**: Keeping implementer alive across steps vs fresh context per step
- **Control**: Current (one invocation, all steps sequential)
- **Variant**: One invocation per step (fresh context each time)
- **Metric**: Anchor regression count, total time, context usage

#### How to Run
1. Pick a completed pipeline run with known results
2. Re-run same requirement.json with variant architecture
3. Compare artifacts (review.json, code-review.json, git diff)
4. Record in `.pilot/experiments/<model>-<date>.md`

### 4.3 Files Affected

| File | Change Type | Description |
|------|-------------|-------------|
| `CLAUDE.md` | MODIFY | Architecture Stress Testing → structured protocol |

---

## Complete File Impact Matrix

| File | §1 | §2 | §3 | §4 | Change Type |
|------|----|----|----|----|-------------|
| `scripts/validate-artifacts.sh` | ✦ | | | | NEW |
| `scripts/validate-plan.sh` | ✦ | | | | NEW |
| `scripts/validate-code-review.sh` | ✦ | ✦ | ✦ | | NEW |
| `scripts/validate-review.sh` | ✦ | | | | NEW |
| `hooks/hooks.json` | ✦ | | | | MODIFY |
| `agents/code-reviewer.md` | ✦ | ✦ | | | MODIFY |
| `agents/design-reviewer.md` | ✦ | | | | MODIFY |
| `skills/pilot/references/phases.md` | ✦ | ✦ | ✦ | | MODIFY |
| `skills/pilot/SKILL.md` | ✦ | | | | MODIFY |
| `CLAUDE.md` | | | | ✦ | MODIFY |

**4 new scripts, 6 modified files, 0 new agents.**

---

## Implementation Order

1. §1 Calibration scripts + prompt changes (highest impact, unblocks everything)
2. §2 Interactive QA (depends on §1 code-review.json schema)
3. §3 Iteration loop (depends on §1 rubric scoring)
4. §4 Protocol documentation (independent, can be done anytime)

## Out of Scope

- Designer/reviewer merge (deferred to experiment protocol)
- Mobile interactive QA (interface reserved, implementation deferred)
- Cost tracking per phase (informational, low priority)
- Sprint contract negotiation pattern from article (unnecessary — plan.json + acRefs serves same purpose)
