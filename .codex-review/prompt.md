You are reviewing the **pilot** Claude Code plugin — an autonomous development pipeline (Notion requirement → draft PR) using 4 Opus subagents.

## Task
Read CLAUDE.md and skills/pilot/references/phases.md first for full architecture context, then review all source files thoroughly.

## What to look for
1. **Correctness**: Logic errors, broken control flow, wrong variable references, state machine violations
2. **Consistency**: Contradictions between SKILL.md, phases.md, agent definitions, and scripts. Mismatched field/phase names across files
3. **Edge cases**: Missing error handling, unhandled states, null/empty checks, boundary conditions
4. **Convention**: Shell scripts missing set -euo pipefail, inconsistent quoting, hardcoded paths that should be variables
5. **Security**: Command injection via unquoted variables, secrets in plain text, unsafe eval
6. **Performance**: Unnecessary file reads, redundant operations

## Rules
- Only report REAL issues, not style preferences or hypothetical improvements
- Each issue must include a concrete suggestion for how to fix it
- If uncertain, mark severity as "low" and explain your uncertainty
- Do NOT suggest feature additions or speculative refactoring
