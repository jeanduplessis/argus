# Architecture decision records

This directory records accepted architecture decisions that affect more than
one implementation detail or need their trade-offs preserved for future work.

Use four-digit sequence numbers and descriptive file names:

```text
0001-render-structured-diffs-with-an-argus-owned-webkit-bridge.md
```

Each record contains:

```md
# ADR NNNN: Decision title

- Status: Proposed | Accepted | Superseded
- Date: YYYY-MM-DD

## Context

## Decision

## Consequences

## References
```

ADRs explain architecture choices and trade-offs. `docs/SPEC.md` remains the
authority for current product behavior. Setup, build, testing, and maintenance
commands belong in `docs/DEVELOPMENT.md` or `docs/RELEASING.md`. When a decision
changes, add a new ADR and mark the old record as superseded rather than
rewriting its history.
