# agent-dev

Autonomous development pipeline for Claude Code: Notion requirement → draft PR.

## What it does

Takes a Notion requirement URL and autonomously:
1. **Fetches** requirements from Notion (+ Figma designs if linked)
2. **Designs** technical approach by analyzing the codebase
3. **Reviews** the design independently (separate Opus session, anti-sycophancy)
4. **Plans** atomic implementation steps
5. **Implements** code changes with per-step commits
6. **Reviews** the code independently before PR
7. **Creates** a draft PR with full context

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

## Architecture

- **3 subagents** with runtime-enforced tool restrictions (tech-designer, design-reviewer, code-reviewer)
- **Design review** in isolated Opus context (anti-sycophancy by architecture)
- **Gate scripts** enforce pipeline ordering (can't implement without review, can't PR without tests)
- **Parent agent** handles planning and implementation (best continuous context)
- **State persistence** in `.agent-dev/state.json` for crash recovery

## Design Principles

1. **Scripts > Prompts** — Critical gates enforced by hook scripts (exit code 2), not prompt instructions
2. **Context Boundary splitting** — Agents split by what context they need, not by "role"
3. **No parallel code writing** — Sequential implementation preserves context continuity
4. **MCP-first integration** — Notion/Figma via MCP, not custom API clients

## License

MIT
