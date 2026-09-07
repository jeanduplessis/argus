# Developing Argus

## Organizing Workspaces

Choose **New Collection…** from the sidebar plus menu or File menu. A Collection
can mix Standalone Workspaces and unrelated repositories. One repository can
appear in several Collections, with one shared configuration and no duplicate
Workspace rows. Workspace menus offer **Move to Collection** and **No Collection**.
Removing a Collection only appends its members to ungrouped placement.

Drag a Workspace row to a Collection header to append it, to another Workspace
row to insert before/after it, or to the top Workspaces header to ungroup it.
A Stack member moves independently across Collections. Collection headers can
be reordered. Same-section move-up/down actions can move a Stack block while
Git metadata continues to control parent order. Disclosure never renumbers
shortcuts. Selection, including same-ID selection, reveals current ancestors.

**New Workspace…** in a Collection supplies its destination and lets you choose
Standalone or a registered repository. Repository and Stack actions also supply
the repository and, for Stack creation, the last real local parent. Global
creation is ungrouped; cancel discards its destination. **New Project…** remains
explicit repository registration plus Main-checkout creation. Simply opening a
Git directory as Standalone does not register it, contact a provider, or run setup.
The repository picker includes repositories with no open Workspaces and provides
**Worktree Setup…** and confirmed **Remove Empty Repository…** configuration actions.
No local repository heading removes Workspaces from other Collections. Orphan
adoption defaults to ungrouped placement and does not run setup automatically.

## Requirements

Argus targets macOS 26 and Swift 6. The Xcode project is generated from `project.yml` for Xcode 26.

Required tools:

- Xcode 26 or later;
- Xcode command-line tools;
- XcodeGen;
- SwiftLint;
- the vendored `Frameworks/GhosttyKit.xcframework`.

Swift 6 toolchains include `swift-format`. Install the other command-line tools with:

```sh
brew install xcodegen swiftlint
```

The GitHub CLI is optional for Pull Request intake and read-only Pull Request
Status in Named Project Worktree Workspaces. Argus uses the active `gh`
authentication context and never stores GitHub credentials. Missing CLI or
authentication does not block local work; Argus never installs or logs in for you.

Install and authenticate it with:

```sh
brew install gh
gh auth login
```

For bare-number intake or Pull Request Status, run `gh repo set-default <remote>`
from the Project Repository Root if repository selection is ambiguous or
unavailable. The default repository must match a Project fetch remote. For
GitHub Enterprise, authenticate with `gh auth login --hostname <host>`.

Settings > Files & Changes > **Show Pull Request status** defaults to on. It
contacts GitHub while the application is active and the main window is visible
and not minimized; turning it off cancels work and clears runtime status.
After CLI, authentication, or repository setup changes, use **Refresh Pull
Request Status** in the Workspace context menu or **Refresh** in its Pull Request
Status popover to bypass ordinary caches, subject to host quota/rate-limit pauses.
Automatic refresh is quiet; **Refresh** shows progress only inside the popover
that started it.
The shared leading Pull Request Status icon opens the popover without selecting
its Workspace. **Show Pull Request Status** and **Refresh Pull Request Status**
remain in the Workspace context menu when the icon is hidden or after no match
or failure; rows have no trailing Pull Request slot or Pull Request-number text.
Detailed statuses are batched through `gh api graphql`; a known Selected
Workspace Pull Request refreshes every minute, with background discovery every
ten minutes. Quota pauses show a resume time and disable manual refresh too;
toggling the setting does not bypass the pause. **Refresh changes** remains
local-Git-only. **Open Pull Request** uses the default system browser without
mutating Workspace, Top-level Tab, or Pane state or changing the Right-sidebar
View.

## Local Stack grouping

Argus groups open Workspaces from locally recorded parent relationships in:

- `branch.<branch>.base` Git configuration;
- Graphite `refs/branch-metadata/<branch>` JSON objects with `parentBranchName`;
- the official [`github/gh-stack`](https://github.com/github/gh-stack)
  extension's schema-v1 `<git-dir>/gh-stack` files.

The same reader supplies Against Base. A valid explicit config value overrides
tool metadata; matching tool parents coalesce, and conflicting parents are
reported rather than guessed. A group requires at least two open Workspaces
in one connected recorded-parent component across the repository. Each section
then keeps its local header even with one member. Branch references from other
sections are nonselectable and labeled truthfully. Forks retain their shared parent,
while independent branches merely based on the unparented Project main branch
remain separate. Argus never initializes, repairs, restacks, or merges Stacks.

The gh-stack format was audited against v0.1.0 and revision
`2bd699a544a09cb5c45a013d03416e0894b0454e`. Linked worktrees have separate
tracking files, so Argus inspects common and linked administration and binds
verified current checkouts. It does not invoke `gh stack view`, which can
contact GitHub and rewrite tracking even with `--json`. Unknown future schemas
produce diagnostics rather than a guessed interpretation.

The Project context menu provides **Refresh Stacks**. Missing metadata leaves
ordinary rows unchanged; malformed or conflicting sources do not erase valid
unrelated relationships. A current-branch conflict makes only Against Base
unavailable, preserving Working Changes. Repository/common and linked metadata
changes refresh automatically, including configuration and packed Graphite
refs; configuration outside those watched roots is reread on explicit or other
refresh. Metadata files and combined command output are bounded to 1 MiB, and
branch/parent names to 4096 UTF-8 bytes.

With a separate Git directory, a linked checkout may not have enough Git
registration data to recover the physical main checkout. Argus leaves that
unknown binding unbound rather than mistaking metadata storage for a Workspace;
starting from the actual Project Repository Root provides the verified binding.
See [ADR 0009](adrs/0009-share-tool-agnostic-recorded-parents.md).

## Generate the Xcode project

`project.yml` is the source of truth for Xcode project configuration.

```sh
./scripts/build.sh generate
```

The build script generates `Argus.xcodeproj` automatically if it is missing.

## Build commands

Build the Debug application and CLI scaffold:

```sh
./scripts/build.sh build
```

Build and launch:

```sh
./scripts/build.sh run
```

Build a Release configuration:

```sh
./scripts/build.sh build --release
```

Install a local build in `/Applications` and launch it:

```sh
./scripts/build.sh install --release
```

Other supported commands:

```sh
./scripts/build.sh cli
./scripts/build.sh clean
```

Pass `--no-cli` to omit the CLI scaffold or `--no-open` to build or install without launching Argus.

Build products are written under `.build/Build/Products/<configuration>/`. Within the built application, the CLI is bundled at `Argus.app/Contents/Resources/bin/argus`, and Argus puts that directory first on the `PATH` of every shell it spawns, so `argus` resolves by name in an Argus terminal.

## Tests and formatting

Run the complete app and CLI validation suite:

```sh
./scripts/test.sh
```

The script runs formatting checks and SwiftLint, executes the macOS `ArgusTests` target, builds the CLI, and verifies its version and help output.

The existing Kilo/Pi behavioral harness tests require Node in the Xcode test-host
PATH. For shell-managed Node installations, forward that PATH explicitly with
`TEST_RUNNER_PATH="$PATH" ./scripts/test.sh`.

Run linting by itself:

```sh
./scripts/lint.sh
```

Format Swift sources:

```sh
./scripts/format.sh
```

Set `SWIFT_FORMAT_BIN` or `SWIFTLINT_BIN` when the executables are outside the active Swift toolchain and standard Homebrew paths.

Tests are grouped by product domain:

- `WorkspaceTests`: window, sidebar, tab, Panel, Browser, Settings, and Agent Status behavior;
- `WorktreeTests`: Projects, repositories, branches, and worktrees;
- `SessionTests`: Session Snapshot and restore behavior;
- `GitStatusTests`: status parsing, Files and Changes behavior, operations, and previews;
- `TestSupport`: shared native test helpers.

Prefer behavioral tests through `@testable import Argus`. Source-contract tests are reserved for SwiftUI and AppKit wiring that cannot be observed through a stable boundary without a full UI test.

Automatic Pull Request Status networking is disabled for app instances with
`XCTestConfigurationFilePath`, `ARGUS_UNDER_TEST=1`, or
`ARGUS_DISABLE_SESSION_RESTORE=1`. Status tests inject provider/local-input
fixtures and scheduling rather than relying on live GitHub access.

## Native diff rendering

Argus renders structured diffs with the native `SwiftDiffs` package. Git Preview
Tabs keep Split and Unified layout controls; long lines scroll horizontally.
Blame previews remain ANSI text. See
`docs/adrs/0002-render-structured-diffs-with-native-swift-diffs.md` for ownership
and runtime boundaries.

## GhosttyKit

Normal builds use the vendored `Frameworks/GhosttyKit.xcframework`. Rebuilding the framework is a maintainer task and is separate from the normal application workflow. See `Frameworks/README.md` and `scripts/build-ghosttykit.sh` before changing it.

## Agent integrations

Argus installs integrations only when enabled from Settings. Kilo owns its
managed JSON/JSONC declaration and completion extension. Pi owns
`extensions/argus-agent-status.js` under the effective `PI_CODING_AGENT_DIR`
(or `~/.pi/agent` when the variable is unset). Existing files owned by another
program are never replaced or removed.

Restart Kilo sessions after changing the Kilo integration. Restart Pi or use
`/reload` after changing the Pi integration. Both integrations send requests to
the app-owned `~/.argus/argus.sock` endpoint, which accepts
`agent.turnCompleted`, `agent.statusChanged`, and `agent.statusCleared`. The
same socket serves the Companion CLI's Workspace Commands.

After updating Argus, enable the Pi integration again in Settings to install
its bundled extension, then restart Pi or use `/reload`. Reloading alone does
not copy the updated extension from Argus.

The Pi extension ignores processes marked with `PI_SUBAGENT_CHILD=1`. When
`pi-subagents` advertises its public fleet status API, a main agent that yields
with delegated work still active stays running in Argus and produces no
completion sound or Turn Completion Attention. Completion is reported at the
next successful main-agent settlement with no active delegated work. An
advertised status API that is unsupported or fails suppresses completion;
plain Pi sessions need no subagent package.

Run the Pi lifecycle and socket transport regression tests without launching
Argus or making model calls:

```sh
node Tests/PiIntegrationTests/pi-plugin-events.mjs
```

## Companion CLI

The `argus` executable talks to a running Argus over `~/.argus/argus.sock`
(or `ARGUS_SOCKET_PATH` when Argus injected one into the shell). It resolves
nothing itself — the application owns every identity and branch decision.

Shells Argus spawns already have it on `PATH`. To use it from an ordinary
terminal, call it by its bundled path or symlink it somewhere on your own
`PATH`:

```sh
ln -sf /Applications/Argus.app/Contents/Resources/bin/argus ~/.local/bin/argus
```

Outside an Argus terminal there is no `ARGUS_WORKSPACE_ID`, so `.` has no
Workspace to resolve and the Project comes from the working directory.

```sh
# Collections and ungrouped Workspaces in sidebar order, Stack Groups included
argus workspace list
argus workspace list --json

# A Worktree Workspace in this terminal's Project, on a generated branch
argus workspace create

# An explicit Project, branch, and Workspace name
argus workspace create --project argus --branch feature/api --name "API work"

# Stacked on this terminal's Workspace, or on a named one
argus workspace create --from . --branch feature/api-ui
argus workspace create --from feature/api --branch feature/api-ui
```

`--project` and `--from` accept an ID, an exact name (branch or display title
for `--from`), or `.` for the terminal's own context. Ambiguous references are
refused with their candidates instead of guessing.

`--from` also records `branch.<new>.base` so the pair groups as a Stack in the
sidebar. Stacking onto a Workspace on the Project's main branch records the
base but shows no Stack Group, because a Stack Group needs two open Workspaces
above a trunk branch.

`workspace list --json` returns ordered `sections`, including empty Collections and
a final ungrouped section. Each section has optional `collectionId` and `name`
(absent for ungrouped placement), plus ordered `items` with `kind: "project"`
repository blocks or `kind: "workspace"` Standalone rows. Repository blocks
contain section-local Workspace/Stack items. Split Stacks keep their headers;
Workspaces in other sections are branch references, not duplicated rows.
Workspace Numbers match the fully expanded sidebar regardless of disclosure.

Creating a Workspace appends it to No Collection, even when the calling or base
Workspace belongs to a Collection. Actually new worktrees use the Project's
existing Worktree Setup consent and checkpoint/ownership checks. Reuse does not
automatically run setup. Creation does not change the Selected Workspace, so it is safe to
run from an agent's terminal. Exit codes: `0` success, `1` Argus refused the
request, `3` Argus could not be reached.

Build the CLI alone with `./scripts/build.sh cli`; `swift test` covers its
rendering and wire contract.

## Local state

Argus writes user state outside the repository:

- Session Snapshot: `~/Library/Application Support/Argus/session-v2.json`
- Legacy downgrade backup: `~/Library/Application Support/Argus/session.json`
- Managed Worktrees: `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
- App-owned socket: `~/.argus/argus.sock`

Set `ARGUS_DISABLE_SESSION_RESTORE=1` to launch without restoring the previous Session Snapshot.

### Protected import and downgrade

The new application writes schema 2 to `session-v2.json`. Only when that file is
absent does it import schema-1 `session.json`. Conversion preserves repository,
Collection, and Workspace UUIDs, manual order, roots, selection, Terminal
metadata, zero-Panel Workspaces, and Worktree Setup consent. The new destination
is checkpointed before normal operation; the source is never rewritten or moved.
If the initial checkpoint fails, loaded content remains available and subsequent
saves retry the new destination. Resolve filesystem write failures before quitting.

An older application still reads/writes `session.json`. It sees the pre-conversion
organization and cannot represent mixed/split Collection placement. Edits in the
two files are not merged. Returning to the new app uses `session-v2.json`, not the
old app's later edits. An existing corrupt/incompatible new destination never
triggers repeated legacy import. Keep copies of both files before manual recovery;
only explicitly moving the new destination aside requests a fresh legacy import.
Managed Worktree directories remain under their existing Project UUIDs and are
not copied or moved by import/downgrade.

Test instances continue to default to the temporary per-process
`Argus/TestSessions/<pid>/session.json`, exactly as specified in `AGENTS.md`.
Caller-supplied destinations never fall back to production legacy state. Tests
can inject a temporary `legacySessionSnapshotURL` to exercise protected import.
Do not test migrations against actual application-support files.

## Worktree Setup

Use a Named Project's **Worktree Setup…** context action to save an optional local
command. Blank disables it. Argus runs the exact command through non-login,
noninteractive `/bin/sh -c` in every newly created worktree, including Stack and
fork Pull Request worktrees. Save grants execution with your user permissions:
only enable commands and repositories you trust. Argus does not discover setup
configuration or copy ignored files. Existing/reused, adopted, Main-checkout, and
restored Workspaces do not run setup automatically.

The initial Terminal Tab remains. The runtime **Worktree Setup** tab shows the
command, directory, live output (last 1 MiB), and result. **Stop** terminates the
owned ordinary process group. **Run Setup Again** uses the current Project command
after validating ownership. The Workspace context menu can reopen the log or run
setup explicitly. Closing a stopped tab retains its last bounded log/result until
the Workspace closes or Argus exits; reopening does not rerun it. Explicit retry
replaces prior output. Failures keep the Workspace. Logs are not saved or sent to
system logs; the Project command is stored locally in the Session Snapshot.

The inherited environment includes installed `/opt/homebrew/bin` and
`/usr/local/bin` paths but excludes Argus socket/Workspace/Surface identity.
Stdin is EOF; there is no terminal prompt support, login-shell startup, or service
supervisor. Commands time out after one hour. Do not start detached background
services: process-group cleanup is not containment of deliberately daemonized
code. Closing active setup requires confirmation and waits for cleanup before
worktree deletion. Failed cleanup retains the owned group and blocks closure;
Stop can retry verification without signaling a recycled process-group ID.

Multiple Workspaces can reference one worktree. Deletion is refused if setup is
pending, running, or awaiting cleanup in another Workspace outside the close
scope. Stop setup in the Workspace named by the error, then retry deletion.
This denial does not stop either Workspace's task or remove files. Close without
deletion still stops only its target. Project removal checks all captured child
worktree roots before stopping any child setup. While deletion or its setup
cleanup is in progress, those canonical roots cannot start setup from any
Workspace, including a newly attached duplicate. Reservations release on failure
and after deletion/state removal. Adoption is refused while its Project is closing
or application-wide setup cleanup is in progress.

Focused tests are `WorktreeSetupRunnerTests`, `WorktreeSetupManagerTests`, and
`WorktreeSetupLifecycleTests`; Pull Request integration has a setup-specific
fixture in `PullRequestWorkspaceTests`. Runner tests execute only synthetic local
commands in disposable directories. Manager tests inject a runner and use local
Git fixtures, never repository-provided setup commands or live provider access.
See ADR 0012 for runtime and ownership trade-offs.
