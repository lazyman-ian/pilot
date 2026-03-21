# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code **plugin** (`claude plugin install github:housesigma/agent-dev`) that adds an autonomous development pipeline. Given a Notion requirement URL, it autonomously fetches requirements, designs a technical approach, reviews the design, implements code, reviews the code, and creates a draft PR — all without human intervention unless escalation is needed.

## Project Structure

```
.claude-plugin/plugin.json   ← Plugin manifest (name, version, metadata)
skills/agent-dev/SKILL.md    ← Main skill definition (entry point, triggers, allowed tools)
skills/agent-dev/references/  ← phases.md (detailed phase instructions), prompts.md
agents/                       ← Subagent definitions (markdown frontmatter + system prompts)
  tech-designer.md            ← Sonnet, READ-ONLY, generates tech design
  design-reviewer.md          ← Opus, READ-ONLY, skeptical independent review
  implementer.md              ← Sonnet, R/W, JIT step-by-step implementation
  code-reviewer.md            ← Opus, has Bash, runs tests + reviews code
hooks/hooks.json              ← Hook definitions (SessionStart, PreToolUse, PostToolUse, etc.)
hooks/stop-hook.sh            ← Prevents pipeline session from stopping mid-pipeline
scripts/                      ← Shell scripts for gates, health checks, context recovery
  agent-dev-gate.sh           ← Pipeline gate enforcement (exit 2 = block)
  check-deps.sh               ← SessionStart dependency check (warns, never blocks)
  patch-state-session.sh      ← Auto-injects sessionId into state.json on Write
  post-compact-resume.sh      ← PostCompact hook: restores pipeline context after compaction
  health-check.sh             ← Detects stalled pipelines, sends macOS notifications
  write-telemetry.sh          ← Appends pipeline run metrics to ~/.agent-dev-telemetry.tsv
.mcp.json                     ← MCP server config (Notion, Figma, Chrome DevTools)
.lsp.json                     ← LSP server config (TypeScript, Swift, Kotlin, PHP)
```

## Architecture

### Pipeline: 8 Phases

FETCH → RESOLVE → DESIGN → REVIEW → PLAN → IMPLEMENT → CODE_REVIEW (+VISUAL_CHECK) → PR [→ PROJECT_TRANSITION → repeat]

- **Parent agent** (lightweight orchestrator) executes phases 1, 1.5, 4, 7, 8 directly
- **Subagents** execute phases 2, 3, 5, 6 — parent MUST persist their output to `.agent-dev/` files immediately
- State machine in `.agent-dev/state.json` tracks progress; all artifacts live in CWD's `.agent-dev/`
- **Multi-project**: after PR, pipeline auto-transitions to next project in queue via PROJECT_TRANSITION

### Context Boundary Design

Agents are split by **what context they need**, not by role:
- `tech-designer` (Sonnet): needs codebase read access, produces architecture-level design
- `design-reviewer` (Opus): isolated context for anti-sycophancy — reviews design independently
- `implementer` (Sonnet): fresh context per project, JIT file reading per step — keeps parent lightweight
- `code-reviewer` (Opus): needs Bash for tests/lint, reviews implementation against requirements
- Parent is a pure orchestrator — never reads/writes project code directly

### Enforcement: Scripts > Prompts

Critical gates are enforced by hook scripts with `exit 2` (block), not by prompt instructions:
- **Pre-PR gate** (`agent-dev-gate.sh pre-pr`): blocks `gh pr create` unless pipeline is in PR phase
- **Stop hook** (`stop-hook.sh`): prevents session exit mid-pipeline (session-isolated, anti-loop with 3-attempt limit)
- **Session patching** (`patch-state-session.sh`): auto-injects `sessionId` on every `state.json` write
- **Post-compact resume** (`post-compact-resume.sh`): restores pipeline context after context compaction

### MCP Integration

Notion, Figma, and Chrome DevTools are accessed via MCP. MCP auth does NOT propagate to subagents — the parent does FETCH directly.

### Telemetry

Every pipeline run appends a row to `~/.agent-dev-telemetry.tsv` (autoresearch-inspired experiment log).

**Score formula** (0-100):
- Completion: 40 pts (ran to COMPLETED)
- Low interventions: 30 pts (0 human asks = 30, each -10)
- Design first-pass: 15 pts (1 round = 15, each extra round -5)
- Code review first-pass: 15 pts (1 round = 15, each extra round -5)

`state.json` tracks `metrics.interventions` (incremented on ESCALATE or user-ask) and `metrics.completedAt`. The `write-telemetry.sh` script computes the score and writes the TSV row.

## Development

### Testing

No automated test suite. Testing is manual — run the pipeline against a Notion URL and verify each phase. Test results are recorded in `TEST-RESULTS-v*.md` files.

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

Each sub-project is an independent git repo. The monorepo root is NOT a git repo. `.agent-dev/` artifacts always live in CWD (monorepo root), never inside sub-projects.

## Key Conventions

- **Commit format**: `type(scope): description` (imperative, lowercase, no period, <72 chars)
- **Branch naming**: `feat/<slug>` or `fix/<slug>` from requirement title
- **Pipeline is fully autonomous**: never stops to ask the user unless review ESCALATES or unrecoverable error
- **Each implementation step = one commit**: atomic undo points
- **PRs are always draft**: never merge automatically
- **Subagent namespace**: always use `@agent-dev:tech-designer` (with plugin prefix), not `@tech-designer`
- **LSP caveat**: do NOT use LSP on `.vue` files (hangs); only use on `.ts/.js/.tsx/.jsx`
