# Prompt References

## Project Knowledge

Each project has its own `CLAUDE.md` and `.claude/` directory with:
- Build, test, lint commands
- Architecture conventions
- Rules and constraints
- Steering docs / skills

Always read the target project's documentation. Do NOT hardcode project-specific knowledge here.

## Commit Message Format

```
type(scope): description
```

- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`
- Scope: module or feature name
- Description: imperative mood, lowercase, no period, under 72 chars
- Example: `feat(filter): add price range filter component`

## Branch Naming

```
feat/<slug-from-requirement-title>
fix/<slug-from-requirement-title>
```

Detect base branch: `git -C <projectDir> rev-parse --abbrev-ref origin/HEAD 2>/dev/null`
Strip "origin/" prefix. Fallback: `main`, then `master`.
