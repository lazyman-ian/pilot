Use only the pasted data. Do not read files.

[PASTE Step 1 output sections: settings.json (user), settings.json (project), settings.local.json, GITIGNORE, CLAUDE.md (global), CLAUDE.md (local), hooks (all levels), PLUGIN HOOKS, MCP FILESYSTEM, MCP ACCESS DENIALS, allowedTools count, AUTO MODE, AUTO MEMORY, PLUGINS, skill descriptions, AGENTS, AGENT FRONTMATTER, CONVERSATION EXTRACT]

Tier: [SIMPLE / STANDARD / COMPLEX]. Apply only that tier.

## Part A: Control + Verification Layer

Hooks checks:
- SIMPLE: Hooks are optional. Only flag broken ones.
- STANDARD+: PostToolUse hooks expected for the primary languages of the project.
- COMPLEX: Hooks expected for all frequently-edited file types found in conversations.
- ALL tiers: If hooks exist, validate against official schema:
  - Top level: event name → array of matcher groups
  - Each matcher group: `matcher` (string/regex, optional) + `hooks` array
  - Each hook: `type` required ("command" | "http" | "prompt" | "agent")
  - Common optional fields: `if`, `timeout`, `statusMessage`, `once`
  - Command-specific: `command`, `async`, `shell`
  - HTTP-specific: `url`, `headers`, `allowedEnvVars`
  - Prompt-specific: `prompt`, `model`
  - Agent-specific: `prompt`
- ALL tiers: Validate event names against official list:
  - Lifecycle: SessionStart, SessionEnd, PreCompact, PostCompact
  - User input: UserPromptSubmit
  - Tool: PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest
  - Agent: SubagentStart, SubagentStop
  - Task: TaskCreated, TaskCompleted, TeammateIdle
  - Completion: Stop, StopFailure
  - Config: ConfigChange, CwdChanged, FileChanged, InstructionsLoaded
  - External: Notification, Elicitation, ElicitationResult
  - Worktree: WorktreeCreate, WorktreeRemove
  - Flag unknown event names (typos or outdated)
- ALL tiers: Flag full test suites on every edit; prefer fast checks for immediate feedback.
- ALL tiers: Flag commands without output truncation; unbounded output floods context.
- ALL tiers: Flag commands without explicit failure surfacing.
- ALL tiers: For `http` hooks, verify URLs are in `allowedHttpHookUrls` if that setting is defined.
- ALL tiers: For `prompt`/`agent` hooks, note they consume additional tokens per invocation.

allowedTools hygiene, ALL tiers:
- Flag genuinely dangerous operations only: sudo *, force-delete root paths, *>* and git push --force origin main
- Check for overly broad patterns that may grant unintended access
- Do NOT flag: path-hardcoded commands, debug/test commands, brew/launchctl/maintenance commands -- these are normal personal workflow entries
- Check deny rules for trivial bypasses (e.g., deny `git checkout -- .` but not `git restore .`)

Credential exposure, ALL tiers:
- Project-scoped secrets are [!] only if committed, shared, or stored in non-gitignored project files
- Treat `ignored only by non-project rule (...)` in the GITIGNORE section as insufficient; recommend a repo-local ignore rule
- Do NOT flag user-scoped files like `~/.mcp.json` or `~/.claude.json` just because credentials are intentionally stored there
- Check `httpHookAllowedEnvVars` if http hooks are used -- overly broad env var access is a risk

MCP configuration, STANDARD+:
- Count total MCP servers across all sources (.mcp.json + settings + ~/.claude.json)
- If >6 servers total, flag performance impact
- Check filesystem MCP has allowedDirectories configured
- If `~/.claude/projects/.../tool-results/*` denials show breakage, output a suggestion for the narrowest missing path
- Check for `enableAllProjectMcpServers: true` -- may auto-approve untrusted servers in shared repos
- Check for servers defined inline in agent `mcpServers` field -- these are scoped correctly

Permission mode checks, ALL tiers:
- Check `permissions.defaultMode` across settings levels
- Flag `defaultMode: "bypassPermissions"` at project level as [!] (affects all contributors)
- Check `autoMode` configuration if present: verify `environment`, `allow`, `soft_deny` arrays make sense
- Flag `disableAutoMode` set at project level (blocks users from choosing auto mode)
- Flag `allowManagedPermissionRulesOnly` or `allowManagedHooksOnly` at non-managed levels (these are managed-only settings)

Prompt cache hygiene, ALL tiers:
- Check CLAUDE.md or hooks for dynamic timestamps/dates in system context; they break prompt cache
- Check if hooks or skills non-deterministically reorder tool definitions
- Flag mid-session model switches like Opus→Haiku→Opus; they rebuild cache and can cost more
- If model switching is detected, recommend subagents instead

Three-layer defense consistency, STANDARD+:
- For each critical rule in CLAUDE.md NEVER/ALWAYS items, check if:
  1. CLAUDE.md declares the rule: intent layer
  2. A Skill teaches the method/workflow for that rule: knowledge layer
  3. A Hook enforces it deterministically: control layer
- Flag rules that only exist in one layer -- single-layer rules are fragile:
  - CLAUDE.md-only rules: Claude may ignore them under context pressure
  - Hook-only rules: no flexibility for edge cases, no teaching
  - Skill-only rules: no enforcement, no always-on awareness
- Priority: focus on safety-critical rules: file protection, test requirements, deploy gates

Verification checks:
- SIMPLE: No formal verification section required. Only flag if Claude declared done without running any check.
- STANDARD+: CLAUDE.md should have a Verification section with per-task done-conditions.
- COMPLEX: Each task type in conversations should map to a verification command or skill.

Plugin checks, STANDARD+:
- List enabled plugins and note their source (official marketplace vs custom)
- Flag `extraKnownMarketplaces` pointing to unknown/unverified sources
- Note: plugin agents ignore hooks/mcpServers/permissionMode -- if these are needed, agent must be copied to .claude/agents/
- Flag if `enabledPlugins` has plugins not actually installed or available

Settings consistency, ALL tiers:
- Check for same key set at multiple levels (user/project/local) with conflicting values
- Flag `includeCoAuthoredBy` (deprecated, use `attribution` instead)
- Flag `includeGitInstructions: false` without a custom git workflow skill
- Check `cleanupPeriodDays: 0` -- this disables session persistence entirely

## Part B: Behavior Pattern Audit

Data source: up to 3 recent conversation files. Only flag clear evidence. Tag each finding [HIGH CONFIDENCE] or [LOW CONFIDENCE].

1. Rules violated: quote the NEVER/ALWAYS rule and observed violation. No inference.
2. Repeated corrections: same issue corrected in at least 2 conversations.
3. Missing local patterns: project-specific behaviors reinforced in conversation but missing from local CLAUDE.md.
4. Missing global patterns: cross-project behaviors missing from ~/.claude/CLAUDE.md.
5. Skill frequency, STANDARD+: only report directly observed usage. With fewer than 3 sessions, mark [INSUFFICIENT DATA]. For verified <1/month skills, suggest adding `disable-model-invocation: true` or retiring.
6. Agent frequency, STANDARD+: check if custom agents are actually being delegated to. Unused agents waste context (descriptions loaded into every session).
7. Anti-patterns: only flag what is directly observable:
   - Claude declaring done without running verification
   - User re-explaining same context across sessions -- missing HANDOFF.md or memory
   - Long sessions over 20 turns without /compact or /clear
   - Model switching mid-session (Opus→Haiku→Opus) causing cache rebuilds
   - Subagent spawned for tasks that main thread + skill could handle (unnecessary overhead)

Output: bullet points only, two sections:
[CONTROL LAYER: hooks issues | permission issues | allowedTools to review | cache hygiene | three-layer gaps | verification gaps | plugin issues | settings conflicts]
[BEHAVIOR: rules violated | repeated corrections | add to local CLAUDE.md | add to global CLAUDE.md | skill frequency | agent frequency | anti-patterns (tag each with confidence level)]
