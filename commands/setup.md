---
description: "Setup agent-dev for monorepo: merge sub-project .claude/ capabilities"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-monorepo.sh:*)"]
---

# agent-dev setup

Run the setup script to merge sub-project `.claude/` capabilities into monorepo root:

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-monorepo.sh"
```

After completion, run `/reload` to apply the merged hooks and rules.

This command:
- Scans all sub-directories with `.git/` + `.claude/`
- Symlinks rules, skills, steering, agents, commands (with project prefix)
- Merges settings.json hooks (replaces `$CLAUDE_PROJECT_DIR` with absolute paths)
- Records manifest for cleanup

Re-run anytime sub-project `.claude/` configs change.
