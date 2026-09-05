# ADR 0012: Opt-in Worktree Setup with owned process groups

- Status: Accepted
- Date: 2026-09-05

## Context

New worktrees often need a local preparation command. Terminal input injection
cannot provide reliable command completion, and repository-discovered commands
would grant execution authority to checkout content. Existing Git/gh process
capture has bounded query semantics, not streaming logs or descendant cleanup.
Setup must not run on worktree reuse or session restore, and deletion must not
race a command still writing into a worktree.

## Decision

A Named Project owns one optional, explicitly saved local Worktree Setup command.
A dedicated native sheet explains execution authority, including fork Pull
Requests. No repository configuration is discovered or imported. Whitespace-only
commands disable setup; otherwise shell source is preserved exactly, bounded to
16 KiB, and rejects NUL. The setting is durable; runs and logs are not.

The worktree service returns an authoritative new/reuse result. WorkspaceManager
captures Project ownership and consent at creation, checkpoints a successfully
attached Workspace, then creates one runtime-only Worktree Setup Panel without
replacing its initial Terminal Tab. Before launch it revalidates canonical
secondary-worktree registration, current Workspace/Project membership, and
unchanged consent. Explicit retry reads the current command and uses the same
checks. Background updates never navigate or take focus.

The dedicated runner uses `/bin/sh -c` with one literal command argument, a
process-API working directory, stdin at EOF, inherited environment with installed
Homebrew binary paths, and no inherited Argus socket/Workspace/Surface identity.
It is noninteractive and non-login. It uses a new POSIX session and owned process group without an inherited
controlling terminal, nonblocking merged output, a 1 MiB UTF-8-safe retained tail, and a one-hour
wall-clock deadline. Retention overflow does not terminate the command. Existing
Git/gh runners are unchanged.

Stop and close terminate ordinary descendants, including those left when the
shell exits first. The runner observes shell exit without reaping the group
leader until group members have terminated, reserving the PID/group identity
through cleanup. Bounded failed cleanup retains that owner for explicit Stop
retry and blocks closure/deletion. This is not sandboxing or containment of
commands that deliberately daemonize or escape their process group. Interactive
prompts and detached background services are unsupported.

Setup has its own running-state count, never the Terminal Surface sidebar badge.
Tab, Workspace, Project, main-window, and application close include active setup
in confirmation. Confirmed close awaits cleanup before removing content or
worktree files. Application termination stays in `terminateLater` until cleanup
completes; failed cleanup cancels termination. Cancel preserves the task.

Shared worktree roots require an additional boundary independent of Workspace
identity. Before any deletion stop/await, WorkspaceManager atomically reserves
all canonical target roots and refuses the operation if an outside-scope
Workspace has pending/running/unconfirmed setup captured at one of those roots.
The user must stop that peer explicitly; denial leaves all tasks and files
unchanged. Project scope is its captured child Workspace IDs, not every Workspace
that happens to share a root. Each operation releases only its acquired roots,
on failure or after deletion/state removal. Eligibility and pre/post-validation
launch checks reject reserved roots globally. Close without deletion remains
Workspace-local. Adoption cannot attach during Project closure or application-wide
setup cleanup, so a late adoption cannot outlive removal of its Project.
Duplicate-Workspace attachment policy is otherwise unchanged.

## Consequences

Setup failures, launch failures, timeout, and Stop retain the Workspace and log.
Users can inspect and retry without recreating the worktree. Logs and raw output
are not written to the Session Snapshot or diagnostic logs. Normal app inactivity
and tab switching do not pause or restart setup. The Project setting can execute
checkout-controlled code with the user's permissions and is not a security
sandbox. Only the last completed/stopped Panel log is retained after its tab closes, so
Show Worktree Setup can reopen it without rerunning. It is released with its
Workspace or when the application exits; explicit retry replaces prior output.

## References

- `docs/SPEC.md`: Worktree Setup, Panel and lifecycle contracts.
- `CONTEXT.md`: Worktree Setup ownership and canonical terms.
- `docs/UI_DESIGN_PRINCIPLES.md`: native configuration and in-Workspace content.
- `docs/DEVELOPMENT.md`: operating and testing Worktree Setup.
