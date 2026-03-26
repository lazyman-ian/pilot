# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code **plugin** (`claude plugin install github:housesigma/pilot`) that adds an autonomous development pipeline. Given a Notion requirement URL, it autonomously fetches requirements, designs a technical approach, reviews the design, implements code (with TDD for testable steps), reviews the code, and creates a draft PR — all without human intervention unless escalation is needed.

## Project Structure

```
.claude-plugin/plugin.json   ← Plugin manifest (name, version, metadata)
skills/pilot/SKILL.md    ← Main skill definition (entry point, triggers, allowed tools)
skills/pilot/references/  ← phases.md (detailed phase instructions), prompts.md
agents/                       ← Subagent definitions (markdown frontmatter + system prompts)
  tech-designer.md            ← Opus, READ-ONLY, generates tech design + testable components table
  design-reviewer.md          ← Opus, READ-ONLY, skeptical independent review
  implementer.md              ← Opus, R/W, TDD for testable steps + JIT implementation
  code-reviewer.md            ← Opus, has Bash + Chrome DevTools MCP, runs tests + lint + interactive QA + checks plan/test coverage
hooks/hooks.json              ← Hook definitions (SessionStart, PreToolUse, PostToolUse, etc.)
hooks/stop-hook.sh            ← Prevents pipeline session from stopping mid-pipeline
scripts/                      ← Shell scripts for gates, health checks, context recovery
  validate-artifacts.sh       ← PostToolUse(Write) dispatcher — routes to artifact validators
  validate-plan.sh            ← Blocks plan.json if non-scaffolding steps have empty acRefs
  validate-code-review.sh     ← Blocks code-review.json on scoring inconsistencies (FIX_REQUIRED > 72, rubric < 5)
  validate-review.sh          ← Blocks review.json if ungrounded API changes + APPROVE
  agent-dev-gate.sh           ← Pipeline gate enforcement (exit 2 = block)
  check-deps.sh               ← SessionStart dependency check (warns, never blocks)
  patch-state-session.sh      ← (Legacy) sessionId injection — now inlined in validate-artifacts.sh
  post-compact-resume.sh      ← PostCompact hook: restores pipeline context after compaction
  health-check.sh             ← Detects stalled pipelines, sends macOS notifications
  write-telemetry.sh          ← Appends pipeline run metrics to ~/.pilot-telemetry.tsv
.mcp.json                     ← MCP server config (Notion, Figma, Chrome DevTools)
.lsp.json                     ← LSP server config (TypeScript, Swift, Kotlin, PHP)
```

## Architecture

### Pipeline Phases

```
FETCH → RESOLVE → [DESIGN → REVIEW →] PLAN → IMPLEMENT → CODE_REVIEW (+VISUAL_CHECK) → PR [→ PROJECT_TRANSITION → repeat]
```

- Phases in brackets are skipped for **simple** tasks (≤3 ACs, 1-3 files)
- **Parent agent** (lightweight orchestrator) executes FETCH, RESOLVE, PLAN, PR, PROJECT_TRANSITION directly
- **4 Opus subagents** execute DESIGN, REVIEW, IMPLEMENT, CODE_REVIEW — parent persists their output to `.pilot/` files immediately
- State machine in `.pilot/state.json` tracks progress; all artifacts in CWD's `.pilot/`
- **Multi-project**: after PR, auto-transitions to next project in queue via PROJECT_TRANSITION

### Context Boundary Design

Agents are split by **what context they need**, not by role:
- `tech-designer` (Opus): codebase read access, produces architecture design + testable components table — reads project docs itself
- `design-reviewer` (Opus): isolated context for anti-sycophancy — reads project docs itself
- `implementer` (Opus): fresh context per project, TDD (RED→GREEN + anchors) for TESTABLE steps, JIT for VERIFY_ONLY — receives injected project docs from parent
- `code-reviewer` (Opus): Bash for tests/lint — receives injected project docs + validated commands, checks plan/test/AC coverage
- Parent is a pure orchestrator — never reads/writes project code directly

**Subagent context injection**: Subagents don't auto-load project docs. Parent injects CLAUDE.md content inline + .claude/ file paths + validated commands (verificationCommand, lintCommand, testInfra) into implementer/code-reviewer prompts. All persisted in plan.json for resume safety.

### Enforcement: Scripts > Prompts

Critical gates enforced by hook scripts with `exit 2` (block):
- **Pre-PR gate** (`agent-dev-gate.sh pre-pr`): blocks `gh pr create` unless pipeline is in PR phase
- **Stop hook** (`stop-hook.sh`): prevents session exit mid-pipeline (session-isolated, anti-loop with 3-attempt limit)
- **Artifact validation** (`validate-artifacts.sh`): PostToolUse(Write) dispatcher — routes to artifact-specific validators:
  - `validate-plan.sh`: blocks plan.json if any non-scaffolding step has empty `acRefs`
  - `validate-code-review.sh`: blocks code-review.json if FIX_REQUIRED + confidence > 72, rubric < 5 + APPROVE, or confidence diverges from rubric mean
  - `validate-review.sh`: blocks review.json if ungrounded API changes + APPROVE verdict
  - Also inlines session patching for state.json (previously `patch-state-session.sh`)
- **Post-compact resume** (`post-compact-resume.sh`): restores pipeline context after compaction

### Quality Gates

- **PLAN**: environment health check (build + existing tests), command validation (dry-run), test infrastructure detection, step testability classification, convention file discovery. All persist in plan.json
- **Implementer TDD**: TESTABLE steps follow RED→GREEN with anchor set regression protection; VERIFY_ONLY steps use build verification; pre-existing failures exempted via baselineFailures/baselineBuildFailure
- **Code-reviewer**: Double-layer review: Hard Gates (binary pass/fail) then RUBRIC_SCORES (Correctness/Completeness/Convention/Regression each X/10, script-enforced consistency). Interactive QA via Chrome DevTools MCP for web-hybrid (conditional). PLAN_COVERAGE, TEST_COVERAGE, REQUIREMENTS_COVERAGE. Uses validated commands from PLAN (not raw CLAUDE.md). Baseline-aware test evaluation. On FIX_REQUIRED: re-invokes implementer in **fix mode** (not parent) — implementer reconstructs anchor set from git history, addresses issues by severity, commits fix. Max 3 rounds before ESCALATE.
- **VISUAL_CHECK**: mandatory when gate passes (Figma + web-hybrid + .vue/.scss/.css via merge-base); writes visual-review.json even if SKIPPED; post-fix runs build + lint + tests

### Complexity Routing

RESOLVE classifies requirements:
- **Simple** (≤3 ACs, 1-3 files, bug fix): skip DESIGN+REVIEW → PLAN directly
- **Standard** (new feature, multiple components): full pipeline
- **Complex** (multi-project, new architecture): full pipeline

### MCP Integration

Notion, Figma, and Chrome DevTools accessed via MCP. MCP auth does NOT propagate to subagents — parent does FETCH directly.

### Telemetry

Every pipeline run appends a row to `~/.pilot-telemetry.tsv`:

**Score formula** (0-100):
- Completion: 40 pts (ran to COMPLETED/PR/PROJECT_TRANSITION)
- Low interventions: 30 pts (0 human asks = 30, each -10)
- Design first-pass: 15 pts (1 round = 15, each extra -5; 0 if design was skipped)
- Code review first-pass: 15 pts (1 round = 15, each extra -5)

Multi-project: one telemetry row per project (idempotent via marker file). Per-project timing reset on transition.

## Configuration

### MCP Servers (.mcp.json)

```json
{
  "mcpServers": {
    "notion": { "command": "npx", "args": ["-y", "@anthropic/notion-mcp"] },
    "figma": { "command": "npx", "args": ["-y", "@anthropic/figma-mcp"] },
    "chrome-devtools": { "command": "npx", "args": ["-y", "@anthropic/chrome-devtools-mcp"] }
  }
}
```

### LSP Servers (.lsp.json)

```json
{
  "lspServers": {
    "typescript": { "command": "typescript-language-server", "args": ["--stdio"] },
    "swift": { "command": "sourcekit-lsp" },
    "kotlin": { "command": "kotlin-language-server" },
    "php": { "command": "intelephense", "args": ["--stdio"] }
  }
}
```

### Project-Level Configuration

Each target project can customize pipeline behavior via its own `.claude/` directory:

| Directory | Purpose | Effect on Pipeline |
|-----------|---------|-------------------|
| `.claude/rules/*.md` | Coding conventions | Injected into implementer + code-reviewer prompts |
| `.claude/steering/*.md` | Architecture/tech stack docs | Injected into implementer + code-reviewer prompts |
| `.claude/docs/*.md` | Setup, auth, environment notes | Injected into implementer + code-reviewer prompts |
| `CLAUDE.md` | Build/test/lint commands | Injected inline into all subagent prompts |

Projects can adopt BDD (Gherkin) by putting BDD conventions in `.claude/rules/` and having existing `.feature` files as test pattern references — the pipeline is convention-agnostic.

## Development

### Testing

No automated test suite. Testing is manual — run the pipeline against a Notion URL and verify each phase. Test results are recorded in `TEST-RESULTS-v*.md` files.

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

**How to Run**: Pick a completed pipeline run → re-run same `requirement.json` with variant → compare artifacts (`review.json`, `code-review.json`, `git diff`) → record in `.pilot/experiments/<model>-<date>.md`

### Local Development

```bash
# Run Claude Code with this plugin loaded locally
claude --plugin-dir /path/to/agent-dev
```

### Prerequisites

- `jq` — required for gate scripts and state management
- `gh` — required for PR creation
- LSP servers (optional): `typescript-language-server`, `sourcekit-lsp`, `kotlin-language-server`, `intelephense`

### Target Monorepo Layout

The plugin is designed for HouseSigma's monorepo structure:
```
~/housesigma/                      (NOT a git repo)
├── web-hybrid/                    (Vue 3, pnpm, TS)
├── housesigma-ios-native/         (Swift 6+, SwiftUI)
├── housesigma-android-native/     (Kotlin, Gradle)
└── realagent-datafeed/            (PHP, Phalcon)
```

Each sub-project is an independent git repo. The monorepo root is NOT a git repo. `.pilot/` artifacts always live in CWD, never inside sub-projects.

## Key Conventions

- **Commit format**: `type(scope): description` (imperative, lowercase, no period, <72 chars)
- **Branch naming**: `feat/<slug>` or `fix/<slug>` from requirement title
- **Pipeline is fully autonomous**: never stops to ask the user unless review ESCALATES or unrecoverable error
- **Each implementation step = one commit**: atomic undo points (test + code together for TESTABLE steps)
- **PRs are always draft**: never merge automatically
- **Subagent namespace**: always use `@pilot:tech-designer` (with plugin prefix), not `@tech-designer`
- **LSP caveat**: do NOT use LSP on `.vue` files (hangs); only use on `.ts/.js/.tsx/.jsx`
