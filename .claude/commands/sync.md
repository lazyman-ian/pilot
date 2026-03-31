---
description: "Sync pilot plugin to local cache + claude-plugins repo"
allowed-tools: ["Bash"]
---

# Sync Plugin

Sync the pilot plugin from dev repo to both targets:
1. Local plugin cache (immediate effect after `/reload-plugins`)
2. `claude-plugins` distribution repo (for git push)

## Excluded from distribution repo
- `docs/superpowers/` — internal specs/plans, not part of the plugin
- `TEST-RESULTS*.md` — manual test logs
- `articles/` — reference articles
- `.alma-snapshots/` — snapshot data

## Steps

1. Sync to local plugin cache (full copy for local dev):
```bash
rsync -av --delete --exclude='.git' \
  /Users/lazyman/projects/pilot/ \
  /Users/lazyman/.claude/plugins/cache/agent-dev-marketplace/pilot/1.6.0/
```

2. Sync to claude-plugins repo (plugin files only):
```bash
rsync -av --delete \
  --exclude='.git' \
  --exclude='docs/superpowers/' \
  --exclude='TEST-RESULTS*' \
  --exclude='articles/' \
  --exclude='.alma-snapshots/' \
  /Users/lazyman/projects/pilot/ \
  /Users/lazyman/housesigma/claude-plugins/pilot/
```

3. Show what changed in claude-plugins:
```bash
cd /Users/lazyman/housesigma/claude-plugins && git status --short pilot/
```

4. If there are changes, commit with the latest pilot commit message:
```bash
cd /Users/lazyman/housesigma/claude-plugins && \
  LATEST_MSG=$(git -C /Users/lazyman/projects/pilot log --oneline -1 --format='%s') && \
  git add pilot/ && \
  git diff --cached --quiet || git commit -m "sync(pilot): $LATEST_MSG"
```

5. Report result. Do NOT push — let the user decide.
