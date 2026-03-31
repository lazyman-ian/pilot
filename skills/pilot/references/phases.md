# Phase Instructions

Read the section matching your current phase from state.json.
After compaction, re-read this file and state.json to resume.

**state.json update rule**: When writing state.json after initial FETCH creation, always preserve `sessionId`, `pipelineId`, `pluginScriptsDir`, and `pluginVersion` from the current file. You already read state.json at phase start — carry those values forward. Never overwrite them with `null`.

## Compact Instructions

When compacting, preserve in priority order:
1. Current phase + projectDir + branch (from state.json)
2. plan.json step statuses (which steps passed/failed/pending)
3. Recent subagent verdicts (APPROVE/FIX_REQUIRED/REVISE)

Safe to discard:
- Notion/Figma MCP tool call results from FETCH phase
- Raw subagent output text (already persisted to .pilot/ files on disk)
- File contents read during PLAN/RESOLVE (re-readable from disk)
- Completed phase artifacts content (on disk: tech-design.md, review.json, etc.)

ALL `.pilot/` artifacts live in CWD. This is typically the target project directory.
Recommended: run `/pilot` from inside the target project (e.g., `cd web-hybrid && claude`).
This way, the project's .claude/ hooks, rules, skills, and steering docs are automatically loaded.

If CWD is a monorepo root with multiple sub-projects:
- RESOLVE will detect the target sub-project directory
- projectDir = `<CWD>/<sub-project>` — code operations use absolute paths
- `.pilot/` stays in CWD (monorepo root)

### Compaction Recovery Instructions (§1.3)

Each phase has specific resume instructions (used by `post-compact-resume.sh`):

| Phase | Key Artifact | Resume Instruction |
|-------|-------------|-------------------|
| DESIGN | design.md | Re-read design.md, continue from where design left off. Do NOT restart. |
| REVIEW | review.json | Read review verdict. If REVISE, prepare next design iteration. If APPROVE, proceed to PLAN. |
| IMPLEMENT | plan.json + step index | Read plan.json, check STEP_STATUSES, resume from first incomplete step. Reconstruct anchor set via `git diff --name-only $(git merge-base origin/<baseBranch> HEAD)..HEAD`. |
| CODE_REVIEW | code-review.json | Read verdict + reviewIteration. If FIX_REQUIRED, invoke implementer fix mode. |
| VISUAL_CHECK | visual-review.json | Read verdict. If MAJOR_DEVIATION, invoke implementer UI fix mode. |

**Priority on compaction**: Preserve (1) state.json, (2) current phase key artifact, (3) plan.json step statuses. Everything else can be re-read from `.pilot/` directory.

## Telemetry

Every pipeline run (COMPLETED or FAILED) writes a row to `~/.pilot-telemetry.tsv`.
- **Score formula** (0-100): completion(40) + low-interventions(30) + design-first-pass(15) + code-review-first-pass(15)
- **metrics.interventions**: increment whenever the pipeline stops to ask the user (ESCALATED, unrecoverable error)
- Written by: `bash "$(jq -r .pluginScriptsDir state.json)/write-telemetry.sh" "$PWD/.pilot/state.json" "$(jq -r .pluginVersion state.json)"`
- On FAILED: set `metrics.completedAt`, then run the telemetry script before reporting the error

---

## Phase 1: FETCH (YOU do this directly)

YOU fetch requirements using Notion/Figma MCP tools directly.
Do NOT create a subagent for fetching — MCP auth doesn't propagate to subagents.

1. Create `.pilot/` directory in CWD
2. Use Notion MCP tools to fetch the page at the given URL
3. **FOLLOW RELATION LINKS** — HouseSigma uses Opportunity Trees:
   ```
   Problem page (user provides this)
     → "Solution" property → Solution page (has User Stories, Business Logic, AC, Mockups)
       → "Designs" property → Design page (may have Figma links)
   ```
   - Fetch the Problem page first
   - Read its "Solution" property — follow that link and fetch the Solution page
   - The Solution page has the REAL requirements (User Stories, Business Logic, AC)
   - If Solution has a "Designs" property — follow and fetch for Figma/design details
   - If Solution has a "Project" property — optionally fetch for task breakdown
4. If Figma links found (in Design page or elsewhere):
   - Use Figma MCP tools to extract component hierarchy, tokens, layout
5. Write `.pilot/requirement.json` combining data from ALL fetched pages:
   ```json
   {
     "title": "string",
     "notionUrl": "string",
     "problem": "string",
     "solution": "string",
     "acceptanceCriteria": ["string"],
     "affectedProjects": ["web-hybrid | housesigma-ios-native | housesigma-android-native | realagent-datafeed"],
     "figmaDesign": { "url": "...", "components": [], "tokens": {} } | null,
     "metadata": { "priority": "string", "status": "string" }
   }
   ```
6. Write `.pilot/state.json`:
   ```json
   {
     "pipelineId": "pipeline-<timestamp>",
     "sessionId": null,
     "phase": "FETCH",
     "notionUrl": "<url>",
     "pluginScriptsDir": "<resolved scripts path from SKILL.md Resolved Plugin Paths>",
     "pluginVersion": "<read from resolved plugin version file>",
     "metrics": {"interventions": 0, "completedAt": null},
     "createdAt": "<ISO>",
     "updatedAt": "<ISO>"
   }
   ```
   IMPORTANT: sessionId is `null` on initial creation — the PostToolUse hook auto-injects the real session ID. On all subsequent state.json writes (any phase after FETCH), **preserve the sessionId value from your last read** — do NOT write `null`.
   IMPORTANT: `pluginScriptsDir` and `pluginVersion` must come from the resolved paths in SKILL.md — do NOT use `${CLAUDE_PLUGIN_ROOT}` in Bash commands (it's only available in hooks, not in agent Bash).
7. Log a one-line summary then IMMEDIATELY continue — do NOT stop, do NOT ask the user anything:
   "需求: **<title>** | 平台: <affectedProjects> | AC: <count> 条 | Figma: <有/无>"
8. Update state.json: phase → RESOLVE. Proceed to Phase 1.5 in the SAME response.

---

## Phase 1.5: RESOLVE (Project Resolution)

Determine which project(s) to work in and build the project queue.
`.pilot/` stays in CWD — do NOT move it.

1. Read `affectedProjects` from requirement.json

2. **VERIFY affected projects** — don't trust the list blindly. When multiple projects listed:
   - For each project, investigate whether it actually contains code that needs to change
   - Read CLAUDE.md, grep for the relevant page/feature, check the actual implementation
   - Only keep projects that genuinely require code modifications
   - Remove projects where the change is already done (e.g., backend PR already merged)

3. **BUILD projectQueue** — ordered by dependency:
   - Backend/API first (realagent-datafeed)
   - Then frontend (web-hybrid)
   - Then native (housesigma-ios-native, housesigma-android-native)
   - If only one project remains after verification, queue has one entry

4. **SET FIRST PROJECT**:
   - `targetProject` = `projectQueue[0]`
   - CWD IS that project (has .git/) → projectDir = CWD (BEST: project's .claude/ hooks/rules active)
   - CWD is monorepo root → projectDir = `<CWD>/<targetProject>`
   - Verify projectDir has `.git/`

5. **Classify complexity** based on requirement scope:
   - **Simple** (1-3 files, single component, bug fix, config change): skip DESIGN+REVIEW, go straight to PLAN
   - **Standard** (new feature, multiple components, UI changes): full pipeline (DESIGN→REVIEW→PLAN→...)
   - **Complex** (multi-project, new architecture, API changes): full pipeline
   - Heuristics: count ACs (≤3 = likely simple), check if affectedProjects > 1 (= standard/complex), check if requirement mentions "new page/screen/API" (= standard+)
   - Record `complexity` in state.json

#### Project Capability Scan (§6.4)

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
  "hasDevServer": true,
  "devServerCommand": "<command or null>",
  "hasFigmaDesigns": false,
  "hasExistingTests": true,
  "conventionFiles": [],
  "qaCapabilities": {
    "web": { "chromeDevTools": false, "devServer": false },
    "ios": { "xcodeMcp": false, "simulator": false }
  }
}
```

**Discovery protocol (§6.1 — three levels):**
1. **Level 1 — CLAUDE.md explicit**: Read target project's CLAUDE.md for `buildCommand`, `testCommand`, `lintCommand`, `devServerCommand`. If found, use directly — skip probing.
2. **Level 2 — Config file probing** (when CLAUDE.md is missing or incomplete):
   - `package.json` → `scripts.test`, `scripts.lint`, `scripts.build`, `scripts.dev`
   - `Makefile` → `make test`, `make lint`, `make build`
   - `build.gradle` / `build.gradle.kts` → `./gradlew test`, `./gradlew lint`
   - `.xcodeproj` / `.xcworkspace` → `xcodebuild test` (or Xcode MCP)
   - `composer.json` → `composer test`
3. **Level 3 — Fallback**: Mark commands as `UNKNOWN`. Implementer discovers in first step.

Write results to `.pilot/project-capabilities.json`. All subsequent phases read this file.

6. Verify clean working tree: `git -C <projectDir> status --porcelain`
   - If dirty → warn, ask to stash or continue

7. Check development environment:
   - Read `<projectDir>/CLAUDE.md` for setup instructions and dependencies
   - Verify project dependencies are installed (check for node_modules, Pods, etc.)
   - If missing, suggest the install command from project docs

8. **Route by complexity**:
   - **Simple** → update state.json: phase → PLAN (skip DESIGN+REVIEW)
   - **Standard/Complex** → update state.json: phase → DESIGN (full pipeline)
   - Always set: projectDir, targetProject, projectQueue, currentProjectIndex → 0

---

## Phase 2: DESIGN

1. Read `.pilot/requirement.json`
2. Invoke `@pilot:tech-designer` with prompt containing:
   - Full requirement content
   - "Target project directory: <projectDir>"
   - If cross-project: "Related projects for API reference: <list>"
   - If `.pilot/cross-project-summary.md` exists: include it ("Previous projects made these decisions. Maintain consistency.")
   - If revision: include feedback from `.pilot/review.json`
3. **IMMEDIATELY write** returned markdown to `.pilot/tech-design.md`
4. Update state.json: phase → REVIEW

---

## Phase 3: REVIEW

1. Invoke `@pilot:design-reviewer` with prompt containing:
   - "Target project directory: <projectDir>"
   - If cross-project: "Related projects for API reference: <list>"
2. Parse CONFIDENCE and VERDICT from returned text
3. **IMMEDIATELY write** to `.pilot/review.json`:
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

---

## Phase 4: PLAN

YOU do this directly. Code paths use projectDir, artifacts stay in `.pilot/`.

1. Read `<projectDir>/CLAUDE.md` and `.claude/` docs for build, test, lint commands.
2. **Discover project convention files** for subagent context injection:
   - Glob `<projectDir>/.claude/rules/*.md`
   - Glob `<projectDir>/.claude/steering/*.md`
   - Glob `<projectDir>/.claude/docs/*.md` (if exists — some projects keep setup/auth notes here)
   - Record found paths (absolute) — these will be passed to implementer and code-reviewer prompts.
3. **Environment health check** — verify the project builds and existing tests pass BEFORE planning:
   a. **Detect verification mode**: check if Xcode MCP tools are available (try calling `BuildProject` — if it responds, set `xcodeMcp: true`).
      - If `xcodeMcp: true`: read workspace/scheme info from `<projectDir>/CLAUDE.md`. Record:
        `xcodeMcp: true`, `xcodeProject: { workspace, scheme, testScheme }`, `verificationMode: "mcp"`
      - If Xcode MCP unavailable: set `xcodeMcp: false`, `verificationMode: "bash"`. Fall back to CLI — find `make build` in Makefile or derive `xcodebuild` command from CLAUDE.md.
   b. **Run health check** using the detected mode:
      - When `verificationMode: "mcp"`: call `BuildProject` → structured success/fail. Call `ListNavigatorIssues` for error list.
      - When `verificationMode: "bash"`: run the project's primary build/typecheck command (e.g., `pnpm vtsc:app`, `./gradlew compileDebugKotlin`, `make build`).
        **verificationCommand MUST be a Bash-runnable command** (not an MCP tool like `BuildProject`). If CLAUDE.md only documents MCP-based building, check the project's Makefile or derive an equivalent CLI command.
      - If build fails on the clean branch → record as `baselineBuildFailure: true`.
   c. If test framework exists, run existing tests: `<test-command>` (no args = full suite)
      - If pre-existing tests fail → note which ones fail (these are NOT our responsibility, but must not be confused with regressions later)
   d. If CLAUDE.md documents a lint command separate from build (e.g., `eslint`, `ktlintCheck`), verify it works too.
      **Important**: use the check-only variant (no `--fix` flag) to avoid mutating the working tree before the feature branch is created
   e. Record all validated commands + baseline failures list — persist in plan.json:
      `verificationCommand` (build/typecheck), `testInfra` (test), `lintCommand` (lint, if separate), `baselineFailures`
      **Validation**: before persisting, verify each command is runnable via `bash -c "<command>"` dry-run. If a command is an MCP tool name or IDE action (not bash-executable), replace it with the CLI equivalent.

#### Health Check Enhancement (§6.1, §6.2)

1. Read `.pilot/project-capabilities.json` (created in RESOLVE)
2. Use `testInfra.runCommand` from capabilities (not hardcoded framework names)
3. Validate commands by dry-run where possible
4. Record validated commands in `plan.json`:
   - `verificationCommand`: from capabilities or CLAUDE.md
   - `lintCommand`: from capabilities or CLAUDE.md
   - `testInfra`: structured object from capabilities (§6.2)

4. **Detect test infrastructure**:
   - Check if project has a test framework (e.g., `vitest` in package.json, `junit` in build.gradle, `XCTest` in Xcode)
   - Also check **Makefile** for `test`/`build` targets (e.g., `make test`, `make build`)
   - Glob for existing test files (`**/*.test.ts`, `**/*.spec.ts`, `**/*Test.kt`, `**/*Tests.swift`, etc.)
   - Check for `UITests/` directory and `import XCUITest` files → detect UI test infrastructure
   - If no test framework → set `testInfra: null`, all steps will be `VERIFY_ONLY`
   - **iOS (xcodeMcp: true)**: use structured format:
     ```json
     "testInfra": {
       "unit": { "command": "RunSomeTests", "framework": "XCTest", "mode": "mcp" },
       "ui": { "command": "RunSomeTests", "framework": "XCUITest", "mode": "mcp", "scheme": "UITests" }
     }
     ```
     Omit `ui` key if no `UITests/` directory exists.
   - **Other projects (verificationMode: "bash")**: use flat format:
     `"testInfra": { "command": "pnpm vitest run", "framework": "vitest" }`
   - Record example test file paths as patterns for the implementer
5. **Build step list** from available context:
   - **Standard/Complex** (tech-design.md exists): read `.pilot/tech-design.md`, break into atomic steps
   - **Simple** (no tech-design.md): read `.pilot/requirement.json` directly, derive 1-3 steps from the ACs + affected files. Grep codebase to identify exact files to modify. No architecture doc needed for simple changes.
   Break into atomic steps:
   - VERIFY_ONLY steps: use the build/lint command from step 3 as `verification`
   - TESTABLE steps: use the **test command** from step 4 targeting the step's test file as `verification`
     (e.g., `pnpm vitest run packages/store/__tests__/myhome.test.ts` or `./gradlew test --tests "com.example.MyTest"`)
   - Order: types/schema → backend → API → frontend → tests
   - **Classify each step's `testability`**:
     - `TESTABLE`: business logic, API service, store/state, UI component with interactive behavior
     - `VERIFY_ONLY`: type definitions, i18n, routes, config, CSS (verified by build or VISUAL_CHECK)
   - **Classify each step's `uiChange`** (orthogonal to testability):
     Mark `uiChange: true` when any file in `filesModify` / `filesCreate` matches:
     - **iOS**: path contains `/UI/`, `/View/`, `/Cell/`, `/Screen/`; filename contains `View.swift`, `Cell.swift`, `ViewController.swift`; file contains `var body: some View` (SwiftUI); or `*.storyboard`, `*.xib`
     - **Web**: `*.vue`, `*.scss`, `*.css` (existing VISUAL_CHECK detection, now explicit per-step)
   - For `uiChange: true` + `TESTABLE` iOS steps, set `testSpec.testPatternRef` to an existing `UITests/` file. Add `navigationTest` field: the XCUITest method name that navigates to the target screen (e.g., `"UITests/MapFilterTests/testNavigateToSliderScreen"`).
   - For TESTABLE steps, add `testSpec`:
     - `testFile`: path for the test file (follow project test conventions)
     - `testPatternRef`: an existing test file to follow as pattern
     - `assertions`: human-readable list of what the test should verify
   - If a test needs multiple steps completed, assign testSpec to the **last** dependency step and mark earlier prerequisite steps as `VERIFY_ONLY` (they get tested via the later step's test)
   - For each step, also identify:
     - `designSection`: which section of tech-design.md describes this step
     - `patternRef`: an existing file to follow as implementation pattern
     - `dependsOn`: which prior step indices this step depends on
5b. **Requirement traceability check** — for each step in the plan:
    - Identify which AC(s) this step addresses → record as `acRefs: ["AC-1", "AC-5"]`
    - If a step cannot trace to ANY AC:
      → If it's infrastructure/scaffolding required by other steps → set `"scaffolding": true`, `acRefs: []`
      → If it's a standalone feature/API change with no AC backing → REMOVE the step.
        It is an ungrounded addition from the design phase.
    - If tech-design.md has API Changes marked `[ASSUMPTION]` → do NOT include in plan
      unless you independently verify an AC demands it
    - The `validate-plan.sh` script enforces: every non-scaffolding step must have non-empty `acRefs`
6. Detect base branch:
   `git -C <projectDir> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##'`
   This resolves the symbolic ref to the actual branch name (e.g., "main", not "HEAD").
   Fallback: check if `origin/main` exists (`git -C <projectDir> rev-parse --verify origin/main`), else use `master`.
7. Write `.pilot/plan.json`:
   ```json
   {
     "totalSteps": N,
     "baseBranch": "main",
     "branchName": "feat/<slug>",
     "xcodeMcp": false,
     "xcodeProject": null,
     "verificationMode": "bash",
     "testInfra": { "command": "pnpm vitest run", "framework": "vitest" },
     "verificationCommand": "pnpm vtsc:app",
     "lintCommand": "pnpm eslint",
     "conventionFiles": ["<projectDir>/.claude/rules/vue-conventions.md", "<projectDir>/.claude/steering/tech.md"],
     "baselineFailures": [],
     "baselineBuildFailure": false,
     "steps": [
       {
         "index": 1,
         "title": "MyHome Pinia store",
         "description": "...",
         "designSection": "UI Changes §1",
         "testability": "TESTABLE",
         "uiChange": false,
         "acRefs": ["AC-2", "AC-8"],
         "scaffolding": false,
         "navigationTest": null,
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
     ]
   }
   All steps start with `"status": "pending"`. Implementer updates to `"pass"` or `"fail"` after each step.
   ```
8. Create branch: `git -C <projectDir> checkout -b <branchName>`
9. Log plan summary:
   "项目: <targetProject>\n分支: <branchName>\n步骤:\n1. <title> [TESTABLE|VERIFY_ONLY]\n..."
10. Update state.json: phase → IMPLEMENT, branch, baseBranch, currentStep → 1
11. Proceed immediately to Phase 5

---

## Phase 5: IMPLEMENT

**ALWAYS delegate to `@pilot:implementer`** — a subagent with fresh context that implements
all steps using JIT file reading (reads real code before each step, not predictions).

**YOU (parent) MUST NOT write project code directly.** You are an orchestrator.
If resuming mid-implementation: check plan.json step statuses, then re-invoke
`@pilot:implementer` with remaining steps. The implementer has Recovery logic
to reconstruct anchor set from git history.

1. Read `.pilot/plan.json` and `.pilot/tech-design.md` (if exists — simple tasks skip DESIGN)
2. Read `<projectDir>/CLAUDE.md` (the implementer subagent cannot auto-load it)
3. Build the implementer prompt:
   - `projectDir`: absolute path
   - `branch`: from plan.json
   - `baseBranch`: from plan.json (needed for anchor recovery after compaction)
   - `steps`: the full steps array from plan.json (includes testability + testSpec per step)
   - `testInfra`: from plan.json (test command + framework; null if no test infra)
   - For each step, extract the relevant `designSection` content from tech-design.md (if exists; for simple tasks, use step description directly)
   - **`claudeMd`**: full content of `<projectDir>/CLAUDE.md` (inline — subagents don't auto-load project docs)
   - **`conventionFiles`**: list of `.claude/rules/*.md`, `.claude/steering/*.md`, and `.claude/docs/*.md` paths discovered in PLAN step 2
   - **`baselineFailures`**: list of pre-existing test failures recorded in PLAN step 3c (so implementer can ignore them during anchor checks)
   - **`baselineBuildFailure`**: boolean from PLAN step 3b — if true, implementer treats pre-existing build failures as baseline (not regression)
   - **`verificationMode`**: from plan.json (`"mcp"` or `"bash"`) — implementer uses this to choose Xcode MCP vs Bash for build/test
   - If `.pilot/cross-project-summary.md` exists, include it as `crossProjectContext`
4. Invoke `@pilot:implementer` with the built prompt
5. Parse the returned summary:
   - `STEP_STATUSES` → update plan.json: set each step's `status` field to `"pass"` or `"fail"` as reported
   - `COMPLETED_STEPS` → update state.json: completedSteps
   - `SKIPPED_STEPS` → log warnings
   - `ISSUES` → if any design/code discrepancies, log them for code review
6. **Validate plan.json step statuses**: verify no steps remain `"pending"` — if any do, the implementer missed them.
7. Verify commits exist: `git -C <projectDir> log --oneline <baseBranch>..HEAD`
8. Update state.json: phase → CODE_REVIEW

**If implementer reports failures:**
- Steps that failed verification but were committed → let code-reviewer catch them
- Steps that were skipped → if not blocking any downstream step, proceed to CODE_REVIEW.
  If blocking: re-invoke `@pilot:implementer` with the same context as step 3,
  but set `steps` to ONLY the skipped/failed steps (implementer reconstructs anchor set
  from git history via Recovery flow). If re-invocation also fails → increment
  metrics.interventions, proceed to CODE_REVIEW and let code-reviewer flag the gaps.

---

## Phase 6: CODE_REVIEW + VISUAL_CHECK

Run sequentially: code review first, then visual check.

### 6a: Code Review (always runs)
1. Read `<projectDir>/CLAUDE.md` (code-reviewer subagent cannot auto-load it)
2. Invoke `@pilot:code-reviewer` with prompt containing:
   - "Project directory: <projectDir>. Pipeline artifacts at: <CWD>/.pilot/"
   - **`claudeMd`**: full content of `<projectDir>/CLAUDE.md` (inline)
   - **`conventionFiles`**: `.claude/rules/*.md` and `.claude/steering/*.md` paths from PLAN
   - **`testInfra`**: from plan.json (the validated test command — code-reviewer should use this instead of raw CLAUDE.md commands)
   - **`verificationCommand`**: the working build/typecheck command from PLAN
   - **`lintCommand`**: the validated lint command from PLAN (may be separate from build)
   - **`baseBranch`**: from plan.json (code-reviewer needs it for diff range)
   - **`baselineFailures`**: from plan.json (pre-existing test failures — not regressions)
   - **`baselineBuildFailure`**: from plan.json (pre-existing build failure — not a regression)
   - **`verificationMode`**: from plan.json — code-reviewer uses this to choose Xcode MCP vs Bash for verification
   - **`qaCapabilities`**: `{ "web": <bool>, "ios": <bool> }`
     - Set `web: true` when ALL of: (1) `targetProject == "web-hybrid"`, (2) diff includes `.vue/.scss/.css`, (3) `claudeMd` has dev server command.
     - Set `ios: true` when: (1) `verificationMode == "mcp"`, (2) `targetProject` contains `"ios"`.
     If Figma design exists, also pre-fetch screenshot via Figma MCP and pass as `figmaScreenshot`.
     Pass `devServerCommand`, `devUrl`, and `affectedRoutes` (inferred from diff + router).
3. Parse results
4. **IMMEDIATELY write** to `.pilot/code-review.json`:
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
5. Decision tree:
   - **FIX_REQUIRED + codeReviewCount < 3**: invoke implementer fix mode (see below), increment codeReviewCount, then re-invoke code-reviewer from step 2
   - **FIX_REQUIRED + codeReviewCount >= 3** or unresolvable:
     → phase → ESCALATED, metrics.interventions += 1, present to user
   - **APPROVE BUT testResult=FAIL or lintResult=FAIL**: treat as FIX_REQUIRED — invoke implementer fix mode, re-invoke code-reviewer
   - **APPROVE + testResult=PASS (or SKIPPED if no test infra) + lintResult=PASS**: proceed to VISUAL_CHECK gate (step 6)

   **Implementer fix mode invocation** (ALWAYS — no parent code edits):
   Re-invoke `@pilot:implementer` with the same context as Phase 5 PLUS fix-specific fields:
   - All fields from the original Phase 5 prompt: `projectDir`, `branch`, `baseBranch`, `steps` (from plan.json), `testInfra`, `claudeMd`, `conventionFiles`, `baselineFailures`, `baselineBuildFailure`
   - `fixMode: true`
   - `codeReviewIssues`: the `issues` array from `.pilot/code-review.json`
   - `testResult`, `lintResult`: from code-review.json (so implementer knows what's broken)
   - If tech-design.md exists: include relevant `designSection` content per issue
   The implementer reconstructs anchor set from git history (same as its Recovery flow),
   addresses issues by severity, and commits a fix. See implementer.md "Fix Mode" for details.

#### Three-Fix Architectural Escape Hatch (§1.2)

If code-review fix round 3 verdict is still FIX_REQUIRED:

1. **Do NOT retry.** Collect all 3 rounds of:
   - Implementer diffs
   - Reviewer comments/findings
2. Generate `.pilot/architectural-concern.md`:
   - Pattern analysis: which issues recurred across all 3 rounds?
   - Root cause hypothesis: is this a design-level flaw, not an implementation bug?
   - Suggested design revision or alternative approach
3. Set `state.json.currentPhase → "ESCALATED"`
4. Set `state.json.metrics.escalationCount += 1`
5. Present the architectural concern analysis to the user

**This also applies to DESIGN/REVIEW**: If design-reviewer returns REVISE 3 times on the same design, auto-escalate with the accumulated feedback.

6. **VISUAL_CHECK gate** — check ALL conditions:
   - `requirement.json` has `figmaDesign` that is NOT null
   - At least one plan step has `uiChange: true`
   - Platform-specific file changes detected:
     - `web-hybrid`: `git -C <projectDir> diff --name-only $(git -C <projectDir> merge-base origin/<baseBranch> HEAD)..HEAD | grep -E '\.(vue|scss|css)$'`
     - iOS (`targetProject` contains `"ios"`): `git -C <projectDir> diff --name-only $(git -C <projectDir> merge-base origin/<baseBranch> HEAD)..HEAD | grep -E '\.(swift|storyboard|xib)$'`

   **All conditions true** → update state.json: phase → VISUAL_CHECK, proceed to Phase 6b
   **Any false** → update state.json: phase → PR, proceed to Phase 7

---

## Phase 6b: VISUAL_CHECK (MANDATORY when gate passed in 6a step 5)

**Fallback mode**: If `code-review.json` contains `qaResult` that is NOT `"SKIPPED"` and NOT absent,
the code-reviewer already performed interactive QA. In this case:
1. Write `.pilot/visual-review.json`:
   ```json
   { "verdict": "DELEGATED_TO_CODE_REVIEWER", "qaResult": "<value from code-review.json>" }
   ```
2. Skip the rest of Phase 6b → proceed to Phase 7 (PR)

If `qaResult` is `"SKIPPED"` or absent, execute the full VISUAL_CHECK flow below.

If you reached this phase, the gate in Phase 6a confirmed: Figma designs exist,
UI changes were planned, and platform-specific files were changed. **Do NOT skip this phase.**

**No silent skipping.** If you cannot complete visual check (e.g., dev server won't start,
Chrome DevTools MCP unavailable, simulator won't boot), you MUST still write `visual-review.json` with
`"verdict": "SKIPPED"` and a `"reason"` explaining why. Never jump to PR without writing
this file — it is the audit trail that visual check was attempted.

### Platform routing

Determine the platform from `targetProject`:
- `web-hybrid` → Web VISUAL_CHECK flow (below)
- Contains `"ios"` → iOS VISUAL_CHECK flow (below)

### iOS VISUAL_CHECK flow

YOU do this directly using Figma MCP + Bash (`xcrun simctl`).

1. **Re-read project docs** (may have been compacted since PLAN phase):
   - Read `<projectDir>/CLAUDE.md` for Xcode workspace, scheme, environment setup
   - Read `.claude/steering/*.md` or `.claude/docs/` if they exist

2. **Get Figma design screenshot**:
   - Use Figma MCP `get_screenshot` with the fileKey and nodeId from requirement.json

3. **Boot simulator** (if none booted):
   `xcrun simctl boot "iPhone 16" 2>/dev/null || true`
   Leave the simulator running — do not shut down after capture.

4. **Build and install app**:
   - If `verificationMode == "mcp"`: call `BuildProject` via Xcode MCP (auto-installs to booted sim)
   - If `verificationMode == "bash"`: `make build` or `xcodebuild ...`

5. **Navigate to target screen**:
   - Read plan.json, find uiChange steps with `navigationTest` field
   - Run the navigation test to bring the app to the target screen:
     ```bash
     xcodebuild test-without-building \
       -workspace <workspace> -scheme UITests \
       -destination 'platform=iOS Simulator,name=iPhone 16' \
       -only-testing:<navigationTest> 2>&1 | tail -5
     ```
     (Uses Bash — `RunSomeTests` may not support `-only-testing` granularity. Output limited to last 5 lines.)
   - If no `navigationTest` available: write `visual-review.json` with `"verdict": "SKIPPED", "reason": "no navigation path to target screen"`, proceed to Phase 7.

6. **Capture simulator screenshot**:
   ```bash
   xcrun simctl io booted screenshot /tmp/pilot-ios-screenshot.png
   ```
   Read the screenshot file (Read tool supports images).

7. **Compare** (use your vision capability):
   - Layout, spacing, colors, typography, component positioning
   - Compare against Figma design tokens from requirement.json
   - Same comparison criteria as web

8. **Write** to `.pilot/visual-review.json` (same schema as web):
   ```json
   {
     "matches": ["layout correct", "colors match tokens"],
     "mismatches": [{"element": "...", "expected": "...", "actual": "..."}],
     "verdict": "MATCH|MISMATCH|PARTIAL|SKIPPED",
     "summary": "..."
   }
   ```

9. **Decision** (same as web):
   - MATCH/PARTIAL/SKIPPED → phase → PR
   - MISMATCH → fix visual issues, rebuild, re-navigate, re-screenshot (max 1 round)
   - Still mismatched → phase → PR with visual notes in PR body

### Web VISUAL_CHECK flow

YOU do this directly using Figma MCP + Chrome DevTools MCP.

1. **Re-read project docs** (may have been compacted since PLAN phase):
   - Read `<projectDir>/CLAUDE.md` for dev server command, environment setup, test URLs
   - Read `.claude/steering/*.md` or `.claude/docs/` if they exist — check for auth flow, viewport config
   - Do NOT hardcode any project-specific details — discover them from the project's own docs

2. **Get Figma design screenshot**:
   - Use Figma MCP `get_screenshot` with the fileKey and nodeId from requirement.json

3. **Render and capture browser screenshot**:
   - Start dev server (command from CLAUDE.md), navigate to the affected page, emulate correct viewport
   - Use Chrome DevTools MCP to take screenshot
   - Optionally: run Lighthouse audit if SEO/performance is a requirement
   - Stop dev server after capture

4. **Compare** (use your vision capability):
   - Layout, spacing, colors, typography, component positioning
   - Compare against Figma design tokens from requirement.json
   - Check responsive behavior matches design breakpoint

5. **Write** to `.pilot/visual-review.json`:
   ```json
   {
     "matches": ["layout correct", "colors match tokens"],
     "mismatches": [{"element": "...", "expected": "...", "actual": "..."}],
     "lighthouse": {"performance": 95, "seo": 100},
     "verdict": "MATCH|MISMATCH|PARTIAL|SKIPPED",
     "summary": "..."
   }
   ```

6. **Decision**:
   - **MATCH, PARTIAL (minor), or SKIPPED**: phase → PR
   - **MISMATCH**: fix visual issues (CSS/template edits), then:
     a. Run the project's verified build command, lint command, AND full test suite (if testInfra exists) to ensure visual fix didn't break types, lint, or existing tests. Exclude `baselineFailures` from plan.json when evaluating test results (same as IMPLEMENT/CODE_REVIEW).
     b. `git commit` the visual fix
     c. Re-capture browser screenshot, re-compare (max 1 round)
   - Still mismatched after fix: phase → PR with visual notes in PR body

---

## Phase 7: PR

1. Push: `git -C <projectDir> push -u origin <branchName>`
2. Create PR:
   ```bash
   cd <projectDir> && gh pr create --draft \
     --title "feat: <requirement.title>" \
     --body "<body>"
   ```
3. PR body template:
   ```markdown
   ## Requirement
   **<title>**
   [Notion](<notionUrl>) | [Figma](<figmaUrl>)
   ### Problem
   <problem>
   ### Solution
   <solution>
   ## Technical Approach
   <from tech-design.md summary — or "Direct implementation (simple task)" if no design>
   ## Changes
   <git diff --stat>
   ## Verification
   - Tests: <result>
   - Lint: <result>
   - Design review: <N>/100 (or "skipped — simple task" if no design phase)
   - Code review: <N>/100
   ## Acceptance Criteria
   <from code-review.json requirementsCoverage>
   ---
   > Generated by pilot. Human review required before merge.
   ```
4. Update state.json: prUrl → <url>
5. **Check project queue**:
   - **More projects** (`currentProjectIndex < projectQueue.length - 1`):
     → phase → PROJECT_TRANSITION, proceed to Phase 8
   - **Last project**:
     → Set metrics.completedAt → <ISO> (but keep phase as PR until telemetry is written)
     → Write telemetry: `bash "$(jq -r .pluginScriptsDir "$PWD/.pilot/state.json")/write-telemetry.sh" "$PWD/.pilot/state.json" "$(jq -r .pluginVersion "$PWD/.pilot/state.json")"`
     → NOW set phase → COMPLETED (only after telemetry is durable)
     → Report all PRs + scores. Ask: "清理 .pilot/ 文件？"

---

## Phase 8: PROJECT_TRANSITION (multi-project only)

Transition from one completed project to the next in the queue.

1. **Set completion time** (if not already set — idempotent for resume): update state.json `metrics.completedAt` → current ISO timestamp
2. `mkdir -p .pilot/completed` (ensure directory exists before marker/archive)
3. **Write telemetry** (idempotent — check marker first):
   - If `.pilot/completed/<targetProject>.telemetry` marker does NOT exist (use targetProject from state.json):
     → Run `bash "$(jq -r .pluginScriptsDir "$PWD/.pilot/state.json")/write-telemetry.sh" "$PWD/.pilot/state.json" "$(jq -r .pluginVersion "$PWD/.pilot/state.json")"`
     → Create the marker file
   - Report: "✅ **<targetProject>** PR: <prUrl> (score: <N>)"

4. **Archive current project's artifacts**:
   ```bash
   mkdir -p .pilot/completed
   for f in tech-design.md review.json plan.json code-review.json visual-review.json; do
     [ -f ".pilot/$f" ] && mv ".pilot/$f" ".pilot/completed/<targetProject>.$f"
   done
   ```

5. **Write/append cross-project summary** to `.pilot/cross-project-summary.md`:
   ```markdown
   ## <targetProject> (completed)
   - **PR**: <prUrl>
   - **Branch**: <branch>
   - **API contracts consumed**: <list endpoints and param shapes from tech-design>
   - **Key design decisions**: <patterns chosen, naming, component architecture>
   - **Shared naming**: <identifiers that other projects should match>
   ```

6. **Push to completedProjects** in state.json:
   ```json
   { "name": "<targetProject>", "prUrl": "<url>", "branch": "<branch>" }
   ```

7. **Atomic queue advance + new project setup** (do these together in a single state.json write to prevent partial-transition on compaction):
   - `currentProjectIndex += 1`
   - `targetProject` = `projectQueue[currentProjectIndex]`
   - `projectDir` = resolve path (CWD/<targetProject> or CWD if matching)
   - Reset per-project fields: branch, baseBranch, reviewConfidence, reviewRevisionCount, codeReviewConfidence, codeReviewCount, currentStep, completedSteps, prUrl → null
   - Reset timing: `createdAt` → current ISO (new project start), `metrics.completedAt` → null, `metrics.interventions` → 0
   - phase → DESIGN (transition complete — resume from here is safe)

8. **Verify new project** (same as RESOLVE steps 6-7):
   - Clean working tree
   - Dependencies installed
   - Read CLAUDE.md
   - Proceed immediately to Phase 4 (PLAN) or Phase 2 (DESIGN) based on state.
