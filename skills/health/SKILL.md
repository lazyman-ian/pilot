---
name: health
description: Audit Claude Code config health. Use when: Claude feels off, ignores rules, reviewing config, or user says "审查配置"/"review config"/"check my setup".
---

# Claude Code Configuration Health Audit

Audit the current project's Claude Code setup with the six-layer framework:
`CLAUDE.md → rules → skills → hooks → subagents → verifiers`

The goal is to find violations and identify the misaligned layer, calibrated to project complexity.

**Output language:** Check in order: (1) CLAUDE.md `## Communication` rule (global takes precedence over local); (2) language of the user's recent conversation messages; (3) default English. Apply the detected language to all output including progress lines, the report, and the stop-condition question.

**IMPORTANT:** Before the first tool call, output a progress block in the output language:

```
Step 1/3: Collecting configuration data
  · CLAUDE.md (global + local) · rules/ · settings · hooks · MCP servers
  · skills + security scan · agents · plugins · auto memory
  · conversation history (up to 3 recent sessions)
```

## Step 0: Assess project tier

Pick tier:

| Tier | Signal | What's expected |
|------|--------|-----------------|
| **Simple** | <500 project files, 1 contributor, no CI | CLAUDE.md only; 0–1 skills; no rules/; hooks optional |
| **Standard** | 500–5K project files, small team or CI present | CLAUDE.md + 1–2 rules files; 2–4 skills; basic hooks |
| **Complex** | >5K project files, multi-contributor, multi-language, active CI | Full six-layer setup required |

**Apply only the detected tier's requirements.**


## Step 1: Collect all data

Run the bundled collector script. It gathers CLAUDE.md, settings (user/project/local), rules, skills, agents, MCP, hooks, plugins, auto memory, conversations, and security scan data in one pass.

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/collect.sh"
```

The script calls `scripts/parse_settings.py` internally for structured settings analysis (hooks, MCP, permissions, auto mode, plugins, notable settings).

Then run the automated validator for deterministic checks that don't need LLM judgment:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/validate.py"
```

This validates skill/agent frontmatter fields, hook schema, context budget, settings conflicts, and security patterns. Its output (`=== VALIDATION FINDINGS ===`) feeds directly into the report — subagents focus on judgment calls only.

## Gotchas

Before interpreting Step 1 output, check these known failure modes.

**Data collection silent failures**
- `jq` not installed: conversation extraction prints `(unavailable)`. BEHAVIOR section will be empty -- treat as [INSUFFICIENT DATA], not a finding.
- `python3` not on PATH: MCP/hooks/allowedTools/plugins/auto-mode sections print `(unavailable)`. Do not flag those areas when the data source itself failed.
- `settings.local.json` absent: hooks, MCP, and allowedTools show empty. Normal for projects using global settings only -- not a misconfiguration.

**MEMORY.md path construction**
- Path built with `sed 's|[/_]|-|g'` on `pwd`. Unusual characters produce the wrong project key. If MEMORY.md shows `(none)` but the user mentions prior sessions, verify the path manually before flagging as [!].

**Conversation extract scope**
- Only the 3 most recent `.jsonl` files are sampled, skipping the active session. Findings from fewer than 3 files carry low signal -- always tag [LOW CONFIDENCE].

**MCP token estimate**
- Assumes ~25 tools/server and ~200 tokens/tool. Servers with many or few tools cause large over/under-estimates. Treat as directional, not precise.

**Tier misclassification edge cases**
- The bash block excludes `node_modules/`, `dist/`, and `build/`, but not all generators. Monorepos with `.next/`, `__pycache__/`, or `.turbo/` output can inflate the file count and trigger COMPLEX tier falsely. Recheck manually if the tier feels wrong.

## Step 2: Analyze with tier-adjusted depth

After Step 1 completes, output a summary line, then the step indicator:

```
Tier: {SIMPLE/STANDARD/COMPLEX} -- {file_count} files · {contributor_count} contributors · CI: {present/absent}
Step 2/3: {SIMPLE: "Analyzing locally" | STANDARD/COMPLEX: "Launching parallel analysis agents"}
```

SIMPLE: output "Analyzing locally" above. Do not launch subagents. Analyze from Step 1, prioritize core config checks, skip conversation-heavy cross-validation unless evidence is obvious.

STANDARD/COMPLEX: output "Launching parallel analysis agents" above, then list coverage:

```
  · Agent 1: CLAUDE.md, rules, skills, agents, MCP context + security scan
  · Agent 2: hooks, permissions, behavior patterns, three-layer defense
```

Launch **two subagents** in parallel. Paste all data inline -- do not pass file paths. Before pasting, replace any credential values (API keys, tokens, passwords) with `[REDACTED]`; paste the structural data only.

### Agent 1 -- Context + Security Audit (no conversation needed)

Read `agents/agent1-context.md` from this skill's directory. It specifies which Step 1 sections to paste and the full audit checklist.

### Agent 2 -- Control + Behavior Audit (uses conversation evidence)

Read `agents/agent2-control.md` from this skill's directory. It specifies which Step 1 sections to paste and the full audit checklist.

## Step 3: Synthesize and present

Before writing the report, output a progress line in the output language:

```
Step 3/3: Synthesizing report
```

Aggregate the local analysis and any agent outputs into one report:

---

**Health Report: {project} ({tier} tier, {file_count} files)**

### ✓ Passing

Render a compact table of checks that passed. Include only checks relevant to the detected tier. Limit to 5 rows. Omit rows for checks that have findings.

| Check | Detail |
|-------|--------|
| settings.local.json gitignored | ok |
| No nested CLAUDE.md | ok |
| Skill security scan | no flags |

### ☻ Critical -- fix now

Rules violated, missing verification definitions, dangerous allowedTools, MCP overhead >12.5%, required-path `Access denied`, active cache-breakers, security findings, broken agent configs.

### ◎ Structural -- fix soon

CLAUDE.md content that belongs elsewhere, missing hooks, oversized skill descriptions, single-layer critical rules, model switching, verifier gaps, subagent permission gaps, skill/agent structural issues, auto memory misconfiguration.

### ○ Incremental -- nice to have

New patterns to add, outdated items to remove, global vs local placement, context hygiene, HANDOFF.md adoption, skill invoke tuning, provenance issues, plugin optimization.

---

If all three issue sections are empty, output one short line in the output language like: `✓ All relevant checks passed. Nothing to fix.`

## Non-goals
- Never auto-apply fixes without confirmation.
- Never apply complex-tier checks to simple projects.
- Flag issues, do not replace architectural judgment.


**Stop condition:** After the report, ask in the output language:
> "Should I draft the changes? I can handle each layer separately: global CLAUDE.md / local CLAUDE.md / hooks / skills / agents."

Do not make any edits without explicit confirmation.
