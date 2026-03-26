# pilot

Autonomous development pipeline for Claude Code: Notion requirement → draft PR.

## What it does

Takes a Notion requirement URL and autonomously:
1. **Fetches** requirements from Notion (+ Figma designs if linked)
2. **Designs** technical approach (Opus) with testable components table
3. **Reviews** the design independently (separate Opus session, anti-sycophancy)
4. **Plans** steps with testability classification, pattern refs, and verified commands
5. **Implements** via TDD for testable steps (RED→GREEN + anchor set) and JIT for verify-only steps
6. **Reviews** code (plan coverage + test coverage) + visual design fidelity against Figma
7. **Creates** a draft PR, then auto-continues to next project in queue

Fully autonomous — human only intervenes on review ESCALATION or at the end (PR review).

## Installation

```bash
# From GitHub
claude plugin install github:housesigma/pilot

# Local development
claude --plugin-dir /path/to/pilot
```

## Prerequisites

- Claude Code with Opus model
- Notion MCP access (OAuth — first use triggers browser auth)
- Figma MCP access (optional, for design-linked requirements)
- `gh` CLI authenticated for PR creation
- `jq` for pipeline gate checks

## Usage

```bash
# Start pipeline with Notion URL
/pilot https://notion.so/your-requirement-page

# Resume interrupted pipeline
/pilot resume

# Check pipeline status
/pilot status

# Clean up pipeline artifacts
/pilot clean
```

## Pipeline Sequence Diagram

```
═══════════════════════════════════════════════════════════════════════
                    pilot v1.6.0 Pipeline
═══════════════════════════════════════════════════════════════════════

 User                Parent               Subagents            External
  │                    │                      │                    │
  │  /pilot <url>  │                      │                    │
  ├───────────────────>│                      │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 1: FETCH       │          │                    │
  │        │  (Parent + MCP)       │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    ├──── Notion MCP ──────────────────────────>│
  │                    │<─── Problem → Solution → Design ─────────│
  │                    ├──── Figma MCP ──────────────────────────>│
  │                    │<─── component hierarchy + tokens ────────│
  │                    │                      │                    │
  │                    │  >> requirement.json  │                    │
  │                    │  >> state.json        │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 1.5: RESOLVE   │          │                    │
  │        │  (Parent)             │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  verify affected projects                  │
  │                    │  build projectQueue (ordered by dep)       │
  │                    │  set targetProject = queue[0]              │
  │                    │  verify git status + deps                  │
  │                    │                      │                    │
  │  ┌─────────────────┴──────────────────────┴───────────────┐    │
  │  │              FOR EACH PROJECT IN QUEUE                  │    │
  │  └─────────────────┬──────────────────────┬───────────────┘    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 2: DESIGN      │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  + cross-project-summary.md (if exists)    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @tech-designer (Opus)       │
  │                    │              reads CLAUDE.md + .claude/    │
  │                    │              reads codebase, LSP verify    │
  │                    │              produces architecture +       │
  │                    │              pattern refs + side effects   │
  │                    │<── tech-design.md ───│                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 3: REVIEW      │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @design-reviewer (Opus)       │
  │                    │              reads CLAUDE.md + .claude/    │
  │                    │              independent skeptical review  │
  │                    │<── VERDICT ──────────│                    │
  │                    │                      │                    │
  │                    ├─── APPROVE (≥60) ─────────> Phase 4       │
  │                    │                      │                    │
  │                    ├─── REVISE ───┐       │                    │
  │                    │              │ (max 3 rounds)              │
  │                    │<─────────────┘       │                    │
  │                    │  re-spawn designer   │                    │
  │                    │  with review feedback│                    │
  │                    │                      │                    │
  │  issues + ask  <───├─── ESCALATE          │                    │
  ├─── direction ─────>│                      │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 4: PLAN        │          │                    │
  │        │  (Parent)             │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  read CLAUDE.md      │                    │
  │                    │  glob .claude/rules/ │                    │
  │                    │    + .claude/steering/│                    │
  │                    │  verify commands work │                    │
  │                    │  detect test infra   │                    │
  │                    │  break design into   │                    │
  │                    │  steps with:         │                    │
  │                    │  - testability       │                    │
  │                    │  - testSpec (if any) │                    │
  │                    │  - designSection     │                    │
  │                    │  - patternRef        │                    │
  │                    │  - dependsOn         │                    │
  │                    │  - verification      │                    │
  │                    │                      │                    │
  │                    │  >> plan.json        │                    │
  │                    │  git checkout -b     │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 5: IMPLEMENT   │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  inject into prompt:  │                    │
  │                    │  · CLAUDE.md (inline) │                    │
  │                    │  · convention paths   │                    │
  │                    │  · testInfra          │                    │
  │                    │  · design sections    │                    │
  │                    │  · cross-project ctx  │                    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @implementer (Opus)           │
  │                    │              fresh context per project     │
  │                    │                      │                    │
  │                    │              step 1: read convention files │
  │                    │              ┌───────┴───────┐            │
  │                    │              │ For each step │            │
  │                    │              │                            │
  │                    │              │ TESTABLE:                  │
  │                    │              │  1. write test (RED)       │
  │                    │              │  2. implement (GREEN)      │
  │                    │              │  3. run anchor set         │
  │                    │              │  4. git commit             │
  │                    │              │                            │
  │                    │              │ VERIFY_ONLY:               │
  │                    │              │  1. implement (JIT)        │
  │                    │              │  2. verify (build/lint)    │
  │                    │              │  3. run anchor set         │
  │                    │              │  4. git commit             │
  │                    │              └───────┬───────┘            │
  │                    │                      │                    │
  │                    │<── summary ──────────│                    │
  │                    │   COMPLETED_STEPS    │                    │
  │                    │   ISSUES             │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 6a: CODE_REVIEW│          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  inject into prompt:  │                    │
  │                    │  · CLAUDE.md (inline) │                    │
  │                    │  · convention paths   │                    │
  │                    │  · testInfra + verCmd │                    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @code-reviewer (Opus)         │
  │                    │              read convention files         │
  │                    │              git diff, run tests + lint    │
  │                    │              check AC + plan + test coverage│
  │                    │<── VERDICT ──────────│                    │
  │                    │                      │                    │
  │                    ├─── FIX_REQUIRED ─┐   │                    │
  │                    │   (max 3 rounds) │   │                    │
  │                    │   implementer    │   │                    │
  │                    │   fix mode       │   │                    │
  │                    │<─────────────────┘   │                    │
  │                    │  re-invoke reviewer  │                    │
  │                    │                      │                    │
  │                    ├─── APPROVE ──────> VISUAL_CHECK gate      │
  │                    │                      │                    │
  │                    │  gate: figma? + web? + .vue/.scss/.css?     │
  │                    │                      │                    │
  │              ┌─ ALL TRUE ─┐        ┌─ ANY FALSE ─┐            │
  │              │            │        │             │             │
  │              ▼            │        │             ▼             │
  │  ┌───────────────────┐   │        │     skip to Phase 7       │
  │  │ Phase 6b: VISUAL  │   │        │                           │
  │  │ (MANDATORY)       │   │        │                           │
  │  └─────────┬─────────┘   │        │                           │
  │            │              │        │                           │
  │            │  re-read CLAUDE.md    │                           │
  │            │  + .claude/steering/  │                           │
  │            │  for dev server cmd   │                           │
  │            │              │        │                           │
  │            ├── Figma MCP: get_screenshot ─────────────────────>│
  │            │<── design screenshot ────────────────────────────-│
  │            │              │        │                           │
  │            │  start dev server     │                           │
  │            ├── Chrome DevTools: take_screenshot ──────────────>│
  │            │<── browser screenshot ──────────────────────────-─│
  │            │              │        │                           │
  │            │  vision compare       │                           │
  │            │              │        │                           │
  │            ├── MATCH ─────────────────> Phase 7                │
  │            ├── PARTIAL (minor) ────────> Phase 7               │
  │            │              │        │                           │
  │            └── MISMATCH   │        │                           │
  │                │          │        │                           │
  │                │  fix CSS/template │                           │
  │                │  build + lint     │                           │
  │                │  git commit       │                           │
  │                │  re-capture       │                           │
  │                │  re-compare       │                           │
  │                │  (max 1 round)    │                           │
  │                │          │        │                           │
  │                ├── MATCH ─────────────> Phase 7                │
  │                └── still MISMATCH ───> Phase 7 (with notes)    │
  │                    │      │        │                           │
  │        ┌───────────┴──────┴────────┴──────────┐               │
  │        │  Phase 7: PR                          │               │
  │        └───────────┬──────────────────────────┘               │
  │                    ├── git push ──────────────────────────────>│
  │                    ├── gh pr create --draft ──────────────────>│
  │                    │<── PR URL ──────────────────────────────-─│
  │                    │                      │                    │
  │                    ├─── more projects in queue? ──┐            │
  │                    │                      │       │            │
  │              ┌── YES ──┐           ┌── NO ──┐    │            │
  │              │         │           │        │    │            │
  │              ▼         │           │        ▼    │            │
  │  ┌──────────────────┐ │           │  COMPLETED   │            │
  │  │Phase 8: TRANSITION│ │          │  write telemetry           │
  │  └────────┬─────────┘ │           │  report all PRs            │
  │           │            │           │                            │
  │           │ set completedAt        │                            │
  │           │ write telemetry        │                            │
  │           │ archive artifacts      │                            │
  │           │ write cross-project    │                            │
  │           │   summary.md           │                            │
  │           │ advance queue index    │                            │
  │           │ reset per-project      │                            │
  │           │   fields + timing      │                            │
  │           │            │           │                            │
  │           └── loop back to Phase 2: DESIGN ──────>             │
  │  └─────────────────────────────────────────────────┘           │
  │                    │                      │                    │
  │  "Pipeline 完成"  <│                      │                    │
  │  PRs + scores      │                      │                    │
  ▼                    ▼                      ▼                    ▼

Legend:
  ──>          sync call / trigger
  >> file      write artifact to disk
  spawn        create subagent (isolated context)
  ─┐ ─┘        loop / retry
  inject       parent includes content in subagent prompt
               (subagents don't auto-load project docs)
```

## Architecture

- **4 Opus subagents** with isolated contexts: tech-designer, design-reviewer, implementer, code-reviewer
- **Parent is a pure orchestrator** — never reads/writes project code directly
- **SDD + AC-driven TDD** — specifications drive design, acceptance criteria drive tests. TESTABLE steps use RED→GREEN with anchor set; VERIFY_ONLY steps use build verification
- **Context injection** — subagents don't auto-load project docs; parent injects CLAUDE.md + conventionFiles + validated commands. All persisted in plan.json for resume safety
- **Complexity routing** — simple tasks (≤3 ACs) skip DESIGN+REVIEW for faster turnaround
- **Multi-project** — auto-transitions between projects; per-project metrics reset; cross-project-summary.md carries API contracts
- **Interactive QA** — code-reviewer uses Chrome DevTools MCP for browser-based functional testing (web-hybrid); VISUAL_CHECK retained as fallback
- **Quality gates** — environment health check, RUBRIC_SCORES (4 dimensions × /10, script-enforced consistency), requirement traceability (acRefs), grounding checks, PLAN_COVERAGE, TEST_COVERAGE, baseline-aware test evaluation
- **Gate scripts** — `validate-artifacts.sh` dispatcher routes artifact writes to validators (exit 2 blocks scoring bias, ungrounded assumptions, missing traceability)

## Usage Guide

### Starting a Pipeline

```bash
# Recommended: run from the target project directory
cd ~/housesigma/web-hybrid
claude
/pilot https://notion.so/your-requirement-page

# Or from monorepo root (multi-project)
cd ~/housesigma
claude
/pilot https://notion.so/your-requirement-page
```

### What Happens Next

The pipeline runs fully autonomously. You'll see phase transitions logged:

```
需求: Claim Homes | 平台: web-hybrid, ios, android | AC: 15 条 | Figma: 有
项目: web-hybrid | 分支: feat/claim-homes | 步骤: 8
✅ web-hybrid PR: https://github.com/.../pull/321 (score: 90)
✅ ios PR: https://github.com/.../pull/28 (score: 100)
✅ android PR: https://github.com/.../pull/26 (score: 100)
Pipeline 完成. 清理 .pilot/ 文件？
```

### When It Stops

The pipeline only stops to ask you in three cases:
1. **ESCALATE** — design review or code review has unresolvable issues
2. **Completion** — all PRs created, asks to clean up
3. **Unrecoverable error** — environment broken, MCP auth expired

### Monitoring a Running Pipeline

From another terminal:
```bash
# Check current state
cat ~/housesigma/.pilot/state.json | jq '{phase, targetProject, completedSteps}'

# Watch for stalls (macOS notification after 10 min of no state changes)
cd ~/housesigma && bash /path/to/pilot/scripts/health-check.sh 10

# View telemetry
column -t -s $'\t' ~/.pilot-telemetry.tsv
```

### Resuming After Interruption

```bash
# Automatically detects state.json and continues
/pilot resume

# Or just start Claude in the same directory — post-compact-resume.sh auto-recovers
```

### Pipeline Artifacts

```
.pilot/
├── state.json                 ← pipeline state machine
├── requirement.json           ← fetched requirements (shared)
├── tech-design.md             ← architecture design (current project)
├── review.json                ← design review verdict
├── plan.json                  ← implementation plan with testability + validated commands
├── code-review.json           ← code review with RUBRIC_SCORES
├── visual-review.json         ← visual check result (if applicable)
├── cross-project-summary.md   ← API contracts + decisions (multi-project)
└── completed/                 ← archived per-project artifacts + telemetry markers
```

## Configuration

### For the Plugin (MCP Servers)

`.mcp.json` — automatically loaded by Claude Code:
```json
{
  "mcpServers": {
    "notion": { "command": "npx", "args": ["-y", "@anthropic/notion-mcp"] },
    "figma": { "command": "npx", "args": ["-y", "@anthropic/figma-mcp"] },
    "chrome-devtools": { "command": "npx", "args": ["-y", "@anthropic/chrome-devtools-mcp"] }
  }
}
```

### For Target Projects

Each project customizes pipeline behavior via its own `.claude/` directory:

| Directory | Purpose | Who Reads It |
|-----------|---------|-------------|
| `CLAUDE.md` | Build/test/lint commands, project overview | All subagents (injected by parent) |
| `.claude/rules/*.md` | Coding conventions, must-follow rules | implementer + code-reviewer (injected) |
| `.claude/steering/*.md` | Architecture, tech stack, patterns | implementer + code-reviewer (injected) |
| `.claude/docs/*.md` | Setup, auth flow, environment notes | implementer + code-reviewer (injected) |

**To adopt BDD/Gherkin** in a project: install a BDD framework, add `.claude/rules/testing.md` with BDD conventions, and ensure existing `.feature` files can serve as `testPatternRef`. The pipeline automatically follows whatever test pattern the project uses.

### Telemetry

Pipeline runs are scored and logged to `~/.pilot-telemetry.tsv`:

| Component | Points | Scoring |
|-----------|--------|---------|
| Completion | 40 | Ran to PR/COMPLETED |
| Low interventions | 30 | 0 asks = 30, each -10 |
| Design first-pass | 15 | 1 round = 15, each extra -5; 0 if skipped |
| Code review first-pass | 15 | 1 round = 15, each extra -5 |

```bash
# View telemetry
column -t -s $'\t' ~/.pilot-telemetry.tsv

# Filter by project
grep 'web-hybrid' ~/.pilot-telemetry.tsv | column -t -s $'\t'
```

## Design Principles

1. **Scripts > Prompts** — Critical gates enforced by hook scripts, not prompt instructions
2. **Architecture upfront, implementation JIT** — tech-designer decides WHAT, implementer discovers HOW by reading real code
3. **SDD + AC-driven TDD** — Specifications drive design, acceptance criteria drive tests. Convention-agnostic — projects choose their test framework
4. **Context isolation** — Each subagent gets fresh context; parent never accumulates implementation details
5. **Explicit context injection** — Subagents don't inherit project docs; parent discovers .claude/ files and injects them. Validated commands persist in plan.json
6. **Cross-project knowledge transfer** — `cross-project-summary.md` carries API contracts and design decisions
7. **Plan = contract** — Code-reviewer verifies PLAN_COVERAGE + TEST_COVERAGE + RUBRIC_SCORES
8. **MCP-first** — Notion/Figma/Chrome DevTools via MCP, not custom API clients

## License

MIT
