# agent-dev

Autonomous development pipeline for Claude Code: Notion requirement → draft PR.

## What it does

Takes a Notion requirement URL and autonomously:
1. **Fetches** requirements from Notion (+ Figma designs if linked)
2. **Designs** technical approach by analyzing the codebase
3. **Reviews** the design independently (separate Opus session, anti-sycophancy)
4. **Plans** atomic implementation steps with pattern references
5. **Implements** code via dedicated subagent with JIT file reading
6. **Reviews** code + visual design fidelity against Figma
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
  │                    │              @tech-designer (Sonnet)       │
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
  │                    │  break design into   │                    │
  │                    │  steps with:         │                    │
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
  │                    │  · design sections    │                    │
  │                    │  · cross-project ctx  │                    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @implementer (Sonnet)         │
  │                    │              fresh context per project     │
  │                    │                      │                    │
  │                    │              step 1: read convention files │
  │                    │              ┌───────┴───────┐            │
  │                    │              │ For each step │            │
  │                    │              │  1. read patternRef        │
  │                    │              │  2. read dependencies      │
  │                    │              │  3. read target files      │
  │                    │              │  4. implement (JIT)        │
  │                    │              │  5. verify (tsc/lint)      │
  │                    │              │  6. git commit             │
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
  │                    ├── spawn ─────────────>│                    │
  │                    │              @code-reviewer (Opus)         │
  │                    │              read convention files         │
  │                    │              git diff, run tests + lint    │
  │                    │              check AC coverage             │
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
  │                    │  gate: figma? + web-hybrid? + .vue?        │
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
  │                │  tsc + lint verify│                           │
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
  │           │ write telemetry        │                            │
  │           │ archive artifacts      │                            │
  │           │ write cross-project    │                            │
  │           │   summary.md           │                            │
  │           │ advance queue index    │                            │
  │           │ reset per-project      │                            │
  │           │   fields               │                            │
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

- **4 subagents** with isolated contexts: tech-designer (Sonnet), design-reviewer (Opus), implementer (Sonnet), code-reviewer (Opus)
- **Parent is a pure orchestrator** — never reads/writes project code directly, stays lightweight
- **Context injection** — subagents don't auto-load project docs; parent injects CLAUDE.md inline + .claude/ convention file paths into implementer/code-reviewer prompts
- **Multi-project support** — auto-transitions between projects in queue (e.g., web → iOS → Android)
- **JIT implementation** — implementer reads real code before each step, not predictions from design phase
- **Design review** in isolated Opus context (anti-sycophancy by architecture)
- **Visual check** compares Figma screenshots vs browser screenshots using vision (mandatory when gate passes, cannot silently skip)
- **Quality gates** — PLAN verifies commands work, code-reviewer checks plan coverage, tests are explicit steps
- **Gate scripts** enforce pipeline ordering (exit code 2 blocks)
- **State persistence** in `.agent-dev/state.json` for crash recovery

## Design Principles

1. **Scripts > Prompts** — Critical gates enforced by hook scripts, not prompt instructions
2. **Architecture decisions upfront, implementation JIT** — tech-designer decides WHAT, implementer discovers HOW by reading real code
3. **Context isolation** — Each subagent gets fresh context; parent never accumulates implementation details
4. **Explicit context injection** — Subagents don't inherit project docs; parent discovers .claude/ files in PLAN and injects them into subagent prompts
5. **Cross-project knowledge transfer** — `cross-project-summary.md` carries API contracts and design decisions between projects
6. **Plan = contract** — Code-reviewer verifies every planned step was implemented (PLAN_COVERAGE); tests in design must become plan steps
7. **MCP-first integration** — Notion/Figma/Chrome DevTools via MCP, not custom API clients

## Telemetry

Every pipeline run is scored (0-100) and logged to `~/.agent-dev-telemetry.tsv`:
- Completion: 40 pts
- Low interventions: 30 pts (0 human asks = 30, each -10)
- Design first-pass: 15 pts (1 round = 15, each extra -5)
- Code review first-pass: 15 pts (1 round = 15, each extra -5)

## License

MIT
