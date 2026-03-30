# Architecture Stress Testing

Components encode assumptions about model limitations — re-validate as models improve.
On each model upgrade, run these experiments using the SAME requirement for comparability:

**Experiment 1: Designer + Reviewer Merge**
- Hypothesis: Single agent can generate design AND critically review it
- Control: Current pipeline (separate tech-designer + design-reviewer)
- Variant: Single agent, two-pass (generate → adversarial self-review with full checklist)
- Metric: Ungrounded assumptions caught (control vs variant)
- Pass: Variant catches ≥ 80% of what control catches
- Test requirement: One with known API scope boundaries (e.g., Android AB test)

**Experiment 2: Implementer Self-Review**
- Hypothesis: Implementer can catch its own code issues without separate code-reviewer
- Control: Current pipeline (implementer + code-reviewer)
- Variant: Implementer runs self-review checklist before returning
- Metric: Issues missed by variant that control caught
- Pass: 0 CRITICAL missed, ≤ 1 MAJOR missed

**Experiment 3: Implementer Context Persistence**
- Hypothesis: One invocation per step (fresh context) vs all steps in one invocation
- Control: Current (one invocation, all steps sequential in same context)
- Variant: One invocation per step (fresh context each time)
- Metric: Anchor regression count, total time, context window usage

**How to Run**: Pick a completed pipeline run → re-run same `requirement.json` with variant → compare artifacts (`review.json`, `code-review.json`, `git diff`) → record in `.pilot/experiments/<model>-<date>.md`
