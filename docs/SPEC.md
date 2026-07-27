# Argus application specification

## Status

Stable v1 baseline, updated 2026-07-26.

This document defines behavior implemented by the current Argus application. Future work belongs under `docs/proposals/` until it is implemented and incorporated here.

The words "MUST", "MUST NOT", "SHOULD", "SHOULD NOT", and "MAY" are normative.

## Product scope

Argus is a personal macOS terminal workspace manager built on Ghostty. It organizes terminal, browser, file, and Git preview content into Workspaces; groups repository-backed Workspaces into Projects; manages Git worktrees; shows Workspace files and Git changes; and restores durable session state.

Argus is a single-user, single-machine application. It has one main Workspace window and a separate native Settings surface. It does not provide a working external control API in v1.

## Application shell

1. The main window MUST use a three-column layout: the left sidebar, center Workspace content, and the Right Sidebar.
2. The main window MUST use a full-size transparent titlebar and an opaque black application shell.
3. The left sidebar and Right Sidebar MUST be independently toggleable and resizable.
4. Left-sidebar visibility and width MUST persist in `UserDefaults`. Its default width is 200 points, with an effective range from 80 points to one third of the window width.
5. Right-sidebar visibility, width, and selected Right-sidebar View MUST persist in `UserDefaults`. Its width range is 180 to 600 points and its default width is 250 points.
6. Dividers MUST provide a drag target wider than their visible separator.
7. Inspectable content MUST remain in the main Workspace window. Settings, sheets, alerts, menus, and popovers MAY use their normal macOS surfaces.

## Settings

1. Argus MUST provide a native macOS Settings surface for global application preferences.
2. Settings MUST be stored separately from the Session Snapshot.
3. General settings MUST include:
   - restore previous session;
   - default Right-sidebar View;
   - default directory for a new Standalone Workspace.
4. An explicitly supplied Standalone Workspace directory MUST take precedence over the configured default. The configured default MUST take precedence over the user's home directory.
5. Appearance settings MUST include interface text size, document text size, and compact or comfortable interface density.
6. Terminal settings MUST include the audible-bell preference. Ghostty configuration remains authoritative for terminal font, colors other than Argus's background override, and keybindings.
7. Files and Changes settings MUST include hidden Workspace Item visibility, initial source wrapping, initial Markdown and SVG display modes, initial diff layout, and initial diff overflow behavior.
8. Browser settings MUST include homepage, search provider, page zoom, WebKit inspectability, and persistent or private website data storage.
9. Global defaults MUST apply when their target is created. They MUST NOT reset existing Panel-local state.
10. `.git` MUST remain excluded from the Files View even when hidden Workspace Items are visible.

## Projects and Workspaces

### Projects

1. A Project MUST have an immutable Project ID and a mutable display name.
2. A Named Project MUST identify one Git repository by its canonical Project Repository Root.
3. Project creation MUST reject a non-repository directory and a repository already represented by another Named Project.
4. Project creation MUST detect the main branch from, in order: the remote HEAD, local `main`, local `master`, or the current branch. The creation UI MAY accept an explicit main-branch override when detection fails.
5. Creating a Named Project MUST also create its Main-checkout Workspace.
6. A Project MUST keep an ordered list of child Workspace IDs and persist its display name, repository path, main branch, expansion state, and optional color.
7. Argus MUST maintain one non-removable Catch-all Project named "Workspaces" for Standalone Workspaces.
8. Removing a Named Project MUST remove its child Workspaces and attempt to remove their Managed Worktrees.
9. Named Projects MUST appear before the Catch-all Project in the left sidebar.

### Workspaces

1. A Workspace MUST have an immutable Workspace ID, one Workspace Root, an ordered set of Top-level Tabs, and one Active Tab.
2. A Workspace MAY be a Standalone Workspace, Main-checkout Workspace, or Worktree Workspace.
3. A Standalone Workspace MAY use an ordinary directory with no Git repository.
4. New Workspaces MUST start with one Terminal Panel.
5. Workspaces MUST support rename, close, selection, and reordering within a Project.
6. Closing the last Workspace MUST create and select a fresh Standalone Workspace.
7. Cmd+1 through Cmd+8 MUST select Workspaces by global left-sidebar order. Cmd+9 MUST select the last Workspace.
8. The left sidebar MUST show Project and Workspace hierarchy, selection, Workspace type, branch when available, and Agent Status when present.
9. A Standalone Workspace MUST allow its Workspace Root to be changed from its left-sidebar context menu.
10. Changing a Standalone Workspace's Workspace Root MUST immediately update its Files View and Git Status Root. New Terminal tabs MUST start at the new Workspace Root without changing existing Terminal Working Directories.

## Work Modes

1. Argus MUST provide Code Work Mode and Review Work Mode through a Work Mode picker in the left-sidebar header.
2. A Work Mode is an application-level state boundary, not a filter over shared content. Code and Review MUST independently retain their navigation selection, center tabs, Right Sidebar state, and restoration state.
3. Switching Work Modes MUST preserve the source mode and restore the destination mode without creating, closing, reordering, or refreshing tabs solely because of the switch.
4. A Work Mode change MUST NOT redirect pending work, selection, focus, or visible content in the other Work Mode.
5. Argus MUST persist the last selected Work Mode and restore it at launch. Before leaving Review Work Mode, it MUST flush durable Review Session State.
6. Global Settings remain shared. A Project's hosted Repository Identity MUST be shared when a Review Project is explicitly associated with a Named Project; display names, filesystem paths, and Git remotes MUST NOT be used to infer that association.

## Pull Request review

### Provider, Project, and intake

1. Review Work Mode currently supports GitHub through the active GitHub CLI (`gh`) account for the requested host.
2. Argus MUST NOT request, receive, store, refresh, or display GitHub credentials. Provider commands MUST run without interactive authentication prompts.
3. Missing `gh`, unauthenticated-host, authorization, rate-limit, network, validation, not-found, timeout, and malformed-provider-response failures MUST remain distinguishable to the user.
4. A Repository Identity MUST be provider-qualified by provider, host, owner, and repository name. A Pull Request identity MUST combine that Repository Identity with a positive Pull Request number.
5. Review Work Mode MUST retain remote-capable Review Project records for hosted repositories that have no local checkout. Opening or synchronizing a Pull Request MUST reuse the matching Review Project or explicitly associated Named Project identity; it MUST NOT clone, fetch, create a Worktree Workspace, or infer a local association.
6. Review Work Mode MUST accept canonical HTTPS GitHub Pull Request URLs without user information, query, fragment, or port. A valid URL MUST load provider metadata before becoming a Saved Pull Request and opening or selecting its review tab.

### Inbox, Saved, and review tabs

1. The Review Inbox MUST contain the active account's GitHub review requests. Review Work Mode MUST show Inbox and Saved membership separately.
2. A Pull Request opened from a URL, an open review tab, or retained user-authored review state MUST be Saved. Inbox synchronization MUST NOT close a review tab or discard local authored state; an item that ceases to be in the Inbox but must be retained MUST become Saved.
3. Removing a Saved Pull Request MUST require confirmation and MUST identify any open tab or unsent reply and Pending Review content that will be discarded.
4. A Pull Request Review Tab MUST be identified by provider-qualified Pull Request identity. Opening an already open Pull Request MUST select its existing tab. Tabs MUST support selection, reordering, and closing within Review Work Mode.
5. Closing a Pull Request Review Tab MUST retain unsent replies and Pending Review content in Review Session State. Closing a tab MUST NOT publish content.
6. Each Pull Request Review Tab MUST provide Files, Activity, and Checks sections. Section selection, selected file, review layout, and authored content are tab-local.
7. The Files section MUST keep changed-file selection within the Pull Request Review Tab. It MUST show a diff for the selected file, explicit Viewed or Unviewed action, conversation state, and Pending Review state.
8. Argus MUST mark a file Viewed or Unviewed only after an explicit user action. It MAY show a pending state while GitHub synchronization is in progress; successful provider state becomes authoritative.

### Review revisions, conversations, and submission

1. A review tab MUST read one immutable Review Revision, consisting of its base and head commits, at a time. Diffs MUST read content for those exact provider commits and MUST NOT read a local checkout, index, or working tree.
2. When GitHub reports a new head commit, Argus MUST keep the loaded Review Revision visible, announce the update, and wait for explicit user action before replacing it.
3. Updating a Review Revision MUST preserve inline drafts where safely mapped by renamed path. Drafts without safe mapping MUST remain available and require remapping or explicit discard.
4. Published conversations MUST show their available comments and resolved, outdated, and permission state. Selecting a conversation MUST select its file and record its line anchor in native Review state. The current renderer does not programmatically scroll the WebKit diff body to that anchor.
5. A reply MUST remain local until the user explicitly sends it. A successful reply publishes immediately and is separate from a Pending Review. A failed send MUST retain the reply text and report the failure.
6. A new inline comment MUST be a local draft in one Pending Review for the loaded Review Revision. Drafts MUST remain local until review submission and MUST be distinguishable from published conversations.
7. A Pending Review MAY contain inline drafts, a summary, and one explicit Review Disposition: Approve, Comment, or Request Changes. Argus MUST NOT infer the disposition.
8. Review submission MUST require confirmation. Success MUST clear submitted Pending Review content and refresh the tab; failure MUST preserve authored content and report the provider error. Mode changes, refresh, revision updates, offline operation, and application termination MUST NOT silently submit authored content.

### Review persistence, cache, offline behavior, and safety

1. Review Session State MUST be independent from the Code Work Mode Session Snapshot and stored at `~/Library/Application Support/Argus/review-session.json`.
2. Review Session State MUST persist Review Projects, Pull Requests, selection, review tabs, section and file selection, Review Revisions, layout state, reply drafts, and Pending Review state. Provider payloads MUST NOT be authoritative session data.
3. User-authored Review Session State MUST use debounced atomic saves and flush at Review tab, Work Mode, and application lifecycle boundaries. If a session snapshot cannot be decoded, Argus MUST preserve a user-only corrupt copy before blocking automatic writes.
4. Complete provider reads MUST be cached separately at `~/Library/Caches/Argus/Review`. Cache cleanup MUST NOT delete Review Session State or authored drafts. Review Session State directories and files MUST use user-only permissions.
5. If a complete cached Review Revision is available after a provider read fails, Argus MUST make that cached revision available as stale content. Provider writes, including Viewed synchronization, replies, conversation resolution, and review submission, MUST remain unavailable while the tab is stale or blocked.
6. Provider URLs, repository fields, file paths, commit identifiers, and review anchors MUST be validated before use. `gh` commands MUST pass values as process arguments, not shell text. Error diagnostics MUST redact credential-like values and local configuration paths.
7. Review status, attention, Viewed state, draft state, and errors MUST have text or accessibility equivalents and MUST NOT rely on color alone.

## Panels, tabs, and panes

1. V1 supports Terminal, Browser, File, and Git Preview Panels.
2. A Workspace MUST maintain a Panel registry and use root Panel IDs to order Top-level Tabs.
3. New Terminal tabs MUST be appended and selected.
4. New Browser, File, and Git Preview Tabs SHOULD be inserted after the Active Tab and selected.
5. Terminal tab labels MUST default to `Terminal N`. A user-supplied terminal title MUST override the ordinal label.
6. Top-level Tabs MUST support selection, drag-and-drop reordering, explicit move actions, and close actions.
7. Opening the same File Tab or Git Preview Tab in one Workspace SHOULD select and refresh the existing tab instead of creating a duplicate.
8. Tab reuse MUST be scoped to the initiating Workspace.
9. Cmd+[ and Cmd+] MUST select the previous and next Top-level Tab with wraparound.
10. Cmd+W MUST close the Focused Pane when a terminal split has multiple panes; otherwise it MUST close the Active Tab.
11. Closing the final Terminal tab MUST require Workspace-close confirmation before changing state.

### Terminal splits

1. A terminal Top-level Tab MAY contain a recursive split tree of terminal Panes.
2. Exactly one Pane in the Active Tab MUST be focused for terminal input.
3. Cmd+D MUST split the Focused Pane vertically. Cmd+Shift+D MUST split it horizontally.
4. A new split SHOULD inherit the Focused Pane's Terminal Working Directory and become focused.
5. Closing a Pane in a multi-pane tab MUST collapse the remaining layout without closing the Top-level Tab.
6. Reordering or closing a Top-level Tab MUST operate on its complete split tree.

## Terminal runtime

1. Argus MUST use one process-wide Ghostty engine.
2. Each Terminal Panel MUST own one independent Terminal Surface.
3. Argus MUST load Ghostty default and recursive configuration before applying its bundled opaque-black terminal background override.
4. Terminal surfaces MUST retain user Ghostty configuration except for the Argus-owned background and background-opacity values.
5. Spawned shells MUST receive `ARGUS_SOCKET_PATH`, `ARGUS_WORKSPACE_ID`, and `ARGUS_SURFACE_ID`.
6. These variables identify the application socket, Workspace, and Terminal Surface for supported integrations. Their presence MUST NOT be treated as proof that a particular Agent Integration is enabled.
7. Argus MUST set terminal-identifying environment values and prepend existing supported Homebrew binary directories to `PATH`.
8. Terminal title and working-directory callbacks MUST update their Terminal Panel state on the main thread.
9. Inactive terminal surfaces SHOULD remain mounted during Top-level Tab changes. They MUST be occluded and prevented from stealing focus or accessibility interaction.
10. Terminal Working Directory MUST remain distinct from Workspace Root and Git Status Root.

## Right Sidebar

1. The Right Sidebar MUST contain the Files and Changes Right-sidebar Views.
2. Switching Right-sidebar Views MUST NOT change Workspace selection or Active Tab.
3. Asynchronous results MUST remain associated with the Workspace that initiated them.

## Titlebar

1. The Center Content Area Titlebar MUST identify the Selected Workspace and its Project or Standalone Workspace directory context.
2. Duplicate Workspace and context names SHOULD be shown once rather than repeated.
3. Available Git context MUST include the current branch, dirty state, and upstream ahead or behind counts.
4. The macOS window title MUST track the visible Workspace context for system surfaces such as Mission Control.

### Files View

1. The Files View MUST show a lazy Workspace File Tree rooted at the Selected Workspace's Workspace Root.
2. Directories MUST load their children when expanded rather than requiring the entire tree to be loaded initially.
3. Directories MUST sort before files at each level.
4. Workspace Items MUST use semantic file and folder icons; unknown files MUST use `doc`.
5. The Files View MUST support selection and Workspace Item Operations for open, copy, rename, and delete where applicable. File and directory context menus MUST support copying the Workspace Item path relative to the Workspace Root as plain text.
6. Destructive Workspace Item Operations MUST require confirmation.
7. Refreshing the same Workspace File Tree SHOULD retain the current tree while new data loads and MUST ignore stale asynchronous results.
8. File enumeration MUST remain bounded and disclose truncation when its display limit is reached.
9. Opening a file MUST create or reuse a File Tab in the initiating Workspace.
10. File Tabs MAY render source text, Markdown, native image formats, and SVG source or image preview according to file type and Panel-local controls.
11. Unsupported, binary, oversized, or failed content MUST show an in-tab state instead of opening another window.

### Changes View

1. The Changes View MUST resolve its Git Status Root from Workspace classification:
   - Worktree Workspace: worktree path;
   - Main-checkout Workspace: Project Repository Root;
   - Standalone Workspace: Workspace Root.
2. Git status and mutations MUST NOT follow a Terminal Panel's live Terminal Working Directory.
3. The Changes View MUST show branch and upstream information, ahead and behind counts, aggregate statistics, and Staged, Unstaged, and Untracked sections.
4. Git File Changes MUST show their status, path, and available addition/deletion statistics.
5. Changed paths MAY be grouped into a compacted Change Tree.
6. Displayed changes MUST be capped at 500 while section counts and Section Operations continue to represent the full Git Status Snapshot.
7. Git status MUST request individual untracked paths rather than treating an untracked directory as one opaque item.
8. A clean repository MUST show a clean state. A non-repository directory MUST offer Git initialization.
9. Refreshing the same Git Status Snapshot SHOULD keep current content visible and show progress in reserved chrome.
10. Changing the snapshot owner MAY replace content with an initial loading state.

### Change actions

1. Staged changes MUST offer unstage, diff, blame, and copy-path actions.
2. Unstaged changes MUST offer stage, discard, diff, blame, and copy-path actions.
3. Untracked changes MUST offer stage, delete, diff, and copy-path actions.
4. Applicable Section Operations MUST include stage all, unstage all, discard all, and delete all.
5. Discard and delete operations MUST require confirmation.
6. A completed Git Mutation MUST refresh the Git Status Snapshot.
7. Diff and blame actions MUST open Git Preview Tabs in the initiating Workspace.
8. Reopening the same Preview Kind, Git Status Root, and path SHOULD refresh and select its existing Git Preview Tab.

### Automatic Git refresh

1. Argus MUST use recursive FSEvents monitoring for the Git Status Root.
2. Normal filesystem changes MUST be debounced by approximately 300 milliseconds.
3. A completed refresh MUST start an approximately one-second cooldown for ordinary working-tree events.
4. Git metadata changes that would create index feedback loops MUST be suppressed.
5. Branch and ref changes received during cooldown MUST be deferred so the displayed branch cannot remain stale.

## Git worktrees

1. Git operations MUST use spawned `git` processes. Argus MUST NOT depend on libgit2.
2. Managed Worktrees MUST be stored under `~/.argus/worktrees/<project-uuid>/<branch-slug>/`.
3. Storage slugs MUST be lowercase, filesystem-safe, and hyphen-separated. Storage-path collisions MUST receive a numeric suffix.
4. Creating a new Worktree Workspace MUST reject a branch name that already exists. Storage-path suffixing MUST NOT be described as branch-name generation.
5. Existing local and remote branches MAY be selected for a Worktree Workspace.
6. Branch choices MUST exclude branches already checked out in another worktree.
7. Worktree removal MUST invoke `git worktree remove`; Project cleanup MAY force removal.
8. Argus MUST scan its managed storage for Orphaned Worktrees not represented by Workspace state.
9. Orphaned Worktrees MUST support adopt, delete, and dismiss actions.
10. "Delete Worktree and Close" MUST remove the worktree before deleting Workspace state.
11. If worktree removal fails, the Workspace MUST remain open and the underlying error MUST be shown.
12. Worktree deletion progress MUST reflect actual removal and Workspace-close operation boundaries.
13. V1 does not model Managed Worktree ownership separately from every possible external secondary worktree. Code MUST NOT infer safe deletion solely from the generic Worktree Workspace type.

## Browser Panels

1. Browser Panels MUST render with WebKit inside normal Workspace Top-level Tabs.
2. Browser chrome MUST include back, forward, reload, address, security, and loading controls.
3. Navigation controls MUST be disabled when their actions are unavailable.
4. Scheme-less addresses MUST default to HTTPS.
5. Configured search providers MAY transform non-URL input into a search URL.
6. Browser creation MUST apply global defaults unless an explicit Panel value is supplied.
7. Cmd+F MUST show find-in-page controls with match count and next/previous navigation.
8. Escape MUST dismiss the find overlay.
9. Background Browser Panels MUST NOT become first responder or steal application focus.
10. Browser Panels are runtime-only in the v1 Session Snapshot and are not restored.

## Agent Status

1. V1 MAY display process-local Agent Status Entries supplied through the in-process `AgentStatusStore`.
2. Agent Keys MUST be unrestricted strings.
3. Supported states are idle, running, needs input, and error, each with a distinct label, icon, and semantic color.
4. Agent Status MAY be scoped to a Workspace or Terminal Surface.
5. Per-panel Agent Status MUST override Workspace-level Agent Status for that Terminal Surface.
6. A loading indicator MUST take precedence over Agent Status in a Top-level Tab. Agent Status MUST take precedence over the default icon.
7. Agent Status Entries MUST remain ephemeral and MUST NOT be restored.
8. Argus MUST host a user-local Unix Domain Socket for the implemented `agent.turnCompleted` method. The Socket Server MUST use bounded newline-delimited JSON frames, restrictive permissions, structured responses, and current Workspace/Terminal Surface ownership validation without activating the app or changing focus.
9. A successful Turn Completion Event for an unviewed Top-level Tab MUST create runtime-only Turn Completion Attention on that tab and summarize it on the Workspace row. A completion in the Active Tab of the Selected Workspace while the main window is key MUST create neither attention nor sound.
10. Top-level Tab icon precedence MUST be loading, Turn Completion Attention, Agent Status, then the default icon. Workspace icon precedence MUST be Turn Completion Attention, Agent Status, then the Workspace-type icon.
11. Turn Completion Attention MUST clear when its Top-level Tab becomes viewed, and MUST be discarded when its tab or Workspace closes. It MUST NOT be restored from the Session Snapshot.
12. Agent settings MUST include an Agent completion sound preference that defaults to enabled and remains independent of Terminal audible bell behavior.
13. Kilo integration MUST be installed or removed only through explicit Settings controls. Argus MUST preserve unrelated Kilo JSON/JSONC configuration, own only its declaration and plugin file, surface setup errors, and require running Kilo sessions to restart after a change.
14. The Kilo TUI plugin MUST use public extension points only, accept successful root-turn completion after conservative non-synthetic, non-compaction user-turn filtering, ignore child, failed, interrupted, and idle-only events, and remain silent on delivery failure.
15. V1 still does not include functional Companion CLI commands, live external Agent Status updates, PID tracking, TTS, notification history, or macOS Notification Center notifications.

## Session persistence

1. Argus MUST store one JSON Session Snapshot at `~/Library/Application Support/Argus/session.json`.
2. The snapshot MUST use one schema version. An incompatible version MUST be discarded rather than migrated.
3. Empty snapshots and snapshots containing more than 128 Workspaces MUST be rejected.
4. Restore MUST reconcile Project and Workspace references, retain one Catch-all Project, remove stale references, and choose a valid Selected Workspace.
5. Project snapshots MUST include Project identity, repository metadata, ordering, expansion state, and optional color.
6. Workspace snapshots MUST include Workspace identity and type, Project association, branch and worktree metadata, Workspace Root, display title, the count used to reconstruct Terminal Panels, terminal custom titles, and per-terminal Terminal Working Directories.
7. Restored Terminal Panels MUST use their last observed Terminal Working Directory as the initial directory.
8. File Panels, Git Preview Panels, Browser Panels, split layouts, Active Tab, Focused Pane, Git Status Snapshots, and Agent Status Entries are runtime-only in v1.
9. Argus MUST synchronously save the Session Snapshot during normal application termination.
10. V1 does not provide periodic autosave. Work that requires a stronger durability boundary MUST add and verify it explicitly.
11. Restore MUST be skipped when disabled in Settings or by the supported test/restore environment overrides.

## Build and local installation

1. `scripts/build.sh` MUST build the app and, by default, the Companion CLI scaffold, bundle the CLI at `Contents/Resources/bin/argus` relative to the built application, and ad-hoc sign the result.
2. Debug MUST remain the default configuration; `--release` MUST select Release.
3. The build script MUST support build, web-asset rebuild, CLI-only build, run, install, clean, and Xcode-project generation commands.
4. Normal app builds MUST use the committed Pierre diff renderer bundle and MUST NOT require Node.js.
5. Rebuilding that bundle MUST use the pinned `ArgusWeb` dependencies. The generated bundle MUST be the only tracked artifact changed by the rebuild.
6. Run and install operations MUST ask a running Argus instance to quit, wait up to approximately five seconds, and then terminate it if needed.
7. Launching a newly built app MUST strip inherited Argus identity environment variables.
8. V1 build tooling does not check for active coding-agent processes before replacing the app.

## Known v1 limitations

- The Companion CLI is a versioned scaffold and has no socket-backed commands; the application socket currently implements only `agent.turnCompleted`.
- Kilo's public extension API cannot prove that every ordinary non-synthetic user message was authored interactively by a person, so completion provenance uses conservative best-effort filtering.
- Nonterminal Panels, split layout, and current tab/focus state are not restored.
- Session persistence occurs on normal application termination; there is no periodic autosave.
- Worktree ownership is not represented independently from Workspace type.
