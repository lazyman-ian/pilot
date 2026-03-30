# iOS UI Verification Design

Adds iOS UI verification to the pilot pipeline: XCUITest automation for testable steps, Xcode MCP for build/test verification, and simulator screenshot comparison for visual checks.

## Context

The pipeline currently has zero iOS UI verification:
- VISUAL_CHECK gate only passes web-hybrid (`.vue/.scss/.css` files)
- Implementer/code-reviewer have no Xcode MCP tools — can't build or run tests via MCP
- `verificationCommand` was recorded as MCP tool name (`"Xcode BuildProject"`) but subagents only had Bash
- `testInfra: null` for iOS even though `UnitTests/` and `UITests/` exist with XCTest/XCUITest
- Code-reviewer `qaResult` always `"SKIPPED"` for iOS

Prior art: evaluator-upgrade spec (§2.6) reserved `qaCapabilities.mobile` with `xcrun simctl + screenshot` as future work.

## Requirement

- UI modification → screenshot comparison + XCUITest
- Functional fix → XCUITest only (no screenshot)

---

## §1: Step Classification Enhancement

Add `uiChange` boolean flag to each plan step, orthogonal to existing `testability`:

```
testability: TESTABLE | VERIFY_ONLY    (existing)
uiChange:    boolean                   (new)
```

Routing matrix:

| uiChange | testability  | IMPLEMENT behavior              | VISUAL_CHECK        |
|----------|--------------|---------------------------------|---------------------|
| true     | TESTABLE     | XCUITest TDD + MCP build        | Figma vs simulator  |
| true     | VERIFY_ONLY  | MCP build verification          | Figma vs simulator  |
| false    | TESTABLE     | XCTest unit test TDD            | skip                |
| false    | VERIFY_ONLY  | MCP build verification          | skip                |

### uiChange detection

PLAN marks `uiChange: true` when the step's `filesModify` / `filesCreate` match any of:

**iOS:**
- Path contains `/UI/`, `/View/`, `/Cell/`, `/Screen/`
- Filename contains `View.swift`, `Cell.swift`, `ViewController.swift`
- File contains `var body: some View` (SwiftUI)
- `*.storyboard`, `*.xib`

**Web (existing, unchanged):**
- `*.vue`, `*.scss`, `*.css`

**Android (future, not implemented):**
- `*.kt` in `/ui/`, `*.xml` layout files

---

## §2: PLAN Phase Changes

### 2a. Xcode MCP detection

PLAN checks plugin MCP availability. If `xcode` MCP server is available (plugin provides it via `.mcp.json`), record in plan.json:

```json
{
  "xcodeMcp": true,
  "xcodeProject": {
    "workspace": "HouseSigma.xcworkspace",
    "scheme": "HouseSigma",
    "testScheme": "UnitTests"
  }
}
```

Workspace/scheme read from project's CLAUDE.md. If Xcode MCP is unavailable (Xcode not installed, `xcrun mcpbridge` fails), set `xcodeMcp: false` and fallback to CLI (`make build` / `make test`).

### 2b. Health check via Xcode MCP

When `xcodeMcp: true`:
- Build verification: `BuildProject` → structured success/fail (replaces `make build` verbose output)
- Error list: `ListNavigatorIssues` → structured issues
- Record `verificationCommand: "BuildProject"` with `verificationMode: "mcp"`

When `xcodeMcp: false`:
- Fallback: `make build` / `xcodebuild` CLI
- Record `verificationMode: "bash"`

### 2c. uiChange auto-marking

For each step, check `filesModify` / `filesCreate` against the patterns in §1. Mark `uiChange: true` if any file matches.

### 2d. Test infrastructure detection (enhanced)

Replace flat `testInfra` with structured format:

```json
{
  "testInfra": {
    "unit": { "command": "RunSomeTests", "framework": "XCTest", "mode": "mcp" },
    "ui": { "command": "RunSomeTests", "framework": "XCUITest", "mode": "mcp", "scheme": "UITests" }
  }
}
```

Detection sources:
- Makefile targets (`make test`, `make build`)
- Glob for `*Tests.swift`, `*Test.swift`, `import XCTest`
- `UITests/` directory presence → `testInfra.ui` populated
- `UnitTests/` directory presence → `testInfra.unit` populated

When `xcodeMcp: false`: command = `make test`, mode = `"bash"`.

**Backward compatibility**: Web projects continue using flat `testInfra: { command, framework }`. The structured `{ unit, ui }` format is only for iOS (when `xcodeMcp: true` or UITests/ detected). Implementer and code-reviewer check `testInfra.unit` first; if absent, fall back to flat `testInfra.command`.

### 2e. plan.json schema additions

```json
{
  "xcodeMcp": true,
  "xcodeProject": { "workspace": "...", "scheme": "...", "testScheme": "..." },
  "verificationMode": "mcp | bash",
  "testInfra": {
    "unit": { "command": "...", "framework": "...", "mode": "..." },
    "ui": { "command": "...", "framework": "...", "mode": "...", "scheme": "..." }
  },
  "steps[].uiChange": true,
  "steps[].navigationTest": "UITests/MapFilterTests/testNavigateToSliderScreen"
}
```

---

## §3: Implementer Changes

### 3a. Tool chain

Add Xcode MCP to implementer agent definition:

```yaml
tools: Read, Write, Edit, Bash, Glob, Grep, LSP, mcp__plugin_pilot_xcode__*
```

Xcode MCP tools are silently unavailable for non-iOS projects — no impact on web/Android.

### 3b. MCP-mode verification flow

When `plan.json` has `verificationMode == "mcp"`, implementer uses Xcode MCP instead of Bash for build/test:

```
Edit file → RefreshCodeIssuesInFile (instant single-file check)
         → next file → RefreshCodeIssuesInFile
         → all done → BuildProject (full compile)
         → RunSomeTests (run tests)
```

Token savings: structured MCP results vs hundreds of lines of xcodebuild output.

### 3c. XCUITest TDD (uiChange: true + TESTABLE)

RED→GREEN flow unchanged, test type = XCUITest:

1. **RED**: Write XCUITest following project conventions from `.claude/rules/dev-workflow.md`:
   - Page Object pattern for reusable screen interactions
   - `accessibilityIdentifier` for element location (never hardcoded text)
   - Reference existing files in `UITests/` as pattern
2. **RED verify**: `RunSomeTests` on new test → should fail
3. **Implement**: Modify UI code, `RefreshCodeIssuesInFile` after each file
4. **GREEN verify**: `BuildProject` → `RunSomeTests` → pass
5. **Commit**: test + implementation together (atomic)

### 3d. XCTest unit TDD (uiChange: false + TESTABLE)

Same flow as §3c, test type = XCTest unit test. Reference existing files in `UnitTests/` as pattern.

### 3e. VERIFY_ONLY steps (uiChange: true or false)

```
Implement → RefreshCodeIssuesInFile → BuildProject → anchor set regression check
```

No test written. MCP build verification replaces the previously non-executable CLI command.

---

## §4: Code-reviewer Changes

### 4a. Tool chain

```yaml
tools: Read, Glob, Grep, Bash, LSP, mcp__plugin_pilot_chrome-devtools__*, mcp__plugin_pilot_xcode__*
```

### 4b. iOS verification flow

When `verificationMode == "mcp"`:

```
BuildProject         → compile verification (replaces bash verificationCommand)
ListNavigatorIssues  → check warnings/errors
RunSomeTests         → run unit + UI tests (replaces bash testInfra.command)
make check           → lint (still Bash — no MCP equivalent for SwiftLint)
```

### 4c. iOS QA capability

Current: code-reviewer only does Interactive QA for web-hybrid (Chrome DevTools). Add iOS path:

```
if targetProject contains "ios":
  1. BuildProject → ensure compilation passes
  2. RunSomeTests → full test suite (unit + UI)
  3. if uiChange steps exist:
     - RenderPreview → check SwiftUI/UIKit preview output
     - Write qaResult: "PASS" / "FAIL"
  4. if no uiChange:
     - qaResult based on test results alone
```

`RenderPreview` provides lightweight visual check within Xcode — no simulator launch required. Heavy comparison (Figma vs screenshot) is left to VISUAL_CHECK.

### 4d. code-review.json extension

```json
{
  "testResult": "PASS",
  "lintResult": "PASS",
  "qaResult": "PASS",
  "qaMethod": "xcode-mcp",
  ...
}
```

New field `qaMethod`: `"chrome-devtools"` | `"xcode-mcp"` | `"skipped"`. Replaces implicit skip for iOS.

---

## §5: VISUAL_CHECK iOS Path

### 5a. Gate condition expansion

Current gate (only web-hybrid):
```
figmaDesign != null AND targetProject == "web-hybrid" AND .vue/.scss/.css changed
```

Expanded:
```
figmaDesign != null AND uiChange steps exist AND (
  targetProject == "web-hybrid" → .vue/.scss/.css changed
  OR targetProject contains "ios" → .swift/.storyboard/.xib changed
  OR targetProject contains "android" → .kt/.xml changed (future)
)
```

### 5b. iOS VISUAL_CHECK flow

```
1. Figma screenshot: Parent uses Figma MCP get_screenshot (same as web)

2. Simulator screenshot:
   a. Boot simulator if needed: xcrun simctl boot <device>
   b. Build & install app: BuildProject via Xcode MCP → app auto-launches in simulator
   c. Navigate to target screen: run the navigationTest from plan.json
      xcodebuild test -only-testing:UITests/<TestClass>/<navigationMethod> ...
      (Uses Bash, not Xcode MCP — RunSomeTests may not support -only-testing granularity.
       Output is minimal: single test pass/fail, not a full build log.)
   d. Capture: xcrun simctl io booted screenshot /tmp/pilot-screenshot.png
   e. Read screenshot (Read tool supports images)

3. Vision comparison: Figma screenshot vs simulator screenshot
   - Layout, spacing, colors, typography, component positioning
   - Compare against Figma design tokens from requirement.json
   - Same comparison logic as web

4. Write visual-review.json (structure unchanged)
```

### 5c. Navigation via XCUITest

Web navigates by opening a URL. iOS requires navigating through the app.

Solution: reuse XCUITest written by implementer. PLAN adds `navigationTest` field to uiChange steps, recording which XCUITest method navigates to the target screen.

VISUAL_CHECK runs that specific test method to bring the app to the target screen, then captures screenshot.

If no `navigationTest` available (e.g., VERIFY_ONLY step with no XCUITest):
- Write `visual-review.json` with `"verdict": "SKIPPED", "reason": "no navigation path to target screen"`
- Pipeline continues — does not block

---

## §6: Plugin MCP Configuration

### 6a. .mcp.json addition

Add Xcode MCP to plugin's `.mcp.json` alongside existing servers:

```json
{
  "mcpServers": {
    "xcode": {
      "type": "stdio",
      "command": "xcrun",
      "args": ["mcpbridge"]
    },
    "chrome-devtools": { ... },
    "figma": { ... },
    "notion": { ... }
  }
}
```

This gives subagents access via `mcp__plugin_pilot_xcode__*` tool prefix, consistent with other plugin MCP tools.

---

## §7: Files Affected

| File | Change Type | Description |
|------|-------------|-------------|
| `.mcp.json` | MODIFY | Add xcode MCP server |
| `skills/pilot/references/phases.md` | MODIFY | §2 PLAN changes + §5 VISUAL_CHECK iOS path + gate expansion |
| `agents/implementer.md` | MODIFY | §3 tool chain + MCP-mode TDD flow + XCUITest section |
| `agents/code-reviewer.md` | MODIFY | §4 tool chain + iOS QA path + qaMethod field |
| `scripts/validate-code-review.sh` | MODIFY | Accept new qaMethod field |

Not changed:
- `hooks/hooks.json` — no new hooks
- `skills/pilot/SKILL.md` — entry point unchanged
- `agents/tech-designer.md` / `agents/design-reviewer.md` — not involved in verification
- iOS project files — project already has Xcode MCP config + XCUITest conventions

---

## §8: Boundary Conditions

| Condition | Handling |
|-----------|----------|
| Xcode not installed / `xcrun mcpbridge` unavailable | PLAN health check fallback to CLI (`make build`), `xcodeMcp: false`, `verificationMode: "bash"` |
| No booted simulator | VISUAL_CHECK boots one: `xcrun simctl boot "iPhone 16"`, leaves running |
| XCUITest navigation fails | `visual-review.json` → `SKIPPED + reason`, pipeline continues |
| Android project | Not covered in this design. `uiChange` pattern matching reserved for `.kt/.xml` (future) |
| Web-hybrid project | Behavior completely unchanged — existing Chrome DevTools path |
| Project has no UITests/ directory | `testInfra.ui: null`, uiChange+TESTABLE steps write XCUITest in new UITests/ dir following project conventions |
| RenderPreview unavailable (UIKit without PreviewProvider) | Code-reviewer skips RenderPreview, relies on test results + VISUAL_CHECK |
