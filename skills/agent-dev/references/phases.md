# Phase Instructions

Read the section matching your current phase from state.json.
After compaction, re-read this file and state.json to resume.

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
6. Write `.agent-dev/state.json`: `{ "pipelineId": "pipeline-<timestamp>", "sessionId": "${CLAUDE_SESSION_ID}", "phase": "FETCH", "notionUrl": "<url>", "metrics": {"interventions": 0, "completedAt": null}, "createdAt": "<ISO>", "updatedAt": "<ISO>" }`
   IMPORTANT: include sessionId so the Stop hook only blocks THIS session, not other sessions in the same directory.
7. Log a one-line summary then IMMEDIATELY continue — do NOT stop, do NOT ask the user anything:
   "需求: **<title>** | 平台: <affectedProjects> | AC: <count> 条 | Figma: <有/无>"
8. Update state.json: phase → RESOLVE. Proceed to Phase 1.5 in the SAME response.

---

## Phase 1.5: RESOLVE (Project Resolution)

Determine which project to work in. All subsequent phases operate on this project's codebase.
`.agent-dev/` stays in CWD — do NOT move it.

1. Read `affectedProjects` from requirement.json

2. **VERIFY affected projects** — don't trust the list blindly. When multiple projects listed:
   - For each project, investigate whether it actually contains code that needs to change
   - Read CLAUDE.md, grep for the relevant page/feature, check the actual implementation
   - Only keep projects that genuinely require code modifications
   - Remove projects where the change is inherited from another project

3. **SINGLE PROJECT** (common after verification):
   - CWD IS that project (has .git/) → projectDir = CWD (BEST: project's .claude/ hooks/rules active)
   - CWD is monorepo root → projectDir = `<CWD>/<affectedProject>`
     Note: sub-project's .claude/ hooks won't auto-load in this case.
     Read `<projectDir>/.claude/settings.json` for hooks and manually apply them (e.g., run lint after edits).
   - Verify projectDir has `.git/`

4. **GENUINELY MULTIPLE PROJECTS** (e.g., new API endpoint + frontend):
   - Only if changes truly require different codebases
   - Set targetProject to the dependency root (usually backend first)
   - Record otherProjects for follow-up
   - Do NOT stop to ask user — just pick the right order and proceed

5. Verify clean working tree: `git -C <projectDir> status --porcelain`
   - If dirty → warn, ask to stash or continue

6. Check development environment:
   - Read `<projectDir>/CLAUDE.md` for setup instructions and dependencies
   - Verify project dependencies are installed (check for node_modules, Pods, etc.)
   - If missing, suggest the install command from project docs

7. Update state.json: projectDir, targetProject, otherProjects, phase → DESIGN

---

## Phase 2: DESIGN

1. Read `.agent-dev/requirement.json`
2. Invoke `@agent-dev:tech-designer` with prompt containing:
   - Full requirement content
   - "Target project directory: <projectDir>"
   - If cross-project: "Related projects for API reference: <list>"
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
2. Read `.agent-dev/tech-design.md`, break into atomic steps:
   - Each step: 1-3 files, has verification command (from project docs)
   - Order: types/schema → backend → API → frontend → tests
3. Detect base branch:
   `git -C <projectDir> rev-parse --abbrev-ref origin/HEAD 2>/dev/null`
   This returns e.g. "origin/main" — strip the "origin/" prefix.
   Fallback: main → master
4. Write `.agent-dev/plan.json`:
   ```json
   {
     "totalSteps": N,
     "baseBranch": "main",
     "branchName": "feat/<slug>",
     "steps": [{"index": 1, "title": "...", "description": "...",
       "filesCreate": [], "filesModify": [], "verification": "..."}]
   }
   ```
5. Create branch: `git -C <projectDir> checkout -b <branchName>`
6. Log plan summary:
   "项目: <targetProject>\n分支: <branchName>\n步骤:\n1. <title>\n..."
7. Update state.json: phase → IMPLEMENT, currentStep → 1
8. Proceed immediately to Phase 5

---

## Phase 5: IMPLEMENT

YOU implement ALL steps sequentially. Best continuous context.

**IMPORTANT: Separate UI and logic in commits.**
When a step involves both logic and UI changes, split into separate commits:
- Logic commit: data, API calls, state management, business logic
- UI commit: template, styles, layout, visual elements
This enables parallel CODE_REVIEW (logic) + VISUAL_CHECK (UI) in Phase 6.

For each step in plan.json:
1. Read step details
2. Implement using Read/Write/Edit/Bash
   - File paths: `<projectDir>/<relative-path>` (absolute paths)
   - Follow existing codebase patterns
3. Run verification: `cd <projectDir> && <verification>`
   - If verification tool not available (missing deps): note it, continue
   - If fails with code errors: fix + retry (max 2)
   - If still fails: ask user (increment metrics.interventions)
4. Commit: `git -C <projectDir> add <files> && git -C <projectDir> commit -m "feat(<scope>): <title>"`
5. Update state.json: completedSteps += index, currentStep → next

After all steps: phase → CODE_REVIEW

---

## Phase 6: CODE_REVIEW + VISUAL_CHECK

Run sequentially: code review first, then visual check (if conditions met).

### 6a: Code Review (always runs)
1. Invoke `@agent-dev:code-reviewer` with prompt:
   "Project directory: <projectDir>. Pipeline artifacts at: <CWD>/.agent-dev/"
2. Parse results
3. **IMMEDIATELY write** to `.agent-dev/code-review.json`:
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
4. Decision tree:
   - **APPROVE + tests/lint PASS**: proceed to 6b (if applicable) or PR
   - **FIX_REQUIRED + codeReviewCount < 2**: fix issues yourself, increment codeReviewCount, re-invoke
   - **FIX_REQUIRED + codeReviewCount >= 2** or unresolvable:
     → phase → ESCALATED, metrics.interventions += 1, present to user

---

## Phase 6b: VISUAL_CHECK (conditional — only when ALL conditions met)

**Skip this phase entirely if ANY of these are true:**
- requirement.json has `figmaDesign: null` (no design reference)
- targetProject is NOT web-hybrid (Chrome DevTools only works for web)
- The changes don't include UI modifications (backend-only changes)

**When to run:** figmaDesign exists AND targetProject is web-hybrid AND changes include UI files (.vue)

YOU do this directly using Figma MCP + Chrome DevTools MCP.

**Project-specific setup**: Read `<projectDir>/CLAUDE.md` and `<projectDir>/.claude/docs/`
for dev server commands, test URLs, environment setup, auth requirements, and viewport config.
Do NOT hardcode any project-specific details here — discover them from the project's own docs.

1. **Get Figma design screenshot**:
   - Use Figma MCP `get_screenshot` with the fileKey and nodeId from requirement.json

2. **Render and capture browser screenshot**:
   - Read project docs for: dev server command, environment setup, test page URL
   - Start dev server, navigate to the affected page, emulate correct viewport
   - Use Chrome DevTools MCP to take screenshot
   - Optionally: run Lighthouse audit if SEO/performance is a requirement
   - Stop dev server after capture

3. **Compare** (use your vision capability):
   - Layout, spacing, colors, typography, component positioning
   - Compare against Figma design tokens from requirement.json
   - Check responsive behavior matches design breakpoint

4. **Write** to `.agent-dev/visual-review.json`:
   ```json
   {
     "matches": ["layout correct", "colors match tokens"],
     "mismatches": [{"element": "...", "expected": "...", "actual": "..."}],
     "lighthouse": {"performance": 95, "seo": 100},
     "verdict": "MATCH|MISMATCH|PARTIAL",
     "summary": "..."
   }
   ```

5. **Decision**:
   - **MATCH or PARTIAL (minor)**: phase → PR
   - **MISMATCH**: fix visual issues, re-capture, re-compare (max 1 round)
   - Still mismatched: phase → PR with visual notes in PR body

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
   <from tech-design.md summary>
   ## Changes
   <git diff --stat>
   ## Verification
   - Tests: <result>
   - Lint: <result>
   - Design review: <N>/100
   - Code review: <N>/100
   ## Acceptance Criteria
   <from code-review.json requirementsCoverage>
   ---
   > Generated by agent-dev. Human review required before merge.
   ```
4. Update state.json: phase → COMPLETED, prUrl → <url>, metrics.completedAt → <ISO>
5. Write telemetry:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-telemetry.sh" "$PWD/.agent-dev/state.json" "1.3.0"
   ```
   This appends a row to `~/.agent-dev-telemetry.tsv` with pipeline score and metrics.
6. Report: "Pipeline 完成. PR: <url>" — include the telemetry score in the summary.
7. If otherProjects in state.json:
   "还有 <otherProjects> 需要实现。要继续下一个项目吗？"
8. Ask: "清理 .agent-dev/ 文件？"
