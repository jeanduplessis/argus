# ADR 0014: Section-based Companion CLI navigation

- Status: Accepted
- Date: 2026-09-07
- Supersedes: The Project-only listing projection in `0012-companion-cli-workspace-commands-over-app-owned-ipc.md`. Its transport-only boundary and nonselecting creation decision remain unchanged.

## Context

The Companion CLI and Workspace-centric Collections were implemented on parallel
branches. A Project-only list cannot represent a repository in multiple
Collections or direct Standalone Workspace rows without inventing a synthetic
owner or duplicating Workspaces. The application already has one authoritative,
fully expanded navigation projection.

## Decision

Replace `workspace.list`'s top-level `projects` with ordered `sections`. Each
section carries its optional `collectionId` and `name`, and ordered `items`.
Collections retain their names and identities even when empty. The final
ungrouped section has neither a Collection ID nor a name.

An item is discriminated as `project` for a section-local repository block or
`workspace` for a direct Standalone Workspace row. Repository blocks retain
Project identity/configuration and Stack diagnostics, but no Catch-all flag.
Their items retain the existing Workspace/Stack discriminators. Stack rows keep
recorded parent, lane, diagnostic, and optional Workspace data. Other-section
members appear only as nonselectable references; a repository-wide qualifying
Stack retains its header even when this section has only one real member.

The application projects `WorkspaceManager.navigationSections` directly. It
assigns the same global Workspace Numbers as keyboard navigation; disclosure
does not filter or renumber. Each real Workspace occurs once. Empty repository
configuration remains available for creation but is not a navigation block.
The CLI renders the returned sections without reconstructing domain state.

Creation has no new destination parameter. It appends to ungrouped placement,
uses `Workspace.projectId` for repository association, and leaves selection and
focus unchanged. Successfully attached, checkpointed, actually new worktrees
use existing Worktree Setup consent and ownership checks. CLI parent recording
retains its warning-on-failure behavior; explicit Stack UI creation retains its
unforced cleanup-on-recording-failure behavior. Neither path changes discovery's
read-only role.

## Consequences

The list result shape changes; scripts expecting top-level `projects` must use
`sections`. The application and bundled CLI ship the same shared wire types;
no legacy synthetic projection or second ordering authority is maintained.
Version-one socket framing and agent methods are unchanged.

Repeated repository IDs across sections identify one shared configuration, not
multiple resource owners. Stack IDs are interpreted within their section and
repository. The CLI cannot move, close, or configure Collections and cannot
select a Workspace.

## References

- `../SPEC.md`: Companion CLI, Collections, and Worktree Setup.
- `../../CONTEXT.md`: association, placement, and command ownership.
- `0012-companion-cli-workspace-commands-over-app-owned-ipc.md`
- `0013-workspace-centric-collections.md`
- `0012-opt-in-worktree-setup-process-groups.md`
- `0013-record-branch-parents-for-argus-created-branches.md`
