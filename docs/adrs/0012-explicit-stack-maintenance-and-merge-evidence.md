# ADR 0012: Keep Stack maintenance explicit and use success-bound merge evidence

- Status: Accepted
- Date: 2026-09-03
- Supersedes: ADR 0009's no-repair scope and missing-recorded-ref fallback, and ADR 0008's prohibition on any Changes View Pull Request module, only for the narrow Stack advisory described here. Shared local discovery, source precedence, reference preference, provider scheduling, and independent Workspace lifecycle remain applicable.

## Context

A local Recorded Base Branch and a Pull Request's target can diverge after a partial Stack merge. Squash merging a parent does not make the original parent commits ancestors of main. Silently replacing the comparison with main can therefore include already merged changes. Deleting the old parent refs previously caused the same change through configured-base fallback.

The existing local metadata reader already serves both Stack Groups and Against Base. Explicit Git configuration takes priority over Graphite and gh-stack records, including tracking files in sibling administrative directories. Writing an override is not third-party Stack registration and can mask later tool updates.

Ordinary Pull Request Status intentionally retains a previously validated merged association after local HEAD changes. That is useful historical information, but it does not prove the current branch tip was merged or is safe to treat as an inactive ancestor. Git refs, Worktrees, local configuration, Workspace state, and the Session Snapshot also have no shared transaction.

## Decision

Keep automatic discovery and local Git status read-only and offline. Add focused explicit operations for dependent creation and repository-local parent edits, outside the metadata reader. New dependent Worktrees start at the initiating Workspace's verified committed HEAD, not the Project checkout's implicit HEAD; their parent is recorded before attachment. Name suggestions and collision checks remain local. A failed attempt tracks its own resources and provider source versions and compensates only while their identity/content still match. New `gh-stack` files or Graphite registrations are retained even when an explicit local parent leaves the effective graph unchanged. Rollback never force-removes changed or dirty Worktrees. Checkout and status-based validation guard external clean/smudge/process filters and recursive submodule activity; required external conversion is refused rather than replaced by silently different content. Unused global filter definitions do not block ordinary checkouts.

The parent editor exposes effective source information and local overrides. It validates branch/checkout/configuration identity, resolvable names, and cycles. A repository-local config transaction uses Git's lock convention, expected-state checks, a staged edit, atomic publication, and shared-reader readback. Global, included, Worktree-scoped, and provider files remain untouched. A concurrent change is retained rather than overwritten during rollback. The UI states that an override takes priority over tools and that removal exposes remaining metadata, not necessarily no parent.

Publish immutable Pull Request Evidence only after successful status validation. Bind it to target, repository, actual local branch/HEAD/upstream, fetch remotes, ownership generations, and validation time. Invalidate usable evidence on context/HEAD/repository changes, failure/pause, disable/removal, or expiry, independently of last-known status presentation. Exact local/provider HEAD agreement is additionally required for merged-row folding and close-only cleanup.

Retain recorded parent, actual comparison ref/base commit, branch/HEAD, and merge base at Change Section level, including empty/unavailable/capped sections. A valid recorded parent whose refs are missing now makes Against Base unavailable instead of silently selecting main. No-parent and invalid/empty/self-parent fallback rules are unchanged. Working Changes remain separate and actionable.

A UI adapter may combine this local comparison context with existing fresh Pull Request Evidence. It distinguishes verified merged-parent evidence from a differing child Pull Request target; it never changes the comparison or Git Status Request identity. The compact advisory is an explicit exception to the prohibition on a general Changes View Pull Request module, not a second provider runtime.

Merged-prefix disclosure is runtime-only presentation over the existing fully expanded navigation projection. Selected and running-process Workspaces stay visible; invalid or expired evidence reveals folded members. Hidden rows do not become fabricated main connections. Explicit cleanup confirms a captured set, retains all Worktrees/branches/files, freshly compares local branch/HEAD/upstream and fetch remotes with captured evidence, then performs final candidate/evidence/process checks and close-only teardown without suspension on MainActor. Selection is resolved once from the original navigation order.

Sync remains guidance, not an execution engine. The user verifies the merge, updates the target, restacks with the correct old boundary, reviews the diff, repairs local parent metadata, and separately reviews publication. The guide may copy instructions or open a fresh Terminal Tab, but it does not inject commands. An ancestry check against stale main or a metadata edit is not reported as completed synchronization.

## Consequences

Argus can extend and organize locally recorded Stacks without assuming ownership of Graphite or gh-stack containers. The explicit local override remains a maintenance responsibility and is visible in the editor.

A missing recorded ref may now require user repair where Argus previously displayed a different comparison. This is deliberate: an unavailable diff is safer and more accurate than silently broadening it after a squash merge.

Merge-driven presentation depends on fresh evidence and can conservatively leave rows expanded or omit a target when ownership cannot be proven. No historical Stack-membership persistence or broad process-liveness subsystem is introduced.

Automatic restacking, conflict recovery, multi-Worktree mutation coordination, provider registration, PR retargeting, pushing, and bulk Worktree deletion remain separate future decisions. Existing individual close/delete workflows are unchanged.

## References

- `docs/adrs/0009-share-tool-agnostic-recorded-parents.md`
- `docs/adrs/0008-read-only-worktree-pull-request-status.md`
- `docs/adrs/0009-host-batched-pull-request-status.md`
- `docs/SPEC.md`, Guided Stack maintenance and Base Branch and Against Base
- `docs/DEVELOPMENT.md`, Guided Stack controls
- `CONTEXT.md`, Pull Request Evidence and Recorded Base Branch
