# ADR 0013: Workspace-centric Collections and protected snapshot import

- Status: Accepted
- Date: 2026-09-05
- Supersedes: ADR 0011's Project-based membership and additive same-file persistence decision. ADR 0009's Recorded Base Branch source/precedence policy and ADR 0012's setup authority/lifecycle remain unchanged.

## Context

Project-based Collections entangle repository configuration, navigation placement,
and destructive scope. Users need to organize unrelated Workspaces together and
place one repository's Workspaces in several Collections without duplicating
repository configuration or selectable content. A same-path schema change cannot
protect this organization from older application writers.

## Decision

Keep one shared Project record and existing UUID/storage paths per registered
repository. `Workspace.projectId` is the authoritative optional repository
association. Remove runtime synthetic Catch-all state and Project child lists.
Store placement only as ordered Workspace IDs per flat Collection plus ordered
ungrouped Workspace IDs. Preserve empty Collections and repository records.
Standalone directory intake never implicitly registers repositories, contacts
providers, or executes setup. Existing explicit registration remains unchanged.

Derive one fully expanded navigation projection for every navigation consumer.
Within each section, repository blocks occupy their earliest manual member;
no-repository Workspaces remain direct. Determine Stack qualification from
repository-wide bindings, then project locally, retaining one-local-member
headers and truthful nonselectable references. Discovery never changes manual
placement. Section + repository + optional Stack identity owns disclosure and
hidden summaries; observation/status/setup configuration remains repository-wide.
Selection resolves current ancestors, including same-ID selection, and later
movement/disclosure cancels obsolete delayed reveals.

Creation requests carry destination separately from repository and explicit
Stack parent. Global creation defaults to ungrouped. Revalidate destination and
repository after asynchronous preparation, before attachment. Exact Pull Request
reuse selects existing placement. Clean only actually new stale resources, using
unforced cleanup to retain edited work for orphan recovery. Only successfully
attached, checkpointed, actually new worktrees with unchanged consent start setup.

Moving a Workspace across sections moves only that Workspace, even within a
Stack. Typed drag payloads capture source order; destination/order is captured
before asynchronous decoding, and both are revalidated. Moves do not change
repository association, Panels, selection, focus, or resources. Collection removal
only ungroups members in manual order. Local headings do not authorize global
repository removal. Empty repository configuration can be removed explicitly;
resource operations capture association-based Workspace IDs and retain existing
setup peer checks, deletion reservations, stop-before-delete, and failure guards.

Write schema 2 to production `session-v2.json`. Only if it is absent, import
schema-1 `session.json`, preserving that source byte-for-byte as the downgrade
backup and checkpointing converted state at the new destination. Never import
again merely because the new destination is corrupt or incompatible. Convert
legacy Project-based Collection order deterministically, clear only synthetic
associations, preserve identity/configuration/content metadata, and seed local
disclosure from legacy Project state. Isolate malformed optional placement.
Test default paths remain the per-process temporary `session.json`; supplied URLs
cannot fall back to production legacy data.

## Consequences

Placement, repository association, and destructive scope now have separate
owners. Repository headings can repeat without duplicating resources or runtime
services. A repository with no open Workspaces disappears from navigation but
remains available through the repository picker for creation and configuration.

An older application can use its preserved file but cannot see new organization.
Old/new edits are not merged. Recovery is explicit; import does not move worktree
directories or widen external-worktree deletion authority. No Work Mode or new
repository-discovery subsystem is introduced.

## References

- `../SPEC.md`: Projects, Collections, Stack Groups, Session persistence.
- `../../CONTEXT.md`: authoritative association and placement terminology.
- `../UI_DESIGN_PRINCIPLES.md`: section-local navigation and contextual creation.
- `../DEVELOPMENT.md`: protected import, downgrade, and test isolation.
