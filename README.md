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
  │                    │<─── Problem+Solution+ACs ────────────────│
  │                    ├──── Figma MCP ──────────────────────────>│
  │                    │<─── design tokens ──────────────────────-│
  │                    │                      │                    │
  │                    │  >> requirement.json  │                    │
  │                    │  >> state.json        │                    │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 1.5: RESOLVE   │          │                    │
  │        │  (Parent)             │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    │  build projectQueue   │                    │
  │                    │  set targetProject    │                    │
  │                    │  verify git + deps    │                    │
  │                    │                      │                    │
  │     ┌──────────────┴──────────────────────┴────────┐           │
  │     │         FOR EACH PROJECT IN QUEUE             │           │
  │     └──────────────┬──────────────────────┬────────┘           │
  │                    │                      │                    │
  │        ┌───────────┴───────────┐          │                    │
  │        │  Phase 2: DESIGN      │          │                    │
  │        └───────────┬───────────┘          │                    │
  │                    ├── spawn ─────────────>│                    │
  │                    │              @tech-designer (Sonnet)       │
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
  │                    │              independent skeptical review  │
  │                    │<── VERDICT ──────────│                    │
  │                    │                      │                    │
  │                    ├─── APPROVE ──────> Phase 4                │
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
  │                    ├── spawn ─────────────>│                    │
  │                    │              @implementer (Sonnet)         │
  │                    │              fresh context per project     │
  │                    │                      │                    │
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
  │                    ├── spawn ─────────────>│                    │
  │                    │              @code-reviewer (Opus)         │
  │                    │              git diff, run tests + lint    │
  │                    │              check AC coverage             │
  │                    │<── VERDICT ──────────│                    │
  │                    │                      │                    │
  │                    ├─── APPROVE ──────> gate check             │
  │                    │                      │                    │
  │                    ├─── FIX_REQUIRED ─┐   │                    │
  │                    │   (max 2 rounds) │   │                    │
  │                    │   parent fixes   │   │                    │
  │                    │<─────────────────┘   │                    │
  │                    │  re-invoke reviewer  │                    │
  │                    │                      │                    │
  │                    ├─── VISUAL_CHECK gate ─────────────────────│
  │                    │   figma? + web? + .vue?                   │
  │                    │                      │                    │
  │              ┌─ ALL TRUE ─┐        ┌─ ANY FALSE ─┐            │
  │              │            │        │             │             │
  │              ▼            │        │             ▼             │
  │  ┌───────────────────┐   │        │     skip to Phase 7       │
  │  │ Phase 6b: VISUAL  │   │        │                           │
  │  └─────────┬─────────┘   │        │                           │
  │            │              │        │                           │
  │            ├── Figma MCP: get_screenshot ─────────────────────>│
  │            │<── design screenshot ────────────────────────────-│
  │            ├── Chrome DevTools: take_screenshot ──────────────>│
  │            │<── browser screenshot ──────────────────────────-─│
  │            │                      │                            │
  │            │  vision compare      │                            │
  │            │                      │                            │
  │            ├── MATCH ────────────────> Phase 7                 │
  │            ├── PARTIAL (minor) ──────> Phase 7                 │
  │            │                      │                            │
  │            └── MISMATCH           │                            │
  │                │                  │                            │
  │                │  fix CSS/template│                            │
  │                │  run tsc + lint  │                            │
  │                │  git commit      │                            │
  │                │  re-capture      │                            │
  │                │  re-compare      │                            │
  │                │                  │                            │
  │                ├── MATCH ────────────> Phase 7                 │
  │                └── still MISMATCH ──> Phase 7 (with notes)     │
  │                    │              │                            │
  │        ┌───────────┴───────────┐  │                            │
  │        │  Phase 7: PR          │  │                            │
  │        └───────────┬───────────┘  │                            │
  │                    ├── git push ──────────────────────────────>│
  │                    ├── gh pr create --draft ──────────────────>│
  │                    │<── PR URL ──────────────────────────────-─│
  │                    │  write telemetry     │                    │
  │                    │                      │                    │
  │                    ├─── more projects? ───┤                    │
  │                    │                      │                    │
  │              ┌── YES ──┐           ┌── NO ──┐                  │
  │              │         │           │        │                  │
  │              ▼         │           │        ▼                  │
  │  ┌──────────────────┐ │           │  COMPLETED                │
  │  │Phase 8: TRANSITION│ │          │  report all PRs            │
  │  └────────┬─────────┘ │           │                            │
  │           │            │           │                            │
  │           │ archive artifacts      │                            │
  │           │ write cross-project    │                            │
  │           │   summary.md           │                            │
  │           │ advance queue index    │                            │
  │           │ reset per-project      │                            │
  │           │   fields               │                            │
  │           │            │           │                            │
  │           └── loop back to Phase 2: DESIGN ──────>             │
  │     └──────────────────────────────────────────────┘           │
  │                    │                      │                    │
  │  "Pipeline 完成"  <│                      │                    │
  │  PRs + scores      │                      │                    │
  ▼                    ▼                      ▼                    ▼

Legend:
  ──>     sync call / trigger
  >> file write artifact to disk
  spawn   create subagent (isolated context)
  ─┐ ─┘   loop / retry
```

## Architecture

- **4 subagents** with isolated contexts: tech-designer (Sonnet), design-reviewer (Opus), implementer (Sonnet), code-reviewer (Opus)
- **Parent is a pure orchestrator** — never reads/writes project code directly, stays lightweight
- **Multi-project support** — auto-transitions between projects in queue (e.g., web → iOS → Android)
- **JIT implementation** — implementer reads real code before each step, not predictions from design phase
- **Design review** in isolated Opus context (anti-sycophancy by architecture)
- **Visual check** compares Figma screenshots vs browser screenshots using vision
- **Gate scripts** enforce pipeline ordering (exit code 2 blocks)
- **State persistence** in `.agent-dev/state.json` for crash recovery

## Design Principles

1. **Scripts > Prompts** — Critical gates enforced by hook scripts, not prompt instructions
2. **Architecture decisions upfront, implementation JIT** — tech-designer decides WHAT, implementer discovers HOW by reading real code
3. **Context isolation** — Each subagent gets fresh context; parent never accumulates implementation details
4. **Cross-project knowledge transfer** — `cross-project-summary.md` carries API contracts and design decisions between projects
5. **MCP-first integration** — Notion/Figma/Chrome DevTools via MCP, not custom API clients

## Telemetry

Every pipeline run is scored (0-100) and logged to `~/.agent-dev-telemetry.tsv`:
- Completion: 40 pts
- Low interventions: 30 pts (0 human asks = 30, each -10)
- Design first-pass: 15 pts (1 round = 15, each extra -5)
- Code review first-pass: 15 pts (1 round = 15, each extra -5)

## License

MIT
