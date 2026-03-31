# Pipeline Robustness Enhancement — Design Spec

**Date**: 2026-03-31
**Status**: Draft
**Scope**: Comprehensive robustness, universality, and BDD behavioral verification for pilot plugin
**Approach**: Hybrid — script gates for critical paths + smart agents for judgment calls
**Phases**: 6 sections, phased implementation

---

## Table of Contents

- [§1 Fault Tolerance & Recovery](#1-fault-tolerance--recovery)
- [§2 Review Quality Enhancement](#2-review-quality-enhancement)
- [§3 Figma→Code Visual Verification](#3-figmacode-visual-verification)
- [§4 BDD Behavioral Verification](#4-bdd-behavioral-verification)
- [§5 Plan/Spec Multi-Dimension Reference](#5-planspec-multi-dimension-reference)
- [§6 Universality & Cross-Project Adaptation](#6-universality--cross-project-adaptation)
- [Priority Chain & Phase Ordering](#priority-chain--phase-ordering)
- [Implementation Phases](#implementation-phases)
- [Future Roadmap](#future-roadmap)

---

## §1 Fault Tolerance & Recovery

### 1.1 Four-Status Subagent Reporting Protocol

All subagents (tech-designer, design-reviewer, implementer, code-reviewer) must include a structured `status` field in their output:

| Status | Meaning | Parent Behavior |
|--------|---------|----------------|
| `DONE` | Normal completion | Proceed to next phase |
| `DONE_WITH_CONCERNS` | Completed with doubts | Record concerns to `.pilot/concerns.json`, continue pipeline but inject concerns into code-review as additional checkpoints |
| `NEEDS_CONTEXT` | Missing information | Parent attempts auto-supplement (read files, query APIs), then re-dispatch; if unable → ESCALATE |
| `BLOCKED` | Unrecoverable blocker | Immediately ESCALATE to user |

**Enforcement**: `validate-artifacts.sh` checks subagent output for `status` field — must exist AND be one of the four valid enum values (`DONE`, `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`). Missing or invalid → `exit 2`.

**NEEDS_CONTEXT re-dispatch cap**: Parent attempts auto-supplement at most **2 times** (read files listed in the NEEDS_CONTEXT response, nothing more). If subagent returns NEEDS_CONTEXT a 3rd time → auto-escalate to BLOCKED.

**concerns.json schema**:
```json
{
  "phase": "IMPLEMENT",
  "concerns": [
    {
      "step": 3,
      "description": "Used deprecated API pattern, couldn't find replacement in codebase",
      "severity": "medium",
      "suggestedCheck": "Verify API compatibility during code review"
    }
  ]
}
```

**concerns.json injection into code-review**: When `concerns.json` exists, parent serializes each concern as an additional SPEC_COMPLIANCE checklist item in the code-reviewer prompt. Code-reviewer must mark each concern as `addressed` (verified fixed), `acknowledged` (verified not an issue), or `confirmed` (verified still an issue → finding). Script enforcement: if `concerns.json` exists but `code-review.json` lacks `concernsResolution` field → `exit 2`.

### 1.2 Three-Fix Architectural Escape Hatch

Current: code-review fix rounds max at 3, then ESCALATE.

**Enhancement**: On 3rd fix failure, enter **architectural reflection mode** before escalating:

1. Collect all 3 rounds of diffs + reviewer comments
2. Generate `.pilot/architectural-concern.md`:
   - Pattern analysis: which issues recurred across rounds?
   - Root cause hypothesis: is this a design-level flaw, not an implementation bug?
   - Suggested design revision or alternative approach
3. ESCALATE with this analysis attached, not a bare "fix failed 3 times"

**Trigger**: fix round 3 verdict is still FIX_REQUIRED.

### 1.3 Compaction Recovery Enhancement

Current: `post-compact-resume.sh` injects state.json path.

**Enhancement**: Inject a **full recovery context bundle**:

- `state.json` — current phase and progress
- **Phase-specific key artifact**:
  - DESIGN: `design.md` summary (first 200 lines)
  - REVIEW: `review.json` verdict + key findings
  - IMPLEMENT: `plan.json` + current step index + last commit hash
  - CODE_REVIEW: `code-review.json` + `bddResults` summary
- **Phase-specific resume instruction**: each phase has an explicit "after compaction, resume from here" instruction, not a generic "read state.json"

**Implementation**: `post-compact-resume.sh` reads `state.json.currentPhase` and selects the appropriate artifact bundle.

### 1.4 Subagent Timeout Protection

- Parent records `startTime` to `state.json` when dispatching each subagent
- `health-check.sh` enhancement: detect >15 minutes with no artifact write → macOS notification + telemetry entry
- **No auto-kill** — subagent may be doing large implementation. Provide diagnostic info:
  - Last artifact written and when
  - Current phase and elapsed time
  - Suggested action: "Check if subagent is stuck or doing large work"

---

## §2 Review Quality Enhancement

### 2.1 Two-Stage Review

Split code-review into two independent evaluation dimensions with **fixed ordering**:

```
Stage 1: SPEC_COMPLIANCE (must pass before Stage 2 matters)
  ├── REQUIREMENTS_COVERAGE: every AC implemented?
  ├── PLAN_COVERAGE: every plan step completed?
  └── BDD_VERIFICATION: every BDD scenario passed? (§4)

Stage 2: CODE_QUALITY (only meaningful if Stage 1 passes)
  ├── Correctness (0-10)
  ├── Convention (0-10)
  ├── Regression (0-10)
  └── Performance (0-10)
```

**Script enforcement**: `validate-code-review.sh` — REQUIREMENTS_COVERAGE < 100% AND verdict APPROVE → `exit 2`.

### 2.2 Anti-Rationalization Tables

Injected into code-reviewer and design-reviewer prompts:

| Rationalization | Rebuttal |
|----------------|----------|
| "This difference is minor, won't affect functionality" | Minor differences accumulate into major deviations. If it exists, document it. |
| "Should be fine" / "Looks correct" | No verification run = no evidence = cannot pass |
| "Tests are too hard to write for this" | If the behavior is worth implementing, it's worth verifying |
| "This is a framework limitation" | Verify it's actually a limitation, not an unfound correct usage |
| "The original code did it this way too" | Original code is not the acceptance standard — the spec is |
| "It works in my testing" | Ad-hoc testing is not structured verification. Run the BDD scenarios. |
| "This edge case won't happen in production" | If it can't happen, the test is free. If it can, you need it. |

### 2.3 Verification Iron Law

> **Any "completion" claim must be accompanied by verification evidence.**

Implementation per subagent:

- **implementer**: each step's artifact must include `verificationEvidence` field:
  - TESTABLE steps: test command output (pass/fail count)
  - VERIFY_ONLY steps: build command output (success/failure)
  - scaffold steps: file existence check output
- **code-reviewer**: APPROVE verdict must include `testRunOutput` field (last test run summary)
- **design-reviewer**: APPROVE verdict must reference each AC's design coverage point

**Script enforcement**: `validate-code-review.sh` — APPROVE + empty `testRunOutput` → `exit 2`.

### 2.4 Grounding Enhancement (Anti-Hallucination)

Extends v1.6.0's design-reviewer `groundingCheck` to implementer:

- **Prompt-level constraint**: implementer must Grep/Glob/LSP-verify any API/component/method exists before using it
- **plan.json enhancement**: each step gains `apiRefs` field — lists key APIs the step expects to use
- Implementer verifies `apiRefs` existence at step start; missing API → `NEEDS_CONTEXT` status

This is primarily a **prompt-level constraint** because API usage is dynamic and cannot be fully enumerated ahead of time.

**Script-enforced complement**: After implementation completes, `validate-code-review.sh` checks that for each `apiRefs` entry in plan.json, the code-reviewer has verified the API exists (grep confirmation in `code-review.json.groundingChecks`). Missing check → warning (not block, since implementer may have legitimately used a different API).

---

## §3 Figma→Code Visual Verification

### Priority Position

Visual verification is **subordinate** to functional verification. The canonical CODE_REVIEW state machine is defined once in §2.1 (two stages: SPEC_COMPLIANCE → CODE_QUALITY). This section does NOT add stages — it defines the separate VISUAL_CHECK phase:

```
CODE_REVIEW phase (§2.1 — authoritative definition):
  Stage 1: SPEC_COMPLIANCE (requirements + plan + BDD)
  Stage 2: CODE_QUALITY (rubric scores)
  → Both must pass for CODE_REVIEW to pass

VISUAL_CHECK phase (separate phase, runs only after CODE_REVIEW passes + UI changes):
  Visual review against Figma
  → Failure → fix round (UI-only) OR backtrack to IMPLEMENT if root cause is logic
```

**Script enforcement**: `agent-dev-gate.sh` — entering VISUAL_CHECK validates code-review.json verdict is APPROVE. Not passed → `exit 2`.

**Backtrack path**: If VISUAL_CHECK implementer reports `BLOCKED` (root cause is functional logic, not styling), pipeline backtracks to IMPLEMENT phase with the visual finding as context, then re-runs CODE_REVIEW. Max 1 backtrack before ESCALATE.

### 3.1 V1: LLM Visual Review (This Release)

Code-reviewer receives two screenshots for structured comparison:

**Input**:
- Figma screenshot (parent pre-fetches via Figma MCP `get_screenshot`)
- Rendered screenshot (web: Chrome DevTools `take_screenshot` / iOS: Xcode simulator)

**Output** — `visual-review.json`:
```json
{
  "verdict": "MATCH | MINOR_DEVIATION | MAJOR_DEVIATION | INTERACTION_FAILURE",
  "overallScore": 0-100,
  "dimensions": {
    "layout":     { "score": 0-10, "findings": [] },
    "spacing":    { "score": 0-10, "findings": [] },
    "color":      { "score": 0-10, "findings": [] },
    "typography": { "score": 0-10, "findings": [] },
    "components": { "score": 0-10, "findings": [] }
  },
  "screenshotPaths": { "figma": "...", "rendered": "..." },
  "comparisonNotes": "..."
}
```

**Verdict mapping**:

| overallScore | Verdict | Pipeline Behavior |
|---|---|---|
| ≥ 80 | MATCH | Pass, proceed to PR |
| 60-79 | MINOR_DEVIATION | Pass, but PR description notes deviations for human review |
| < 60 | MAJOR_DEVIATION | Trigger fix round — implementer receives findings, fixes UI only |

**Script enforcement**: `validate-visual-review.sh` — verdict MATCH but any dimension < 5 → `exit 2` (scoring inconsistency).

### 3.2 Trigger Conditions (Expanded)

**Trigger** (any one satisfied):
1. `plan.json` has `uiChange: true`
2. Changed files include `.vue` / `.scss` / `.css` / `.swift`(UI) / `.xml`(layout)
3. Figma URL exists in requirement
4. Tech design explicitly marks UI changes

**Skip** (with explicit reason recorded):
- Pure backend/logic change + `uiChange: false` → `SKIPPED_NO_UI`
- No Figma design available → `SKIPPED_NO_FIGMA`
- Cannot start rendering environment → `SKIPPED_NO_RENDERER`

### 3.3 Interactive Visual Verification (Advisory in V1)

> **V1 scope**: Interactive visual verification is **advisory** (reported but not blocking). It becomes a hard gate in a future release once BDD Track B reliability is validated.

Visual scenarios are **parasitic on BDD scenarios** — they reuse the BDD interaction path and add screenshot checkpoints:

```json
// plan.json
"visualCheckpoints": [
  {
    "afterBddStep": "AC-2.Then.1",
    "figmaNodeId": "123:456",
    "description": "Search results list"
  },
  {
    "afterBddStep": "AC-2.Then.2",
    "figmaNodeId": "123:789",
    "description": "Result card detail"
  }
]
```

**Execution during VISUAL_CHECK**:
1. Code-reviewer replays the BDD scenario interaction steps via MCP
2. At each `checkpoint`, takes a screenshot
3. Compares against the Figma node screenshot
4. Each checkpoint scored independently
5. `overallScore` = minimum across all checkpoints (weakest-link)

**INTERACTION_FAILURE** takes priority — if the interaction can't reach a state, visual comparison is meaningless.

**V1 advisory behavior**: Interactive checkpoint results are included in `visual-review.json` but only the **single static screenshot comparison** (§3.1) drives the verdict. Interactive checkpoints are logged for data collection and future gating.

### 3.4 Visual Fix Scope Constraint

Visual fix rounds are restricted to UI-only changes. Implementer prompt injection:

> "This fix round is for UI styling only (CSS/layout/style attributes). If the visual deviation's root cause is a functional logic issue, report BLOCKED with explanation."

**Visual fix → code review interaction**: Visual fix rounds only re-run VISUAL_CHECK, NOT full CODE_REVIEW. If the visual fix changes >50 lines of code, ESCALATE instead of re-running (large changes risk regressions that need full review). Max 2 visual fix rounds before ESCALATE.

### 3.5 V2 Roadmap (Not This Release)

- **Structural comparison**: Figma node tree vs DOM tree hierarchy matching
- **Design token comparison**: Figma variables vs CSS variables value matching
- **Pixel-level diff**: pixelmatch as supplementary metric (not decision driver)

---

## §4 BDD Behavioral Verification

### 4.1 Gherkin as Behavioral Contract

PLAN phase generates `.pilot/scenarios.feature` from ACs as the sole behavioral acceptance standard:

```gherkin
# .pilot/scenarios.feature
# Auto-generated from requirement ACs — DO NOT manually edit

Feature: Property Save Function

  Background:
    Given user is logged in as "test@example.com"

  @AC-1
  Scenario: Save a property
    Given user is on property detail page "/property/123"
    When user clicks "Save" button
    Then success toast "Saved" is displayed
    And "Save" button changes to "Saved" state

  @AC-2
  Scenario: Unsave a property
    Given user has saved property "123"
    And user is on property detail page "/property/123"
    When user clicks "Saved" button
    Then confirmation dialog "Confirm unsave?" is displayed
    When user clicks "Confirm"
    Then "Saved" button reverts to "Save" state

  @AC-3
  Scenario: Unauthenticated user saves
    Given user is not logged in
    And user is on property detail page "/property/123"
    When user clicks "Save" button
    Then user is redirected to login page
```

**Generation rules**:
- Each **behavioral** AC → at least one Scenario (mandatory)
- Each **non-behavioral** AC (e.g., "code follows conventions", "performance < 200ms") → no scenario required, tagged `@non-behavioral` in plan.json
- Cover happy path + key error paths (unauthenticated, empty data, network error)
- Language matches AC source (Chinese or English)
- `@AC-N` tags establish scenario→AC traceability
- Gherkin quality: every `Then` step must contain a concrete assertion (element text, URL, state change), not vague descriptions like "the feature works correctly"

**AC classification**: PLAN phase classifies each AC as `behavioral` or `non-behavioral`. Script enforcement: behavioral AC without corresponding `@AC-N` scenario → `exit 2`. Non-behavioral AC without scenario → allowed (warning only).

### 4.2 Dual-Track Execution

Gherkin scenarios execute on two tracks, routed by step type:

**Track A — Unit/Integration Tests (existing TDD flow)**
- Scope: business logic, data processing, API calls, state management
- Execution: implementer writes tests → code-reviewer runs via bash
- Verification: test pass = scenario's Then assertion holds

**Track B — LLM-as-BDD-Runner (new, ADVISORY in V1)**
- Scope: UI interaction, page navigation, form submission, visual feedback
- Execution: code-reviewer interprets Gherkin step-by-step via MCP tools
- **V1: advisory only** — Track B results are reported but do NOT block APPROVE. Only Track A is a hard gate. Track B becomes blocking after a validation spike confirms >80% consistency (see §4.8).
- Mapping:
  - `Given user is on "/path"` → `navigate_page(url)`
  - `When user clicks "X"` → `click(selector)` / Xcode tap
  - `When user enters "Y" into "Z"` → `fill(selector, value)`
  - `Then "X" is displayed` → `evaluate_script` / `wait_for`
  - `Then user is redirected to "/path"` → `evaluate_script(location.href)`

**PLAN phase determines routing** — plan.json tags each scenario:

```json
"bddScenarios": [
  {
    "id": "AC-1",
    "track": "mcp",
    "preconditions": {
      "devServer": true,
      "testData": "logged-in user with no saved properties",
      "loginRequired": true
    }
  },
  {
    "id": "AC-3",
    "track": "hybrid",
    "preconditions": {
      "devServer": true,
      "testData": "no active session",
      "loginRequired": false
    }
  }
]
```

Track values: `"mcp"` (interactive only — advisory in V1), `"test"` (unit/integration only — blocking), `"hybrid"` (both — Track A must pass for blocking verdict; Track B is advisory in V1).

### 4.3 BDD Verification in Code Review

BDD verification is embedded in Stage 1 (SPEC_COMPLIANCE) of the two-stage review (§2.1):

```
Stage 1: SPEC_COMPLIANCE
  ├── REQUIREMENTS_COVERAGE
  ├── PLAN_COVERAGE
  └── BDD_VERIFICATION (new):
      ├── Run Track A tests (bash)
      ├── Execute Track B scenarios (MCP)
      └── Report per-scenario PASS/FAIL
```

**code-review.json addition**:
```json
{
  "bddResults": {
    "total": 3,
    "passed": 2,
    "failed": 1,
    "skipped": 0,
    "scenarios": [
      {
        "id": "AC-1",
        "trackResults": {
          "test": { "verdict": "PASS" },
          "mcp": { "verdict": "PASS", "advisory": true }
        },
        "blockingVerdict": "PASS"
      },
      {
        "id": "AC-2",
        "trackResults": {
          "mcp": { "verdict": "PASS", "advisory": true }
        },
        "blockingVerdict": "PASS"
      },
      {
        "id": "AC-3",
        "trackResults": {
          "test": { "verdict": "PASS" },
          "mcp": {
            "verdict": "FAIL",
            "advisory": true,
            "failedStep": "Then user is redirected to login page",
            "actual": "Error toast displayed instead of redirect",
            "screenshot": ".pilot/screenshots/AC-3-fail.png"
          }
        },
        "blockingVerdict": "PASS"
      }
    ]
  }
}
```

**Verdict logic**: `blockingVerdict` is computed from non-advisory tracks only. In V1, only Track A (`"test"`) is non-advisory. A scenario with only `"mcp"` track results has `blockingVerdict: "PASS"` by default (advisory cannot block). This schema supports future promotion of Track B to blocking by flipping `advisory: false`.

### 4.4 Script Enforcement

`validate-code-review.sh` additions:
- Verdict APPROVE but `bddResults` has any scenario with `blockingVerdict: "FAIL"` → `exit 2`
- `bddResults` field missing AND plan.json has `bddScenarios` → `exit 2` (cannot skip BDD)
- Advisory Track B failures are logged but do NOT trigger `exit 2` in V1
- If >50% of scenarios have `blockingVerdict: "SKIPPED"` (any reason) → `exit 2` (prevents silent bypass of entire BDD system)

### 4.5 BDD Failure Fix Flow

BDD scenario failure → fix round. Implementer receives:
- Full text of failed scenario
- Specific failed step + actual behavior observed
- Screenshot (if available)
- Constraint: **"Fix functional behavior to make scenario pass. Do NOT modify the scenario."**

**Scenario regeneration escape hatch**: If 3 consecutive fix rounds fail AND the implementer reports that the scenario itself is incorrect (e.g., AC was misinterpreted during Gherkin generation), the parent may regenerate `scenarios.feature` for the specific failing AC. Regeneration requires: (1) implementer explicitly states the scenario is wrong with evidence, (2) parent re-reads the original AC, (3) generates a corrected scenario. Max 1 regeneration per AC per pipeline run.

### 4.6 Precondition Management

Interactive BDD requires environment preparation. PLAN phase `preconditions` field guides code-reviewer:

- `devServer: true` → verify dev server is reachable before running scenarios
- `loginRequired: true` → execute login flow via MCP (test credentials from project config)
- `testData` → describes required data state (code-reviewer judges if seeding is needed)

**Precondition failure handling** (not all skips are equal):
- `devServer` unreachable → all MCP-track scenarios marked `SKIPPED_MCP_UNAVAILABLE` (infrastructure failure, distinct from precondition)
- `loginRequired` login flow fails → that scenario marked `FAIL` (not SKIPPED — login is part of the test)
- `testData` cannot be satisfied → scenario marked `SKIPPED_PRECONDITION` with reason

**Skip thresholds**: If >50% of scenarios are SKIPPED (any reason), the BDD gate does NOT auto-pass. Instead → `exit 2` with message requiring human acknowledgment or infrastructure fix.

### 4.8 BDD Spike Requirement (Phase 2 Pre-Gate)

Before committing to Phase 2 implementation, run a **time-boxed validation spike** (1-2 days):

1. Manually write 5 Gherkin scenarios for an existing HouseSigma feature
2. Have the code-reviewer LLM execute them via Chrome DevTools MCP
3. Measure across 3 runs of each scenario:
   - Pass/fail consistency (target: >80%)
   - Time per scenario
   - False positive and false negative rates

**Decision gate**:
- Consistency ≥80% → proceed with Track B as advisory, plan promotion to blocking
- Consistency 50-79% → proceed with Track B as advisory only, defer blocking promotion
- Consistency <50% → defer Track B entirely, rely on Track A + manual QA checklist

### 4.9 Medium-Term Roadmap (Not This Release)

- **playwright-bdd integration**: web projects can optionally have implementer generate `.feature` + step definitions as persistent regression tests (enters CI, not just pipeline verification)
- **XCUITest BDD**: iOS projects translate Gherkin scenarios to XCUITest methods, executed via Xcode MCP

---

## §5 Plan/Spec Multi-Dimension Reference

### 5.1 Multi-Dimension Reference Framework

Tech-designer must collect references from these dimensions during DESIGN phase, documented in `design.md`:

| Dimension | Source | Purpose |
|-----------|--------|---------|
| **Existing Patterns** | Grep/Glob for similar features | Implementer follows existing patterns instead of inventing new ones |
| **API Contracts** | Type definitions / OpenAPI spec / existing call sites | Prevent hallucinating non-existent APIs (§2.4) |
| **Test Patterns** | Existing test files, framework usage | Implementer writes style-consistent tests |
| **Figma Nodes** | Figma URL nodeIds from requirement | VISUAL_CHECK uses precise comparison frames |
| **Convention Files** | `.claude/rules/*.md`, `.claude/steering/*.md` | Injected into implementer/code-reviewer prompts |
| **Dependency Map** | Module upstream/downstream dependencies | Assess regression risk, guide test scope |

**Output format** (new section in design.md):

```markdown
## Reference Dimensions

### Existing Patterns
- Similar feature: `src/components/PropertyCard.vue` (list card pattern)
- State management: `src/stores/useSearchStore.ts` (Pinia store pattern)

### API Contracts
- GET /api/v2/property/:id → PropertyDetail (types/api.d.ts:42)
- POST /api/v2/favorites → { success: boolean } (types/api.d.ts:87)

### Test Patterns
- Component tests: vitest + @vue/test-utils (see tests/components/*.spec.ts)
- API mocking: msw (see tests/mocks/handlers.ts)

### Figma Nodes
- Property detail page: node-id=123:456
- Save button states: node-id=123:789, 123:790 (default, saved)

### Dependency Map
- PropertyDetail.vue → usePropertyStore → /api/v2/property
- FavoriteButton.vue → useFavoriteStore → /api/v2/favorites
```

### 5.2 No Placeholders Rule

**Script enforcement** — `validate-plan.sh` additions:
- Step `description` contains TBD / TODO / "待定" / "后续补充" / "implement later" / "add appropriate" → `exit 2`
- Step `files` is empty array → `exit 2` (every step must know which files it changes)
- Existing `acRefs` empty check preserved

### 5.3 Execution Posture

Each plan.json step gains a `posture` field:

| Posture | Meaning | Implementer Behavior |
|---------|---------|---------------------|
| `test-first` | Write test before implementation (existing TESTABLE) | RED → GREEN → commit |
| `build-verify` | Write code then verify build passes (existing VERIFY_ONLY) | implement → build → commit |
| `characterization-first` | Write tests describing current behavior, then modify | Lock behavior with tests → modify → verify only intended changes |
| `scaffold` | Infrastructure setup, no business logic | Create files/dirs/config → build verify |

`characterization-first` is new — for bugfix and refactoring scenarios. Write tests to lock current behavior first, then modify implementation, ensuring only intended behavior changes.

**characterization-first expected-change rule**: Steps with this posture must explicitly list which characterization tests are **expected to change** (because we are intentionally fixing the behavior they describe). Only those specific tests may break after implementation. Any other characterization test breaking = unintended regression = fail.

### 5.4 Plan ↔ BDD Cross-Reference

plan.json and `scenarios.feature` are linked via `acRefs`:

```
plan step → acRefs → AC → @AC-N tag → Gherkin scenario
```

PLAN phase generates both simultaneously. `validate-plan.sh` cross-check:
- Behavioral AC (per §4.1 classification) without corresponding `@AC-N` in scenarios.feature → `exit 2` (block)
- Non-behavioral AC without scenario → warning only

---

## §6 Universality & Cross-Project Adaptation

### 6.1 Framework-Agnostic Command Discovery

Three-level discovery protocol:

```
Level 1: CLAUDE.md explicit declaration (highest priority)
  → buildCommand, testCommand, lintCommand, devServerCommand
  → If present, use directly — no further probing

Level 2: Project config file probing (when CLAUDE.md is missing)
  → package.json scripts → npm test / npm run lint / npm run build
  → Makefile → make test / make lint / make build
  → Gradle → ./gradlew test / ./gradlew lint
  → xcodebuild → infer from .xcodeproj / .xcworkspace
  → composer.json → composer test
  → Probing results written to plan.json, project files not modified

Level 3: Fallback (no config files)
  → Mark as UNKNOWN, implementer discovers in first step
  → Code-reviewer uses implementer-discovered commands
```

### 6.2 Generalized testInfra

Replace hardcoded framework names with structured probe results:

```json
"testInfra": {
  "framework": "vitest",
  "runCommand": "npx vitest run",
  "watchCommand": "npx vitest",
  "configFile": "vitest.config.ts",
  "testPattern": "**/*.spec.ts",
  "coverageCommand": null,
  "detected": true
}
```

Implementer and code-reviewer use `runCommand` instead of hardcoded framework invocations. New frameworks (Jest, Mocha, pytest, RSpec) require zero pipeline code changes.

### 6.3 AI-Friendly Error Messages

All hook scripts adopt structured error output:

```
[BLOCKED] <short reason>
WHY: <which rule was violated>
FIX: <specific fix guidance>
CONTEXT: <relevant file path or field name>
```

Example transformation:

```bash
# Before
echo "ERROR: acRefs empty for non-scaffolding step"

# After
echo "[BLOCKED] plan.json step 3 missing acRefs"
echo "WHY: Non-scaffolding steps must trace to at least one AC (requirement traceability)"
echo "FIX: Add acRefs array with AC identifiers, e.g. [\"AC-1\", \"AC-2\"]"
echo "CONTEXT: .pilot/plan.json → steps[3].acRefs"
```

The agent sees the FIX line and can directly execute the repair without deep error analysis.

### 6.4 Project Onboarding Simplification

New project onboarding: after FETCH, run a **project capability scan**:

```json
// .pilot/project-capabilities.json
{
  "stack": "vue3-typescript",
  "buildSystem": "vite",
  "testInfra": { },
  "hasDevServer": true,
  "devServerCommand": "npm run dev",
  "hasFigmaDesigns": true,
  "hasExistingTests": true,
  "conventionFiles": [
    ".claude/rules/coding-style.md",
    ".claude/steering/architecture.md"
  ],
  "qaCapabilities": {
    "web": { "chromeDevTools": true, "devServer": true },
    "ios": { "xcodeMcp": false, "simulator": false }
  }
}
```

All subsequent phases read this file — no redundant probing. One scan, full pipeline reuse.

### 6.5 Reduce HouseSigma Hardcoding

Audit and migrate HouseSigma-specific references to project-capabilities:

| Current Hardcoding | Migration |
|---|---|
| `~/housesigma/` path references | Read from CWD or state.json |
| Vue 3 / Pinia test patterns | Read from testInfra probe results |
| `web-hybrid` / `housesigma-ios-native` project names | Infer from git remote or directory name |
| ESLint / Volar specific config | Read from conventionFiles |

**Goal**: Any project with a CLAUDE.md can install pilot and run the pipeline without modifying pilot source code.

---

## Priority Chain & Phase Ordering

```
Functional Correctness (BDD) → Code Quality (Rubric) → Visual Match (Figma)
     must pass                    must pass              pass or note deviations
```

Updated pipeline phase detail:

```
FETCH → RESOLVE → [DESIGN → REVIEW →] PLAN → IMPLEMENT → CODE_REVIEW → [VISUAL_CHECK →] PR

CODE_REVIEW internals (canonical definition, §2.1):
  Stage 1: SPEC_COMPLIANCE
    ├── REQUIREMENTS_COVERAGE (every AC implemented?)
    ├── PLAN_COVERAGE (every plan step completed?)
    ├── BDD_VERIFICATION (§4, Track A = blocking, Track B = advisory in V1)
    └── CONCERNS_RESOLUTION (if concerns.json exists)
  Stage 2: CODE_QUALITY
    ├── Correctness / Convention / Regression / Performance (rubric)
    └── Verification Iron Law check (testRunOutput required)

VISUAL_CHECK internals (separate phase, only if CODE_REVIEW passes + UI changes):
  ├── Static screenshot comparison against Figma (§3.1, blocking)
  ├── Interactive checkpoint screenshots (§3.3, advisory in V1)
  └── If BLOCKED with logic root cause → backtrack to IMPLEMENT (max 1)
```

---

## Implementation Phases

### Phase 1: Foundation (Fault Tolerance + Review Hardening + Infrastructure)
- §1.1 Four-status subagent reporting protocol (with enum validation, NEEDS_CONTEXT cap, concerns injection)
- §1.2 Three-fix architectural escape hatch
- §1.3 Compaction recovery enhancement
- §1.4 Subagent timeout protection
- §2.1 Two-stage review (spec compliance → code quality)
- §2.2 Anti-rationalization tables
- §2.3 Verification iron law
- §5.2 No placeholders rule
- §6.1 Framework-agnostic command discovery
- §6.2 Generalized testInfra
- §6.3 AI-friendly error messages
- §6.4 Project onboarding simplification (project-capabilities.json)

**Why first**: These are prompt + script changes to existing agents, plus the infrastructure that BDD (Phase 2) depends on. Compaction recovery and timeout protection must exist before adding BDD's longer-running MCP sessions. Command discovery and testInfra must exist before BDD can route scenarios to the correct test runner.

### Phase 1.5: BDD Validation Spike (§4.8)
- Write 5 Gherkin scenarios for an existing feature
- Execute via Chrome DevTools MCP, measure consistency across 3 runs
- Decision gate: proceed with Track B advisory / defer Track B / adjust approach

**Why before Phase 2**: Gates the BDD investment. If LLM-as-BDD-Runner consistency is <50%, Phase 2 scope shrinks significantly (Track A only).

### Phase 2: BDD Behavioral Verification
- §4.1 Gherkin generation in PLAN phase (with AC classification)
- §4.2 Dual-track execution (Track A blocking, Track B advisory)
- §4.3 BDD verification in code-review
- §4.4 Script enforcement for BDD results (with skip threshold)
- §4.5 BDD failure fix flow (with scenario regeneration escape hatch)
- §4.6 Precondition management (with failure distinction and skip thresholds)
- §5.3 Execution posture (with characterization-first expected-change rule)
- §5.4 Plan ↔ BDD cross-reference (behavioral AC = block, non-behavioral = warning)
- §2.4 Grounding enhancement

**Why second**: BDD is the core behavioral verification layer. Depends on Phase 1's two-stage review structure and infrastructure.

### Phase 3: Visual Verification + Universality
- §3.1 LLM visual review (V1, static screenshot comparison)
- §3.2 Trigger condition expansion
- §3.3 Interactive visual verification (advisory, parasitic on BDD)
- §3.4 Visual fix scope constraint (with backtrack path and loop prevention)
- §5.1 Multi-dimension reference framework
- §6.5 Reduce HouseSigma hardcoding

**Why third**: Visual verification depends on BDD interaction paths (§3.3). §6.5 is an audit pass that benefits from all other changes being in place.

---

## Future Roadmap (Not This Release)

- **§3.5**: Structural comparison (Figma node tree vs DOM tree), design token matching, pixel-level diff
- **§4.7**: playwright-bdd persistent regression tests, XCUITest BDD for iOS
- **Multi-persona review**: Dynamic reviewer selection per diff (security, performance, API-contract specialists) — inspired by compound-engineering
- **Knowledge compounding**: `.pilot/solutions/` with overlap-aware deduplication — inspired by compound-engineering
- **Review mode contracts**: interactive/autofix/report-only/headless modes for code-reviewer — inspired by compound-engineering
- **SKILL.md template system**: Generate skills from templates to prevent doc/code drift — inspired by gstack
- **Scratch space convention**: `.context/pilot/<workflow>/` for ephemeral collaboration artifacts — inspired by compound-engineering

---

## Reference Sources

| Source | Key Patterns Adopted |
|--------|---------------------|
| [superpowers](https://github.com/obra/superpowers) | Verification iron law, systematic debugging, 3-fix escape hatch, four implementer statuses, anti-rationalization tables, no-placeholders rule, two-stage review |
| [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) | Multi-dimension reference, execution posture signals, action routing concepts |
| [gstack](https://github.com/garrytan/gstack) | AI-friendly error messages, crash-then-recover philosophy, framework-agnostic command discovery |
| BDD research | LLM-as-BDD-Runner approach, playwright-bdd for medium-term, Gherkin as behavioral contract |
