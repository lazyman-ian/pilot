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

**Enforcement**: `validate-artifacts.sh` checks subagent output for `status` field. Missing → `exit 2`.

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

This is a **prompt-level constraint**, not script-enforced, because API usage is dynamic and cannot be fully enumerated ahead of time.

---

## §3 Figma→Code Visual Verification

### Priority Position

Visual verification is **subordinate** to functional verification:

```
CODE_REVIEW phase:
  Stage 1: SPEC_COMPLIANCE (§2.1)
  Stage 2: CODE_QUALITY (§2.1)
  Stage 3: BDD_VERIFICATION (§4) ← functional acceptance, must pass first
    └─ Failure → fix round, no visual check

VISUAL_CHECK phase (only after CODE_REVIEW fully passes):
  Stage 4: VISUAL_REVIEW (§3) ← visual acceptance, BDD must pass first
    └─ Failure → fix round, UI-only fixes (no logic changes)
```

**Script enforcement**: `agent-dev-gate.sh` — entering VISUAL_CHECK validates code-review.json BDD pass status. Not passed → `exit 2`.

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

### 3.3 Interactive Visual Verification

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

### 3.4 Visual Fix Scope Constraint

Visual fix rounds are restricted to UI-only changes. Implementer prompt injection:

> "This fix round is for UI styling only (CSS/layout/style attributes). If the visual deviation's root cause is a functional logic issue, report BLOCKED with explanation."

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
- Each AC → at least one Scenario
- Cover happy path + key error paths (unauthenticated, empty data, network error)
- Language matches AC source (Chinese or English)
- `@AC-N` tags establish scenario→AC traceability

### 4.2 Dual-Track Execution

Gherkin scenarios execute on two tracks, routed by step type:

**Track A — Unit/Integration Tests (existing TDD flow)**
- Scope: business logic, data processing, API calls, state management
- Execution: implementer writes tests → code-reviewer runs via bash
- Verification: test pass = scenario's Then assertion holds

**Track B — LLM-as-BDD-Runner (new)**
- Scope: UI interaction, page navigation, form submission, visual feedback
- Execution: code-reviewer interprets Gherkin step-by-step via MCP tools
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

Track values: `"mcp"` (interactive only), `"test"` (unit/integration only), `"hybrid"` (both — scenario must pass on BOTH tracks to be considered PASS; either track failing = scenario FAIL).

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
    "scenarios": [
      { "id": "AC-1", "track": "mcp", "verdict": "PASS" },
      { "id": "AC-2", "track": "mcp", "verdict": "PASS" },
      {
        "id": "AC-3",
        "track": "mcp",
        "verdict": "FAIL",
        "failedStep": "Then user is redirected to login page",
        "actual": "Error toast displayed instead of redirect",
        "screenshot": ".pilot/screenshots/AC-3-fail.png"
      }
    ]
  }
}
```

### 4.4 Script Enforcement

`validate-code-review.sh` additions:
- Verdict APPROVE but `bddResults` has any failed scenario → `exit 2`
- `bddResults` field missing AND plan.json has `bddScenarios` → `exit 2` (cannot skip BDD)

### 4.5 BDD Failure Fix Flow

BDD scenario failure → fix round. Implementer receives:
- Full text of failed scenario
- Specific failed step + actual behavior observed
- Screenshot (if available)
- Constraint: **"Fix functional behavior to make scenario pass. Do NOT modify the scenario."**

### 4.6 Precondition Management

Interactive BDD requires environment preparation. PLAN phase `preconditions` field guides code-reviewer:

- `devServer: true` → verify dev server is reachable before running scenarios
- `loginRequired: true` → execute login flow via MCP (test credentials from project config)
- `testData` → describes required data state (code-reviewer judges if seeding is needed)

Unmet precondition → scenario marked `SKIPPED_PRECONDITION`, does not affect verdict but reason is recorded.

### 4.7 Medium-Term Roadmap (Not This Release)

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

### 5.4 Plan ↔ BDD Cross-Reference

plan.json and `scenarios.feature` are linked via `acRefs`:

```
plan step → acRefs → AC → @AC-N tag → Gherkin scenario
```

PLAN phase generates both simultaneously. `validate-plan.sh` cross-check: plan has acRef but `scenarios.feature` lacks corresponding `@AC-N` → warning (not block — some ACs are non-behavioral, e.g., "code follows conventions").

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

CODE_REVIEW internals:
  Stage 1: SPEC_COMPLIANCE
    ├── REQUIREMENTS_COVERAGE
    ├── PLAN_COVERAGE
    └── BDD_VERIFICATION (§4)
  Stage 2: CODE_QUALITY
    ├── Correctness / Convention / Regression / Performance (rubric)
    └── Verification Iron Law check

VISUAL_CHECK internals (only if CODE_REVIEW passes + UI changes):
  ├── Replay BDD interaction steps via MCP
  ├── Screenshot at visual checkpoints
  └── Compare against Figma node screenshots
```

---

## Implementation Phases

### Phase 1: Foundation (Fault Tolerance + Review Hardening)
- §1.1 Four-status subagent reporting protocol
- §1.2 Three-fix architectural escape hatch
- §2.1 Two-stage review (spec compliance → code quality)
- §2.2 Anti-rationalization tables
- §2.3 Verification iron law
- §5.2 No placeholders rule
- §6.3 AI-friendly error messages

**Why first**: These are prompt + script changes to existing agents. Low risk, immediately improve quality.

### Phase 2: BDD Behavioral Verification
- §4.1 Gherkin generation in PLAN phase
- §4.2 Dual-track execution (test + MCP)
- §4.3 BDD verification in code-review
- §4.4 Script enforcement for BDD results
- §4.5 BDD failure fix flow
- §4.6 Precondition management
- §5.3 Execution posture
- §5.4 Plan ↔ BDD cross-reference

**Why second**: BDD is the core behavioral verification layer. Depends on Phase 1's two-stage review structure.

### Phase 3: Visual Verification + Universality
- §3.1 LLM visual review (V1)
- §3.2 Trigger condition expansion
- §3.3 Interactive visual verification (parasitic on BDD)
- §3.4 Visual fix scope constraint
- §1.3 Compaction recovery enhancement
- §1.4 Subagent timeout protection
- §5.1 Multi-dimension reference framework
- §6.1 Framework-agnostic command discovery
- §6.2 Generalized testInfra
- §6.4 Project onboarding simplification
- §6.5 Reduce HouseSigma hardcoding
- §2.4 Grounding enhancement

**Why third**: Visual verification depends on BDD interaction paths (§3.3). Universality items are independent but lower priority than correctness.

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
