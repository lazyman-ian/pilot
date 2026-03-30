# Config Best Practices

## From Anthropic Official Docs (code.claude.com, 2026-03)

### Skill Specification
- Frontmatter fields: `name`, `description`, `argument-hint`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `model`, `effort`, `context`, `agent`, `hooks`, `paths`, `shell`
- Description: <250 chars, truncated in listing. Front-load key use case
- SKILL.md: <500 lines, move detail to supporting files
- String substitutions: `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N`, `${CLAUDE_SESSION_ID}`, `${CLAUDE_SKILL_DIR}`
- `context: fork` runs skill in isolated subagent; needs explicit task instructions
- `agent` field picks subagent type (Explore, Plan, general-purpose, or custom)
- `paths:` glob patterns limit when skill auto-activates (same format as rules)
- Dynamic context: `` !`command` `` syntax runs shell before skill content sent to Claude
- Skill description budget scales at 1% of context window, fallback 8000 chars. Override with `SLASH_COMMAND_TOOL_CHAR_BUDGET`

### Hook Specification
- Event types (full list): SessionStart, InstructionsLoaded, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, PostToolUseFailure, Notification, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, TeammateIdle, Stop, StopFailure, ConfigChange, CwdChanged, FileChanged, PreCompact, PostCompact, Elicitation, ElicitationResult, WorktreeCreate, WorktreeRemove, SessionEnd
- Handler types: `command`, `http`, `prompt`, `agent`
- Common fields: `type` (required), `if`, `timeout`, `statusMessage`, `once`
- Command: `command`, `async`, `shell`
- HTTP: `url`, `headers`, `allowedEnvVars`
- Prompt: `prompt`, `model`
- Agent: `prompt`
- Exit codes: 0=success (parse JSON), 2=blocking error (block action, stderr to Claude), other=non-blocking
- JSON output: `continue`, `stopReason`, `suppressOutput`, `systemMessage`, `decision`, `reason`, `hookSpecificOutput`
- Environment vars: `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_ENV_FILE`, `CLAUDE_CODE_REMOTE`
- Settings: `disableAllHooks`, `allowManagedHooksOnly`, `allowedHttpHookUrls`, `httpHookAllowedEnvVars`

### Subagent Specification
- Frontmatter: `name` (required), `description` (required), `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `effort`, `isolation`, `initialPrompt`
- Model options: `sonnet`, `opus`, `haiku`, full model ID, `inherit` (default)
- Permission modes: `default`, `acceptEdits`, `dontAsk`, `bypassPermissions`, `plan`
- Memory scopes: `user` (~/.claude/agent-memory/), `project` (.claude/agent-memory/), `local` (.claude/agent-memory-local/)
- Built-in agents: Explore (haiku, read-only), Plan (inherit, read-only), general-purpose (inherit, all tools), Bash, statusline-setup, Claude Code Guide
- Plugin agents ignore hooks/mcpServers/permissionMode (security)
- Subagents cannot spawn other subagents
- Cost: 4-7x tokens vs main thread
- `isolation: worktree` for isolated repo copy

### CLAUDE.md Guidelines
- Under 200 lines per file
- Include only what Claude can't infer from code
- Specific and verifiable rules, not vague guidance
- @ imports for related content (max depth 5)
- .claude/rules/ for topic-specific files with paths globs
- Skills for domain knowledge that's not needed every session
- HTML comments (`<!-- -->`) stripped before injection (use for human-only notes)
- `claudeMdExcludes` in settings to skip irrelevant files in monorepos

### Memory System
- Auto memory: per-project at `~/.claude/projects/<project>/memory/`
- MEMORY.md: first 200 lines or 25KB loaded at session start
- Topic files loaded on demand by Claude
- `autoMemoryEnabled` setting (default: true)
- `autoMemoryDirectory` setting for custom location
- All worktrees in same git repo share one auto memory directory

### Settings Architecture
| Scope | File | Shared | Priority |
|-------|------|--------|----------|
| Managed | Server/plist/registry/managed-settings.json | IT-deployed | 1 (highest) |
| CLI args | --flag | No | 2 |
| Local | .claude/settings.local.json | Gitignored | 3 |
| Project | .claude/settings.json | Git | 4 |
| User | ~/.claude/settings.json | No | 5 (lowest) |

Key settings: `permissions`, `hooks`, `autoMode`, `disableAutoMode`, `autoMemoryEnabled`, `autoMemoryDirectory`, `model`, `availableModels`, `modelOverrides`, `effortLevel`, `statusLine`, `outputStyle`, `agent`, `enableAllProjectMcpServers`, `enabledMcpjsonServers`, `disabledMcpjsonServers`, `channelsEnabled`, `claudeMdExcludes`, `includeGitInstructions`, `cleanupPeriodDays`, `attribution`

### Permission Settings
- `permissions.allow`: array of tool patterns
- `permissions.deny`: array of tool patterns
- `permissions.defaultMode`: auto/default/acceptEdits/dontAsk/bypassPermissions/plan
- `autoMode.environment`: prose rules for auto mode classifier
- `autoMode.allow`: auto-allowed patterns
- `autoMode.soft_deny`: soft-denied patterns
- Tool pattern syntax: `ToolName(pattern)`, `Agent(agent-name)`, `Skill(skill-name *)`

## From Tw93 — "Six-Layer Framework"

### Context Budget
- 200K context: ~15-20K for system instructions, each MCP server ~5K tools
- 5 MCP servers = 25K tokens (12.5%) just for tool definitions
- CLAUDE.md should be under 2.5K tokens
- Problem is noise, not length

### Layer Balance
Context → Tools/MCP → Skills → Subagents → Hooks → Verification
Only strengthening one layer causes imbalance.

### Rules
- Hooks for deterministic enforcement (100% compliance)
- CLAUDE.md/rules for guidance (~70% compliance)
- Safety-critical rules must be hooks, not instructions

### Prompt Cache
- Stable tool definition order
- No dynamic content in system prompt
- defer_loading for rarely-used tools

## From Anthropic (Thariq — "How We Use Skills")

### Skill Writing
- Push Claude out of defaults — focus on info that changes behavior, not what it already knows
- Gotchas section is highest-signal content — build from actual failure points
- Use filesystem for progressive disclosure: SKILL.md → references/ → scripts/
- Avoid over-specification — give info but allow flexibility
- Description is a trigger condition, not a summary
- Give Claude scripts to compose, not boilerplate to reconstruct

### Skill Categories
Reference, Verification, Data, Automation, Scaffolding, Code Quality, Deployment, Investigation, Operational

## Agent Checklist
- Has `maxTurns`? (prevent runaway)
- Has descriptive `description` with "Use proactively"? (improve trigger rate)
- System prompt references skills instead of duplicating? (DRY)
- `memory` instructions in body? (read before start, write after finish)
- `tools` or `disallowedTools` set? (principle of least privilege)
- `isolation: worktree` for high-risk operations? (migration, refactor)

## Memory Lifecycle (Industry Consensus)
- Create → Dedup → Store → Access → Decay → Consolidate → Archive/Expire
- Auto Memory: first 200 lines/25KB loaded, topic files on demand
- Mem0: LLM judges ADD/UPDATE/DELETE/NOOP (built-in dedup)
- Consolidation: entries > 30 days → archive to topic file; 3+ occurrences → promote to skill
