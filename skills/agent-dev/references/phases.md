# Phase Instructions

Read the section matching your current phase from state.json.
After compaction, re-read this file and state.json to resume.

## Compact Instructions

When compacting, preserve in priority order:
1. Current phase + projectDir + branch (from state.json)
2. plan.json step statuses (which steps passed/failed/pending)
3. Recent subagent verdicts (APPROVE/FIX_REQUIRED/REVISE)

Safe to discard:
- Notion/Figma MCP tool call results from FETCH phase
- Raw subagent output text (already persisted to .agent-dev/ files on disk)
- File contents read during PLAN/RESOLVE (re-readable from disk)
- Completed phase artifacts content (on disk: tech-design.md, review.json, etc.)

ALL `.agent-dev/` artifacts live in CWD. This is typically the target project directory.
Recommended: run `/agent-dev` from inside the target project (e.g., `cd web-hybrid && claude`).
This way, the project's .claude/ hooks, rules, skills, and steering docs are automatically loaded.

If CWD is a monorepo root with multiple sub-projects:
- RESOLVE will detect the target sub-project directory
- projectDir = `<CWD>/<sub-project>` — code operations use absolute paths
- `.agent-dev/` stays in CWD (monorepo root)

## Telemetry

Every pipeline run (COMPLETED or FAILED) writes a row to `~/.agent-dev-telemetry.tsv`.
- **Score formula** (0-100): completion(40) + low-interventions(30) + design-first-pass(15) + code-review-first-pass(15)
- **metrics.interventions**: increment whenever the pipeline stops to ask the user (ESCALATED, unrecoverable error)
- Written by: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-telemetry.sh" "$PWD/.agent-dev/state.json" "<version>"`
- On FAILED: set `metrics.completedAt`, then run the telemetry script before reporting the error

---

## Phase 1: FETCH (YOU do this directly)

YOU fetch requirements using Notion/Figma MCP tools directly.
Do NOT create a subagent for fetching — MCP auth doesn't propagate to subagents.

1. Create `.agent-dev/` directory in CWD
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
5. Write `.agent-dev/requirement.json` combining data from ALL fetched pages:
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
6. Write `.agent-dev/state.json`: `{ "pipelineId": "pipeline-<timestamp>", "sessionId": null, "phase": "FETCH", "notionUrl": "<url>", "metrics": {"interventions": 0, "completedAt": null}, "createdAt": "<ISO>", "updatedAt": "<ISO>" }`
   IMPORTANT: sessionId is auto-injected by the PostToolUse hook on every state.json write. Always write `null` — never hardcode a value.
7. Log a one-line summary then IMMEDIATELY continue — do NOT stop, do NOT ask the user anything:
   "需求: **<title>** | 平台: <affectedProjects> | AC: <count> 条 | Figma: <有/无>"
8. Update state.json: phase → RESOLVE. Proceed to Phase 1.5 in the SAME response.

---

## Phase 1.5: RESOLVE (Project Resolution)

Determine which project(s) to work in and build the project queue.
`.agent-dev/` stays in CWD — do NOT move it.

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

1. Read `.agent-dev/requirement.json`
2. Invoke `@agent-dev:tech-designer` with prompt containing:
   - Full requirement content
   - "Target project directory: <projectDir>"
   - If cross-project: "Related projects for API reference: <list>"
   - If `.agent-dev/cross-project-summary.md` exists: include it ("Previous projects made these decisions. Maintain consistency.")
   - If revision: include feedback from `.agent-dev/review.json`
3. **IMMEDIATELY write** returned markdown to `.agent-dev/tech-design.md`
4. Update state.json: phase → REVIEW

---

## Phase 3: REVIEW

1. Invoke `@agent-dev:design-reviewer`
2. Parse CONFIDENCE and VERDICT from returned text
3. **IMMEDIATELY write** to `.agent-dev/review.json`:
   ```json
   {
     "confidence": 82,
     "verdict": "APPROVE",
     "issues": [{"severity": "MINOR", "description": "..."}],
     "summary": "..."
   }
   ```
4. Decision tree (**VERDICT is primary, confidence is secondary**):
   - **VERDICT == APPROVE** (any confidence >= 60): proceed to PLAN
     → Update state.json: phase → PLAN, reviewConfidence → N
   - **VERDICT == APPROVE BUT confidence < 60**: warn user, ask to confirm or revise
   - **VERDICT == REVISE**: revision loop
     → If reviewRevisionCount < 3 → back to Phase 2 with issues as feedback
     → Increment reviewRevisionCount in state.json
   - **VERDICT == ESCALATE** OR reviewRevisionCount >= 3:
     → Update state.json: phase → ESCALATED, metrics.interventions += 1
     → Present all issues to user
     → Ask: "要我修复特定问题？还是重新设计？还是手动批准？"
     → On user response: set phase back to DESIGN or PLAN accordingly

---

## Phase 4: PLAN

YOU do this directly. Code paths use projectDir, artifacts stay in `.agent-dev/`.

1. Read `<projectDir>/CLAUDE.md` and `.claude/` docs for build, test, lint commands.
2. **Discover project convention files** for subagent context injection:
   - Glob `<projectDir>/.claude/rules/*.md`
   - Glob `<projectDir>/.claude/steering/*.md`
   - Glob `<projectDir>/.claude/docs/*.md` (if exists — some projects keep setup/auth notes here)
   - Record found paths (absolute) — these will be passed to implementer and code-reviewer prompts.
3. **Environment health check** — verify the project builds and existing tests pass BEFORE planning:
   a. Run the project's primary build/typecheck command (e.g., `pnpm vtsc:app`, `./gradlew compileDebugKotlin`)
      - If the command from CLAUDE.md doesn't exist, find the underlying command and use that instead
      - If build fails on the clean branch → record as `baselineBuildFailure: true` in plan.json. VERIFY_ONLY steps and code review should treat pre-existing build failures the same way as baselineFailures for tests.
   b. If test framework exists, run existing tests: `<test-command>` (no args = full suite)
      - If pre-existing tests fail → note which ones fail (these are NOT our responsibility, but must not be confused with regressions later)
   c. If CLAUDE.md documents a lint command separate from build (e.g., `eslint`, `ktlintCheck`), verify it works too.
      **Important**: use the check-only variant (no `--fix` flag) to avoid mutating the working tree before the feature branch is created
   d. Record all validated commands + baseline failures list — persist in plan.json:
      `verificationCommand` (build/typecheck), `testInfra` (test), `lintCommand` (lint, if separate), `baselineFailures`
4. **Detect test infrastructure**:
   - Check if project has a test framework (e.g., `vitest` in package.json, `junit` in build.gradle, `XCTest` in Xcode)
   - Glob for existing test files (`**/*.test.ts`, `**/*.spec.ts`, `**/*Test.kt`, etc.)
   - If no test framework → set `testInfra: null`, all steps will be `VERIFY_ONLY`
   - If found → record test command (e.g., `pnpm vitest run`) and example test file paths as patterns
5. **Build step list** from available context:
   - **Standard/Complex** (tech-design.md exists): read `.agent-dev/tech-design.md`, break into atomic steps
   - **Simple** (no tech-design.md): read `.agent-dev/requirement.json` directly, derive 1-3 steps from the ACs + affected files. Grep codebase to identify exact files to modify. No architecture doc needed for simple changes.
   Break into atomic steps:
   - VERIFY_ONLY steps: use the build/lint command from step 3 as `verification`
   - TESTABLE steps: use the **test command** from step 4 targeting the step's test file as `verification`
     (e.g., `pnpm vitest run packages/store/__tests__/myhome.test.ts` or `./gradlew test --tests "com.example.MyTest"`)
   - Order: types/schema → backend → API → frontend → tests
   - **Classify each step's `testability`**:
     - `TESTABLE`: business logic, API service, store/state, UI component with interactive behavior
     - `VERIFY_ONLY`: type definitions, i18n, routes, config, CSS (verified by build or VISUAL_CHECK)
   - For TESTABLE steps, add `testSpec`:
     - `acRefs`: which acceptance criteria this step addresses
     - `testFile`: path for the test file (follow project test conventions)
     - `testPatternRef`: an existing test file to follow as pattern
     - `assertions`: human-readable list of what the test should verify
   - If a test needs multiple steps completed, assign testSpec to the **last** dependency step and mark earlier prerequisite steps as `VERIFY_ONLY` (they get tested via the later step's test)
   - For each step, also identify:
     - `designSection`: which section of tech-design.md describes this step
     - `patternRef`: an existing file to follow as implementation pattern
     - `dependsOn`: which prior step indices this step depends on
6. Detect base branch:
   `git -C <projectDir> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##'`
   This resolves the symbolic ref to the actual branch name (e.g., "main", not "HEAD").
   Fallback: check if `origin/main` exists (`git -C <projectDir> rev-parse --verify origin/main`), else use `master`.
7. Write `.agent-dev/plan.json`:
   ```json
   {
     "totalSteps": N,
     "baseBranch": "main",
     "branchName": "feat/<slug>",
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
         "testSpec": {
           "acRefs": ["AC-2", "AC-8"],
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

Delegate to `@agent-dev:implementer` — a subagent with fresh context that implements
all steps using JIT file reading (reads real code before each step, not predictions).

1. Read `.agent-dev/plan.json` and `.agent-dev/tech-design.md` (if exists — simple tasks skip DESIGN)
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
   - **`baselineFailures`**: list of pre-existing test failures recorded in PLAN step 3b (so implementer can ignore them during anchor checks)
   - If `.agent-dev/cross-project-summary.md` exists, include it as `crossProjectContext`
4. Invoke `@agent-dev:implementer` with the built prompt
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
- Steps that were skipped → assess if critical. If blocking, fix manually and re-commit.
  If >2 manual fixes needed, increment metrics.interventions.

---

## Phase 6: CODE_REVIEW + VISUAL_CHECK

Run sequentially: code review first, then visual check.

### 6a: Code Review (always runs)
1. Read `<projectDir>/CLAUDE.md` (code-reviewer subagent cannot auto-load it)
2. Invoke `@agent-dev:code-reviewer` with prompt containing:
   - "Project directory: <projectDir>. Pipeline artifacts at: <CWD>/.agent-dev/"
   - **`claudeMd`**: full content of `<projectDir>/CLAUDE.md` (inline)
   - **`conventionFiles`**: `.claude/rules/*.md` and `.claude/steering/*.md` paths from PLAN
   - **`testInfra`**: from plan.json (the validated test command — code-reviewer should use this instead of raw CLAUDE.md commands)
   - **`verificationCommand`**: the working build/typecheck command from PLAN
   - **`lintCommand`**: the validated lint command from PLAN (may be separate from build)
   - **`baseBranch`**: from plan.json (code-reviewer needs it for diff range)
3. Parse results
4. **IMMEDIATELY write** to `.agent-dev/code-review.json`:
   ```json
   {
     "testResult": "PASS|FAIL",
     "lintResult": "PASS|FAIL",
     "confidence": 82,
     "verdict": "APPROVE",
     "issues": [],
     "requirementsCoverage": {"covered": [], "missing": []},
     "summary": "..."
   }
   ```
5. Decision tree:
   - **FIX_REQUIRED + codeReviewCount < 2**: fix issues yourself, commit, increment codeReviewCount, re-invoke code-reviewer from step 2
   - **FIX_REQUIRED + codeReviewCount >= 2** or unresolvable:
     → phase → ESCALATED, metrics.interventions += 1, present to user
   - **APPROVE BUT testResult=FAIL or lintResult=FAIL**: treat as FIX_REQUIRED — fix the failing tests/lint, re-invoke
   - **APPROVE + testResult=PASS (or SKIPPED if no test infra) + lintResult=PASS**: proceed to VISUAL_CHECK gate (step 6)
6. **VISUAL_CHECK gate** — check ALL three conditions:
   - `requirement.json` has `figmaDesign` that is NOT null
   - `targetProject` is `web-hybrid`
   - Implementation includes UI-related file changes (check `git -C <projectDir> diff --name-only $(git -C <projectDir> merge-base origin/<baseBranch> HEAD)..HEAD | grep -E '\.(vue|scss|css)$'`)

   **All three true** → update state.json: phase → VISUAL_CHECK, proceed to Phase 6b
   **Any false** → update state.json: phase → PR, proceed to Phase 7

---

## Phase 6b: VISUAL_CHECK (MANDATORY when gate passed in 6a step 5)

If you reached this phase, the gate in Phase 6a confirmed: Figma designs exist,
target is web-hybrid, and .vue files were changed. **Do NOT skip this phase.**

**No silent skipping.** If you cannot complete visual check (e.g., dev server won't start,
Chrome DevTools MCP unavailable), you MUST still write `visual-review.json` with
`"verdict": "SKIPPED"` and a `"reason"` explaining why. Never jump to PR without writing
this file — it is the audit trail that visual check was attempted.

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

5. **Write** to `.agent-dev/visual-review.json`:
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
   > Generated by agent-dev. Human review required before merge.
   ```
4. Update state.json: prUrl → <url>
5. **Check project queue**:
   - **More projects** (`currentProjectIndex < projectQueue.length - 1`):
     → phase → PROJECT_TRANSITION, proceed to Phase 8
   - **Last project**:
     → Set metrics.completedAt → <ISO> (but keep phase as PR until telemetry is written)
     → Write telemetry: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-telemetry.sh" "$PWD/.agent-dev/state.json" "1.4.0"`
     → NOW set phase → COMPLETED (only after telemetry is durable)
     → Report all PRs + scores. Ask: "清理 .agent-dev/ 文件？"

---

## Phase 8: PROJECT_TRANSITION (multi-project only)

Transition from one completed project to the next in the queue.

1. **Set completion time** (if not already set — idempotent for resume): update state.json `metrics.completedAt` → current ISO timestamp
2. `mkdir -p .agent-dev/completed` (ensure directory exists before marker/archive)
3. **Write telemetry** (idempotent — check marker first):
   - If `.agent-dev/completed/<targetProject>.telemetry` marker does NOT exist (use targetProject from state.json):
     → Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-telemetry.sh" "$PWD/.agent-dev/state.json" "1.4.0"`
     → Create the marker file
   - Report: "✅ **<targetProject>** PR: <prUrl> (score: <N>)"

4. **Archive current project's artifacts**:
   ```bash
   mkdir -p .agent-dev/completed
   for f in tech-design.md review.json plan.json code-review.json visual-review.json; do
     [ -f ".agent-dev/$f" ] && mv ".agent-dev/$f" ".agent-dev/completed/<targetProject>.$f"
   done
   ```

5. **Write/append cross-project summary** to `.agent-dev/cross-project-summary.md`:
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
