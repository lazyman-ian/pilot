# agent-dev

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
claude plugin install github:housesigma/agent-dev

# Local development
claude --plugin-dir /path/to/agent-dev
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
/agent-dev https://notion.so/your-requirement-page

# Resume interrupted pipeline
/agent-dev resume

# Check pipeline status
/agent-dev status

# Clean up pipeline artifacts
/agent-dev clean
```

## Pipeline Sequence Diagram

```
═══════════════════════════════════════════════════════════════════════
                    agent-dev v1.4.0 Pipeline
═══════════════════════════════════════════════════════════════════════

 User                Parent               Subagents            External
  │                    │                      │                    │
  │  /agent-dev <url>  │                      │                    │
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
  │                    │   (max 2 rounds) │   │                    │
  │                    │   parent fixes   │   │                    │
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
- **Parent is a pure orchestrator** — never reads/writes project code directly, stays lightweight
- **Context injection** — subagents don't auto-load project docs; parent injects CLAUDE.md inline + conventionFiles + testInfra + verificationCommand into subagent prompts. All persisted in plan.json for resume safety
- **SDD + BDD hybrid** — architecture decisions in DESIGN (SDD), TDD for testable steps in IMPLEMENT (BDD). Steps classified TESTABLE vs VERIFY_ONLY during PLAN
- **TDD with anchor set** — TESTABLE steps: write test first (RED) → implement (GREEN) → run all anchors (regression check). Based on AlphaCodium test anchor pattern
- **Multi-project support** — auto-transitions between projects in queue; per-project timing/metrics reset on transition
- **Design review** in isolated Opus context (anti-sycophancy by architecture)
- **Visual check** compares Figma screenshots vs browser screenshots (gate: .vue/.scss/.css via merge-base; mandatory when gate passes; writes SKIPPED verdict if can't complete)
- **Quality gates** — PLAN verifies commands work (dry-run); code-reviewer checks PLAN_COVERAGE + TEST_COVERAGE; APPROVE requires test+lint PASS
- **Gate scripts** enforce pipeline ordering (exit code 2 blocks)
- **State persistence** in `.agent-dev/state.json` + plan.json for crash recovery

## Design Principles

1. **Scripts > Prompts** — Critical gates enforced by hook scripts, not prompt instructions
2. **Architecture decisions upfront, implementation JIT** — tech-designer decides WHAT, implementer discovers HOW by reading real code
3. **SDD + BDD** — Specifications drive design, behavior tests drive implementation. TESTABLE steps use RED→GREEN TDD; VERIFY_ONLY steps use build verification
4. **Context isolation** — Each subagent gets fresh context; parent never accumulates implementation details
5. **Explicit context injection** — Subagents don't inherit project docs; parent discovers .claude/ files in PLAN and injects them. Validated commands persist in plan.json
6. **Cross-project knowledge transfer** — `cross-project-summary.md` carries API contracts and design decisions between projects
7. **Plan = contract** — Code-reviewer verifies every planned step was implemented (PLAN_COVERAGE) and every testable step has tests (TEST_COVERAGE)
8. **MCP-first integration** — Notion/Figma/Chrome DevTools via MCP, not custom API clients

## Telemetry

Every pipeline run is scored (0-100) and logged to `~/.agent-dev-telemetry.tsv`:
- Completion: 40 pts
- Low interventions: 30 pts (0 human asks = 30, each -10)
- Design first-pass: 15 pts (1 round = 15, each extra -5)
- Code review first-pass: 15 pts (1 round = 15, each extra -5)

## License

MIT
