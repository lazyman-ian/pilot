---
name: pilot
description: >
  Autonomous development pipeline: Notion requirement → draft PR.
  Trigger when: user says "pilot", "agent-dev", provides Notion URL for implementation,
  asks to "build from ticket", "implement this requirement", "从需求开发",
  "自动开发", "开发流水线". Also trigger on /pilot slash command.
user-invocable: true
argument-hint: "<notion-url> | resume | status | clean"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, LSP, Agent, mcp__plugin_pilot_chrome-devtools__*, mcp__plugin_pilot_figma__*, mcp__claude_ai_Notion__*
---

# pilot: Autonomous Development Pipeline

You orchestrate a 7-phase pipeline. Detailed phase instructions are in
`${CLAUDE_SKILL_DIR}/references/phases.md` — read it when starting a pipeline
or resuming after compaction.

## Pipeline Overview

| Phase | 执行者 | 文件产出 |
|-------|--------|---------|
| 1. Fetch | **YOU** (Notion/Figma MCP) | `.pilot/requirement.json` |
| 1.5 Resolve | **YOU** | state.json (projectDir) |
| 2. Design | @pilot:tech-designer → **YOU write file** | `.pilot/tech-design.md` |
| 3. Review | @pilot:design-reviewer → **YOU write file** | `.pilot/review.json` |
| 4. Plan | **YOU** | `.pilot/plan.json` + git branch |
| 5. Implement | @pilot:implementer → **YOU update state** | code + per-step commits |
| 6a. Code Review | @pilot:code-reviewer → **YOU write file** | `.pilot/code-review.json` |
| 6b. Visual Check | **YOU** (Figma + Chrome DevTools MCP, conditional) | `.pilot/visual-review.json` |
| 7. PR | **YOU** | draft PR |

Phase 1/1.5/4/7: YOU execute directly.
Phase 2/3/5/6: Subagent executes, YOU persist result to file immediately.

## Subagent Namespace

Plugin agents use namespace prefix. Always use:
- `@pilot:tech-designer` (NOT `@tech-designer`)
- `@pilot:design-reviewer` (NOT `@design-reviewer`)
- `@pilot:implementer` (NOT `@implementer`)
- `@pilot:code-reviewer` (NOT `@code-reviewer`)

## Monorepo Project Map

```
~/housesigma/                      (NOT a git repo)
├── web-hybrid/                    (git repo: Vue 3, pnpm, TS)
├── housesigma-ios-native/         (git repo: Swift 6+, SwiftUI)
├── housesigma-android-native/     (git repo: Kotlin, Gradle)
└── realagent-datafeed/            (git repo: PHP, Phalcon)
```

Each sub-project is an independent git repo.
The monorepo root is NOT a git repo — you cannot create branches there.

## Entry Points

- `/pilot <notion-url>` — Start new pipeline
- `/pilot resume` — Resume from state.json
- `/pilot status` — Show pipeline state
- `/pilot clean` — Delete .pilot/

**Recommended**: run from the target project directory (e.g., `cd web-hybrid && claude`).
This loads the project's `.claude/` hooks, rules, skills, and steering docs, which significantly
improves code quality during implementation (e.g., auto lint-fix, coding conventions enforcement).

## Critical Rules

1. **File persistence**: After EVERY subagent completes, IMMEDIATELY write its output
   to a file in `.pilot/`. Never rely on context memory for subagent results.
2. **state.json is source of truth**: Update at EVERY phase transition BEFORE starting next phase.
3. **Never skip review for standard/complex tasks**: @pilot:design-reviewer runs in separate context for objectivity. Simple tasks (routed by RESOLVE) skip DESIGN+REVIEW by design.
4. **Each step = one commit**: Atomic undo points.
5. **PR is ALWAYS draft**: Never merge.
6. **After compaction**: Read `state.json` + `plan.json` to resume. Do NOT ask the user.
7. **NEVER STOP TO ASK THE USER** unless review ESCALATES or an unrecoverable error occurs. Do NOT ask "is this correct?", "should I continue?", "does this look right?". Just log a summary and proceed to the next phase in the SAME turn. The pipeline is fully autonomous.

## File Persistence Protocol

ALL artifacts live in `<CWD>/.pilot/`. CWD is wherever you started the pipeline
(monorepo root or sub-project directory — both are valid).
Code changes target `projectDir` via absolute paths. Artifacts stay in CWD.

```
.pilot/                    ← always in CWD
├── state.json                 ← pipeline state machine
├── requirement.json           ← Phase 1 output (shared across projects)
├── cross-project-summary.md   ← accumulated cross-project decisions (multi-project only)
├── tech-design.md             ← Phase 2 output (current project)
├── review.json                ← Phase 3 output (current project)
├── plan.json                  ← Phase 4 output (current project)
├── code-review.json           ← Phase 6a output (current project)
├── visual-review.json         ← Phase 6b output (conditional)
└── completed/                 ← archived artifacts from completed projects
    ├── web-hybrid.tech-design.md
    └── web-hybrid.code-review.json
```

After each subagent returns, YOU write its output to `.pilot/` immediately.

## How to Start or Resume

```
1. Search for .pilot/state.json in CWD and known project dirs
2. If found with phase != COMPLETED/FAILED:
   → Read state.json to get current phase and projectDir
   → Read phases.md for that phase's instructions
   → CONTINUE the pipeline (do not ask user)
3. If not found:
   → Read phases.md for Phase 1 instructions
   → Start fresh pipeline
```

## State Schema

`.pilot/state.json`:
```json
{
  "pipelineId": "pipeline-<timestamp>",
  "sessionId": null,
  "notionUrl": "https://...",
  "phase": "FETCH|RESOLVE|DESIGN|REVIEW|ESCALATED|PLAN|IMPLEMENT|CODE_REVIEW|VISUAL_CHECK|PR|PROJECT_TRANSITION|COMPLETED|FAILED",

  "complexity": "simple|standard|complex",
  "projectQueue": ["web-hybrid", "housesigma-ios-native"],
  "currentProjectIndex": 0,
  "completedProjects": [],

  "targetProject": "web-hybrid",
  "projectDir": "/absolute/path/to/project",
  "branch": "feat/<slug>",
  "baseBranch": "main",
  "reviewConfidence": null,
  "reviewRevisionCount": 0,
  "codeReviewConfidence": null,
  "codeReviewCount": 0,
  "currentStep": null,
  "completedSteps": [],
  "prUrl": null,
  "error": null,

  "metrics": {
    "interventions": 0,
    "completedAt": null
  },
  "createdAt": "<ISO8601>",
  "updatedAt": "<ISO8601>"
}
```

## Resolved Plugin Paths

These are resolved at load time — use them when phases.md needs plugin paths:
- **Scripts directory**: `${CLAUDE_PLUGIN_ROOT}/scripts`
- **Plugin version file**: `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`

During Phase 1 (FETCH), persist these resolved paths into `state.json` as `pluginScriptsDir` and read version into `pluginVersion`. Telemetry and other scripts read from state.json — never reference `${CLAUDE_PLUGIN_ROOT}` in Bash commands.

## Phase Instructions

Read `${CLAUDE_SKILL_DIR}/references/phases.md` for detailed phase-by-phase instructions.
Always read it at pipeline start and after any context compaction.
