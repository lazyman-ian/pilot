# iOS UI Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iOS UI verification to the pilot pipeline — Xcode MCP for build/test, XCUITest TDD for testable steps, simulator screenshot comparison for visual checks.

**Architecture:** Extend existing pipeline agents (implementer, code-reviewer) with Xcode MCP tools. Modify PLAN phase to detect Xcode MCP + structured testInfra + uiChange flag. Expand VISUAL_CHECK gate to accept iOS projects with `xcrun simctl` screenshots.

**Tech Stack:** Xcode MCP (`xcrun mcpbridge`), XCUITest, `xcrun simctl`, jq (validation scripts)

---

### Task 1: Add Xcode MCP to plugin configuration

**Files:**
- Modify: `.mcp.json`

- [ ] **Step 1: Add xcode server to .mcp.json**

Current file has `figma` and `chrome-devtools`. Add `xcode` alongside them:

```json
{
  "figma": {
    "type": "http",
    "url": "https://mcp.figma.com/mcp"
  },
  "chrome-devtools": {
    "command": "npx",
    "args": ["-y", "chrome-devtools-mcp@latest"]
  },
  "xcode": {
    "type": "stdio",
    "command": "xcrun",
    "args": ["mcpbridge"]
  }
}
```

- [ ] **Step 2: Verify xcode MCP server starts**

Run: `xcrun mcpbridge --help 2>&1 | head -5`
Expected: help output or version info (confirms the binary exists)

- [ ] **Step 3: Commit**

```bash
git add .mcp.json
git commit -m "feat(mcp): add Xcode MCP server for iOS build/test verification"
```

---

### Task 2: Extend implementer agent with Xcode MCP tools + MCP-mode verification

**Files:**
- Modify: `agents/implementer.md`

- [ ] **Step 1: Add Xcode MCP to tool list**

In the frontmatter, change line 8:

```yaml
# Before:
tools: Read, Write, Edit, Bash, Glob, Grep, LSP

# After:
tools: Read, Write, Edit, Bash, Glob, Grep, LSP, mcp__plugin_pilot_xcode__*
```

- [ ] **Step 2: Update testInfra input documentation**

In the `## Input` section, update the `testInfra` bullet (line 21):

```markdown
# Before:
- `testInfra`: test framework info (`{ command, framework }`) or null if no test infra

# After:
- `testInfra`: test framework info — either flat `{ command, framework }` (web) or structured `{ unit: { command, framework, mode }, ui: { command, framework, mode, scheme } }` (iOS). Check `testInfra.unit` first; if absent, fall back to `testInfra.command`. `mode` is `"mcp"` or `"bash"`.
```

- [ ] **Step 3: Add verificationMode input documentation**

In the `## Input` section, after the `baselineBuildFailure` bullet (line 26), add:

```markdown
- `verificationMode`: `"mcp"` or `"bash"`. When `"mcp"`, use Xcode MCP tools (`BuildProject`, `RefreshCodeIssuesInFile`, `RunSomeTests`) instead of Bash commands for build/test verification. MCP returns structured results — far fewer tokens than raw CLI output.
```

- [ ] **Step 4: Add MCP-mode verification flow**

After the `## Process` header and before step 1, add a new section:

```markdown
## Verification Mode

Your prompt includes `verificationMode` (`"mcp"` or `"bash"`).

### When `verificationMode == "mcp"` (iOS with Xcode MCP):

- **After each file edit**: call `RefreshCodeIssuesInFile` for instant single-file error checking (replaces waiting for full build)
- **After all edits in a step**: call `BuildProject` for full compile verification
- **Run tests**: call `RunSomeTests` targeting the step's test file
- **Anchor regression check**: call `RunSomeTests` with no file filter (full suite)

### When `verificationMode == "bash"` (default, web/Android):

- Use the step's `verification` command via Bash (existing behavior)
- Use `testInfra.command` via Bash for anchors (existing behavior)

Always check `verificationMode` before running build/test. Do NOT mix modes — if MCP, use MCP throughout the step.
```

- [ ] **Step 5: Add uiChange + XCUITest TDD section**

After the existing TESTABLE section (after line 62 "Mark step status → `"pass"`"), add:

```markdown
   ### XCUITest for `uiChange: true` steps

   When a step has `uiChange: true` AND `testability == "TESTABLE"`:
   - Write **XCUITest** (not XCTest unit test) following the project's `.claude/rules/dev-workflow.md`:
     - Use Page Object pattern for reusable screen interactions
     - Use `accessibilityIdentifier` for element location — never hardcoded text
     - Reference existing files in `UITests/` as `testSpec.testPatternRef`
   - The RED→GREEN flow is identical to regular TESTABLE — only the test type differs
   - If the step has `navigationTest` field, the XCUITest should include a method that navigates to the target screen (will be reused by VISUAL_CHECK)

   When `uiChange: false` (or absent), write standard XCTest unit test as usual.
```

- [ ] **Step 6: Verify the file is valid markdown**

Run: `head -10 agents/implementer.md`
Expected: frontmatter with `tools:` line including `mcp__plugin_pilot_xcode__*`

- [ ] **Step 7: Commit**

```bash
git add agents/implementer.md
git commit -m "feat(implementer): add Xcode MCP tools + MCP-mode verification + XCUITest TDD"
```

---

### Task 3: Extend code-reviewer agent with Xcode MCP tools + iOS QA

**Files:**
- Modify: `agents/code-reviewer.md`

- [ ] **Step 1: Add Xcode MCP to tool list**

In the frontmatter, change line 8:

```yaml
# Before:
tools: Read, Glob, Grep, Bash, LSP, mcp__plugin_pilot_chrome-devtools__*

# After:
tools: Read, Glob, Grep, Bash, LSP, mcp__plugin_pilot_chrome-devtools__*, mcp__plugin_pilot_xcode__*
```

- [ ] **Step 2: Update verification commands section**

In `## Process` step 1 (line 18-27), after the lint fallback line, add:

```markdown
   - **Verification mode**: check `verificationMode` from plan.json.
     When `"mcp"`: use Xcode MCP tools (`BuildProject` for build, `ListNavigatorIssues` for errors, `RunSomeTests` for tests) instead of Bash commands. Lint (`make check`) still uses Bash — no MCP equivalent for SwiftLint.
     When `"bash"` (default): use Bash commands as before.
```

- [ ] **Step 3: Add iOS QA section**

After the existing `## Interactive QA (conditional)` section (after line 232), add:

```markdown
## iOS QA (conditional)

You have access to Xcode MCP tools for iOS build, test, and preview verification.

### Trigger Conditions (ALL must be true)
- `verificationMode` is `"mcp"` in your prompt
- `targetProject` contains `"ios"`

If conditions are not met, skip this section (web projects use Interactive QA above).

### Process

1. **Build verification** — call `BuildProject`. If fails, record `testResult: "FAIL"`.
2. **Run all tests** — call `RunSomeTests` (unit + UI tests). Record pass/fail.
3. **UI preview check** (only if any plan step has `uiChange: true`):
   - For each uiChange step, call `RenderPreview` on the modified SwiftUI/UIKit file
   - If RenderPreview unavailable (UIKit without PreviewProvider), skip — rely on test results
   - Record in `qaResult`: `"PASS"` if previews render correctly, `"FAIL"` if visual issues
4. **No uiChange steps** — `qaResult` based on test results: `testResult == "PASS"` → `qaResult: "PASS"`

### Output

Set `qaMethod: "xcode-mcp"` in both structured text and JSON output.
Include `QA_RESULT` and `QA_DETAILS` as normal.
```

- [ ] **Step 4: Add qaMethod to JSON output schema**

In the Part 2 JSON output template (around line 167-193), add `qaMethod` field after `qaResult`:

```json
{
  "testResult": "PASS",
  "lintResult": "PASS",
  "confidence": 68,
  "verdict": "FIX_REQUIRED",
  "rubricScores": { ... },
  "qaResult": "PASS|FAIL|SKIPPED",
  "qaMethod": "chrome-devtools|xcode-mcp|skipped",
  "qaDetails": [ ... ],
  ...
}
```

- [ ] **Step 5: Commit**

```bash
git add agents/code-reviewer.md
git commit -m "feat(code-reviewer): add Xcode MCP tools + iOS QA path + qaMethod field"
```

---

### Task 4: Update PLAN phase — Xcode MCP detection + uiChange + structured testInfra

**Files:**
- Modify: `skills/pilot/references/phases.md` (Phase 4 section, lines 199-316)

This is the largest change. The PLAN phase needs: Xcode MCP detection, MCP-mode health check, uiChange auto-marking, structured testInfra, and new plan.json schema fields.

- [ ] **Step 1: Add Xcode MCP detection to PLAN step 3**

Replace the current step 3a (lines 210-213) with:

```markdown
   a. **Detect verification mode**: check if Xcode MCP tools are available (try calling `BuildProject` — if it responds, set `xcodeMcp: true`).
      - If `xcodeMcp: true`: read workspace/scheme info from `<projectDir>/CLAUDE.md`. Record:
        ```json
        "xcodeMcp": true,
        "xcodeProject": { "workspace": "HouseSigma.xcworkspace", "scheme": "HouseSigma", "testScheme": "UnitTests" },
        "verificationMode": "mcp"
        ```
      - If Xcode MCP unavailable: set `xcodeMcp: false`, `verificationMode: "bash"`. Fall back to CLI — find `make build` in Makefile or derive `xcodebuild` command from CLAUDE.md.
   b. **Run health check** using the detected mode:
      - When `verificationMode: "mcp"`: call `BuildProject` → structured success/fail. Call `ListNavigatorIssues` for error list.
      - When `verificationMode: "bash"`: run the project's primary build/typecheck command (e.g., `pnpm vtsc:app`, `./gradlew compileDebugKotlin`, `make build`).
        **verificationCommand MUST be a Bash-runnable command** (not an MCP tool like `BuildProject`). If CLAUDE.md only documents MCP-based building, check the project's Makefile or derive an equivalent CLI command.
      - If build fails on the clean branch → record as `baselineBuildFailure: true`.
```

- [ ] **Step 2: Update test infrastructure detection (PLAN step 4)**

Replace current step 4 (lines 221-226) with:

```markdown
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
```

- [ ] **Step 3: Add uiChange auto-marking to PLAN step 5**

After the existing testability classification (line 237), add:

```markdown
   - **Classify each step's `uiChange`** (orthogonal to testability):
     Mark `uiChange: true` when any file in `filesModify` / `filesCreate` matches:
     - **iOS**: path contains `/UI/`, `/View/`, `/Cell/`, `/Screen/`; filename contains `View.swift`, `Cell.swift`, `ViewController.swift`; file contains `var body: some View` (SwiftUI); or `*.storyboard`, `*.xib`
     - **Web**: `*.vue`, `*.scss`, `*.css` (existing VISUAL_CHECK detection, now explicit per-step)
   - For `uiChange: true` + `TESTABLE` iOS steps, set `testSpec.testPatternRef` to an existing `UITests/` file. Add `navigationTest` field: the XCUITest method name that navigates to the target screen (e.g., `"UITests/MapFilterTests/testNavigateToSliderScreen"`).
```

- [ ] **Step 4: Update plan.json schema example**

Replace the current plan.json example (lines 261-308) — add the new fields to the schema:

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
  "conventionFiles": [],
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
      "testSpec": {
        "testFile": "packages/store/__tests__/myhome.test.ts",
        "testPatternRef": "packages/store/__tests__/watch.test.ts",
        "assertions": ["add() updates claimedIdSet", "remove() clears from set"]
      },
      "navigationTest": null,
      "filesCreate": ["packages/store/myhome.ts"],
      "filesModify": [],
      "patternRef": "packages/store/watch.ts",
      "dependsOn": [],
      "verification": "pnpm vitest run packages/store/__tests__/myhome.test.ts",
      "status": "pending"
    }
  ]
}
```

- [ ] **Step 5: Update IMPLEMENT phase prompt building (Phase 5 step 3)**

In the Phase 5 prompt building section (lines 332-343), add `verificationMode` to the injected fields:

```markdown
   - **`verificationMode`**: from plan.json (`"mcp"` or `"bash"`) — implementer uses this to choose Xcode MCP vs Bash for build/test
```

- [ ] **Step 6: Update CODE_REVIEW phase prompt building (Phase 6a step 2)**

In the Phase 6a prompt section (lines 370-385), add `verificationMode` to the injected fields:

```markdown
   - **`verificationMode`**: from plan.json — code-reviewer uses this to choose Xcode MCP vs Bash for verification
```

Also update the `qaCapabilities` construction:

```markdown
   - **`qaCapabilities`**: `{ "web": <bool>, "ios": <bool> }`
     - Set `web: true` when ALL of: (1) `targetProject == "web-hybrid"`, (2) diff includes `.vue/.scss/.css`, (3) `claudeMd` has dev server command.
     - Set `ios: true` when: (1) `verificationMode == "mcp"`, (2) `targetProject` contains `"ios"`.
     If Figma design exists, pre-fetch screenshot via Figma MCP and pass as `figmaScreenshot`.
```

- [ ] **Step 7: Commit**

```bash
git add skills/pilot/references/phases.md
git commit -m "feat(plan): Xcode MCP detection + uiChange flag + structured testInfra + iOS qaCapabilities"
```

---

### Task 5: Expand VISUAL_CHECK gate + iOS flow

**Files:**
- Modify: `skills/pilot/references/phases.md` (Phase 6 VISUAL_CHECK gate + Phase 6b)

- [ ] **Step 1: Replace VISUAL_CHECK gate condition**

Replace lines 424-430:

```markdown
6. **VISUAL_CHECK gate** — check ALL conditions:
   - `requirement.json` has `figmaDesign` that is NOT null
   - At least one plan step has `uiChange: true`
   - Platform-specific file changes detected:
     - `web-hybrid`: `git diff --name-only ... | grep -E '\.(vue|scss|css)$'`
     - iOS (`targetProject` contains `"ios"`): `git diff --name-only ... | grep -E '\.(swift|storyboard|xib)$'`

   **All conditions true** → update state.json: phase → VISUAL_CHECK, proceed to Phase 6b
   **Any false** → update state.json: phase → PR, proceed to Phase 7
```

- [ ] **Step 2: Add iOS flow to Phase 6b**

After the existing web VISUAL_CHECK flow (after line 491 "Re-capture browser screenshot"), add a new section before the web flow, restructuring Phase 6b to route by platform:

```markdown
## Phase 6b: VISUAL_CHECK (MANDATORY when gate passed in 6a step 6)

[... keep existing fallback mode for code-reviewer qaResult delegation ...]

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

[... existing web flow unchanged ...]
```

- [ ] **Step 3: Commit**

```bash
git add skills/pilot/references/phases.md
git commit -m "feat(visual-check): expand gate to iOS + add simulator screenshot flow"
```

---

### Task 6: Update validate-code-review.sh for qaMethod field

**Files:**
- Modify: `scripts/validate-code-review.sh`

- [ ] **Step 1: Add qaMethod validation**

After the existing QA missing hint (Warning 6, lines 62-72), add:

```bash
# Warning 7: iOS project but qaMethod missing
if [ "$QA_RESULT" != "SKIPPED" ] && [ "$QA_RESULT" != "MISSING" ]; then
  QA_METHOD=$(jq -r '.qaMethod // "MISSING"' "$FILE")
  if [ "$QA_METHOD" = "MISSING" ]; then
    echo "WARNING: qaResult is $QA_RESULT but qaMethod field is missing. Expected: chrome-devtools, xcode-mcp, or skipped." >&2
  fi
fi
```

Also update Warning 6 to also warn for iOS projects:

```bash
# Warning 6: QA missing hint for web-hybrid or iOS
QA_RESULT=$(jq -r '.qaResult // "MISSING"' "$FILE")
if [ "$QA_RESULT" = "MISSING" ]; then
  AGENT_DEV_DIR=$(dirname "$FILE")
  STATE_FILE="$AGENT_DEV_DIR/state.json"
  if [ -f "$STATE_FILE" ]; then
    TARGET=$(jq -r '.targetProject // ""' "$STATE_FILE" 2>/dev/null)
    if [ "$TARGET" = "web-hybrid" ]; then
      echo "WARNING: web-hybrid project but qaResult missing from code-review.json." >&2
    elif echo "$TARGET" | grep -q "ios"; then
      echo "WARNING: iOS project but qaResult missing from code-review.json." >&2
    fi
  fi
fi
```

- [ ] **Step 2: Verify script syntax**

Run: `bash -n scripts/validate-code-review.sh && echo "syntax ok"`
Expected: `syntax ok`

- [ ] **Step 3: Commit**

```bash
git add scripts/validate-code-review.sh
git commit -m "feat(validation): add qaMethod field warning + iOS qa missing hint"
```

---

### Task 7: Sync plugin to marketplace cache + manual verification

- [ ] **Step 1: Sync to local plugin cache**

```bash
rsync -av --delete --exclude='.git' /Users/lazyman/projects/pilot/ /Users/lazyman/.claude/plugins/cache/agent-dev-marketplace/pilot/1.6.0/
```

- [ ] **Step 2: Reload plugins**

User runs: `/reload-plugins`
Expected: `Reloaded: 3 plugins · 5 skills · 9 agents · 8 hooks · 3 plugin MCP servers · 4 plugin LSP servers`
(Note: MCP servers should now be 3, including xcode)

- [ ] **Step 3: Verify Xcode MCP tools are visible**

From the iOS project directory, check that `mcp__plugin_pilot_xcode__*` tools appear in deferred tools list.

- [ ] **Step 4: Commit plan document**

```bash
git add docs/superpowers/plans/2026-03-31-ios-ui-verification.md
git commit -m "docs(plan): iOS UI verification implementation plan"
```
