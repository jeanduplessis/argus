# Argus Application

## Status

Draft — reverse-engineered from implementation plan on 2026-03-25.

## Conventions

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
"SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and
"OPTIONAL" in this document are to be interpreted as described in
BCP 14 [RFC 2119] [RFC 8174] when, and only when, they appear in all
capitals, as shown here.

## Overview

Argus is a macOS terminal workspace manager built on the Ghostty
terminal rendering engine. It organizes work into projects backed by
git worktrees, provides a real-time git status sidebar with file
operations, embeds browser panels alongside terminals, tracks AI agent
status via a socket API with text-to-speech notifications, and persists
full session state across restarts. The application runs as a single
native macOS process with an embedded socket server and companion CLI
tool.

---

## Rules

### Terminal Rendering

1. The system MUST render terminal content using GPU-accelerated
   compositing via the Ghostty terminal engine.

2. The system MUST read terminal configuration (font, theme,
   keybindings) from Ghostty-compatible configuration files at the
   standard Ghostty configuration path.

3. The system MUST manage exactly one global terminal engine instance
   for the application lifetime, shared across all terminal panels.

4. Each terminal panel MUST own an independent terminal surface that
   handles its own input, output, and rendering.

5. The system MUST inject environment variables into every spawned
   shell session identifying the socket path, the current workspace
   identifier, and the current surface identifier.

6. The system MUST ensure the shell PATH includes standard package
   manager directories so that tools such as git extensions are
   discoverable from within terminal sessions.

### Window and Layout

1. The application MUST present a single main window.

2. The main window MUST use a three-column layout: a left sidebar, a
   central content area, and a right git sidebar.

3. The main window MUST use a custom transparent titlebar with
   full-size content view mode, allowing content to extend into the
   titlebar area.

4. The left sidebar MUST be toggleable and user-resizable within a
   range of 80 pixels to 33% of the window width, with a default
   width of 200 pixels.

5. The right git sidebar MUST be toggleable and user-resizable within
   a range of 180 to 600 pixels, with a default width of 250 pixels.

6. Draggable dividers MUST separate the three columns, with a hit
   zone of at least 6 pixels for comfortable mouse targeting.

7. The central content area MUST fill the remaining horizontal space
   between the two sidebars.

8. The left sidebar visibility and width MUST persist across sessions.

9. The right git sidebar visibility and width MUST persist across
   sessions.

### Workspaces

1. The system MUST organize terminal and browser panels into
   workspaces, where each workspace contains an ordered list of
   tabbed panels.

2. Each workspace MUST display a tab bar showing all top-level tabs.
   Terminal tabs MUST default to labels based on ordinal position as
   "Terminal 1", "Terminal 2", and so on, rather than by working
   directory or process title. A user-assigned terminal title MUST take
   precedence over the ordinal label.

3. Exactly one top-level tab per workspace MUST be active at a
   time; selecting a tab MUST switch the active tab. A terminal tab
   MAY contain multiple split panes, but exactly one pane MUST be
   focused for keyboard input at a time.

4. The tab bar MUST provide a button to create a new terminal panel
   within the current workspace. New terminal tabs MUST be appended to
   the end of the tab order and selected.

5. Each tab MUST provide a close button to remove the panel from the
   workspace. Terminal tabs MUST provide a context menu with Close and
   Rename actions.

6. Tabs MUST be reorderable within a workspace via drag and drop.

7. The system MUST allow creating new workspaces, each starting with
   a single terminal panel.

8. The system MUST allow closing workspaces. When the last workspace
   is closed, the system MUST create a new empty workspace
   automatically.

9. The system MUST allow renaming workspaces. The default workspace
   name SHOULD be derived from the shell's working directory or
   process title.

10. The system MUST support selecting workspaces 1 through 8 via
    keyboard shortcuts (Cmd+1 through Cmd+8), using global sidebar
    order across all projects, and Cmd+9 to select the last workspace.

11. The system MUST support keyboard shortcuts to create a new
    workspace, create a new tab, and close the current tab or focused
    split pane.

12. The system MUST support splitting the focused terminal pane
    vertically with Cmd+D and horizontally with Cmd+Shift+D.

### Projects

1. The system MUST allow users to create a project from any directory
   that is a valid git repository.

2. The system MUST reject project creation if the target directory is
   not a git repository.

3. The system MUST reject project creation if a project already exists
   for the same repository path.

4. The system MUST automatically detect the main branch of the
   repository when creating a project, trying symbolic references
   first, then common branch names ("main", "master"), then the
   current HEAD.

5. The system MUST assign a display name to each project, defaulting
   to the repository directory name if no custom name is provided.

6. Each project MUST maintain an ordered list of child workspace
   references.

7. The system MUST maintain exactly one "catch-all" project that
   adopts any workspaces not assigned to a named project.

8. The catch-all project MUST NOT be removable by the user.

9. When a named project is removed, the system MUST also remove all
   of its child workspaces and clean up associated worktrees.

10. Projects MUST support an expand/collapse state in the sidebar that
    persists across sessions.

11. Projects MAY have a custom color for visual identification in the
    sidebar.

12. The system MUST allow renaming projects.

13. Each project MUST be assigned an immutable, globally unique
    identifier (UUID) at creation time. This identifier MUST be used
    as the stable key for worktree storage paths and cross-references.
    The project display name is mutable and MUST NOT be used as a
    storage key.

14. The worktree storage path MUST use the project's stable identifier,
    not its display name or repository basename:
    `~/.argus/worktrees/<project-uuid>/<branch-slug>/`.

### Sidebar Hierarchy

1. The left sidebar MUST display items in a two-level hierarchy:
   projects as collapsible headers and workspaces as children within
   projects.

2. Standalone workspaces (those not assigned to any project) MUST
   appear under the catch-all project.

3. Each sidebar workspace item MUST indicate whether it is the main
   checkout, a worktree, or an external directory when it belongs to
   a project.

4. The system MUST reconcile project-to-workspace and
   workspace-to-project cross-references after session restore to
   ensure bidirectional consistency.

5. Workspaces MUST be reorderable within a project via drag and drop.

6. The sidebar MUST display the git branch name for each workspace
   that has a git context.

7. The sidebar MUST display the agent status icon for each workspace
   that has an active agent status entry.

8. The sidebar MUST highlight the currently active workspace with a
   distinct selection indicator.

9. The sidebar MUST show a hover highlight on workspace rows.

10. Project headers MUST provide a context menu with options to
    rename the project, add a workspace, and remove the project.

11. Workspace rows MUST provide a context menu with options to
    rename, close, and reorder the workspace.

### File Tabs

1. Binary image files supported by the native image decoder MUST render an
   image preview in their File Tab instead of the generic binary-file state.

2. SVG files MUST provide source and image-preview displays in their File Tab.

### Git Worktrees

1. The system MUST create isolated git worktrees when users create
   new workspaces within a project, placing them at a well-known
   directory under the application's worktree storage path
   organized by project slug and branch name.

2. The system MUST slugify workspace or branch names into
   filesystem-safe, git-compatible branch names (lowercase,
   hyphen-separated, no special characters).

3. The system MUST generate a unique branch name with a numeric
   suffix if the desired branch name already exists.

4. The system MUST support creating worktrees from existing remote
   or local branches.

5. When removing a worktree, the system MUST invoke the git worktree
   removal operation; force removal MUST be used for programmatic
   cleanup (such as project deletion).

6. The system MUST detect and enumerate orphaned worktrees on disk
   that have no corresponding workspace data.

7. The system MUST list available branches for worktree creation,
   excluding branches already checked out in existing worktrees.

8. On application launch, the system MUST scan for orphaned
   worktrees on disk that have no corresponding workspace data.

9. When orphaned worktrees are found, the system MUST present a
   non-blocking dialog listing them, allowing the user to adopt
   (re-create a workspace), delete, or dismiss (defer) each one.

### Git Status Sidebar

1. The system MUST provide a toggleable git status sidebar panel on
   the right side of the window.

2. The git sidebar MUST track the worktree root directory (or the
   project repository root for main-checkout workspaces) of the
   active workspace. It MUST NOT attempt to follow the terminal
   session's live working directory; shell integration is deferred.

3. The git sidebar MUST display the current branch name and upstream
   tracking information (ahead/behind commit counts).

4. The git sidebar MUST organize changed files into three collapsible
   sections: staged, unstaged, and untracked.

5. Each file entry MUST display an icon and color corresponding to
   its status (added, modified, deleted, renamed, copied,
   type-changed, untracked).

6. Each file entry MUST show per-file diff statistics (lines added
   and removed).

7. The system MUST automatically refresh git status when files change,
   using recursive filesystem event monitoring (FSEventStream) over
   the worktree root with a debounce interval of at least
   300 milliseconds.

8. The system MUST suppress refresh events caused by git's own
   internal file changes (such as index updates) to prevent feedback
   loops.

9. The system MUST enforce a cooldown period of at least one second
   after a refresh completes before allowing another
   filesystem-event-triggered refresh.

10. The system MUST cap the number of displayed files at 500 to
    prevent rendering slowdowns in large repositories.

11. The system MUST expand untracked directories to enumerate their
    individual child files for display.

12. Each section header MUST display the file count for that section.

13. The git sidebar MUST display a loading indicator during refresh
    operations.

14. The git sidebar MUST provide a manual refresh button.

### Git File Operations

1. The system MUST provide hover-based action buttons for each file
   in the git sidebar.

2. For staged files, the system MUST offer unstage, diff, blame, and
   copy-path actions.

3. For unstaged files, the system MUST offer stage, discard, diff,
   blame, and copy-path actions.

4. For untracked files, the system MUST offer stage, delete, diff,
   and copy-path actions.

5. Destructive operations (discard changes, delete file) MUST require
   explicit user confirmation before execution.

6. The system MUST provide section-level bulk actions: stage all,
   unstage all, discard all, delete all.

7. Bulk destructive operations MUST require user confirmation.

8. The system MUST refresh git status immediately after any file
   operation completes.

9. The system MUST offer a diff preview that opens as a tab in the
   central content area and displays colorized diff output.

10. The system MUST offer a blame preview that opens as a tab in the
    central content area and displays colorized blame output.

11. Preview tabs MUST use the workspace tab lifecycle, including tab
    selection, reordering, and closing.

12. Reopening the same preview SHOULD refresh and select its existing
    tab instead of creating a duplicate tab.

13. If the current directory is not a git repository, the sidebar MUST
    offer to initialize one.

14. When the working tree is clean, the sidebar MUST display a "clean
    working tree" indicator.

### Browser Panels

1. The system MUST support embedded browser panels that render web
   pages within a workspace tab alongside terminal panels.

2. Each browser panel MUST include an address bar with a URL input
   field, back button, forward button, and reload button.

3. The back and forward buttons MUST be visually disabled when there
   is no navigation history in the respective direction.

4. The address bar MUST display an HTTPS indicator when the current
   page uses a secure connection.

5. Browser panels MUST support find-in-page functionality, activated
   via a keyboard shortcut, with a floating search overlay showing
   match count and next/previous navigation.

6. The find-in-page overlay MUST be dismissible with the Escape key.

7. Background browser panels MUST NOT steal application focus (for
   example, via JavaScript autofocus).

### Titlebar Display

1. The titlebar MUST display the workspace name.

2. The titlebar MUST display additional context: the project name
   (if the workspace belongs to a project) or the directory basename
   (for standalone workspaces).

3. The workspace name SHOULD be omitted from the titlebar when it is
   identical to the context name.

4. The titlebar MUST display the current git branch name when
   available.

5. The titlebar MUST display a dirty indicator when the working tree
   has uncommitted changes.

6. The titlebar MUST display ahead/behind commit counts relative to
   the upstream branch when upstream tracking exists.

7. The window title (visible in Mission Control and the Dock) MUST be
   updated to reflect the titlebar content.

### Session Persistence

1. The system MUST persist durable application state to disk,
   including the window, workspace metadata, projects, sidebar state,
   and panel types with explicit persistence requirements below.

2. The system MUST autosave at regular intervals of approximately
   8 seconds during typing-quiet periods.

3. On application termination, the system MUST write the session
   synchronously to ensure data persists before exit.

4. On launch, the system MUST attempt to restore the previous session
   unless restore is explicitly disabled via environment variable or
   the application was launched with file or URL arguments.

5. The system MUST NOT restore session state when running under
   automated test environments.

6. Project snapshots MUST include the project identifier, name,
   repository path, main branch, expand/collapse state, workspace
   identifiers, optional custom color, and catch-all flag.

7. Workspace snapshots MUST include the project identifier, worktree
   path, and worktree branch name when the workspace belongs to a
   project.

8. Status entries, agent PIDs, and other ephemeral runtime state MUST
    NOT be restored across app restarts, as the associated processes
    no longer exist.

9. Browser panels MUST persist and restore the current URL, page zoom
    level, and developer tools visibility.

10. The session format MUST use a single schema version. The system
    MUST NOT implement schema migration; if the snapshot version does
    not match, the system MUST discard it and start fresh.

11. The system MUST enforce resource limits during persistence: a
    maximum of 128 workspaces. The persistence schema SHOULD model
    a window array for forward-compatibility with multi-window
    support, but v1 MUST contain exactly one window entry. The
    schema-level cap is 12 windows and 128 workspaces per window.

### IPC and CLI

1. The system MUST provide an embedded Unix domain socket server
   within the application process, listening at a well-known path
   under the application's data directory.

2. The socket protocol MUST use newline-delimited JSON (JSON Lines)
   for both requests and responses.

3. Each request MUST include a method field and MAY include an
   identifier for request/response correlation.

4. Error responses MUST include a structured error with a code and
   human-readable message.

5. The system MUST provide a companion CLI tool that communicates
   with the application via the socket.

6. The CLI MUST auto-discover the socket path, checking the
   well-known path and falling back to environment variable
   overrides.

7. Socket and CLI commands MUST NOT steal macOS application focus or
   raise windows as a side effect.

8. Only commands with explicit focus intent (workspace select, panel
   focus) MAY mutate in-app focus state.

9. Status and telemetry commands MUST be processed off the main
   thread; UI mutations MUST be dispatched asynchronously to the main
   thread only when necessary.

10. High-frequency telemetry commands MUST NOT use synchronous
    main-thread dispatch.

11. The system MUST deduplicate identical status updates to prevent
    update storms from rapid-fire telemetry.

12. The CLI MUST provide commands for project creation, listing, and
    removal.

13. The CLI MUST provide commands for workspace and panel management
    including creation, listing, selection, closing, and renaming.

### Agent Integration

1. The socket API for agent integration MUST be agent-agnostic: any
   agent key string MUST be accepted for status, PID, and
   notification commands without restriction.

2. The system MUST provide a reference plugin for Kilo Code that
   translates agent lifecycle events into status updates and
   notifications. This plugin serves as the reference implementation
   for other agent integrations.

3. The reference plugin MUST only activate when the socket path
   environment variable is present; it MUST be a no-op when running
   outside the terminal application.

4. The reference plugin MUST update the sidebar status entry for the
   current terminal panel when the agent transitions between states:
   idle, running, needs input, and error.

5. Each status state MUST have a distinct icon and color for visual
   differentiation.

6. The reference plugin MUST send a notification when the agent
   completes work, encounters an error, or requests user permission.

7. The reference plugin MUST debounce completion notifications for at
   least 3 seconds to account for sub-agent idle events that precede
   continued work.

8. The reference plugin MUST register the agent process ID with the
   application to enable suppression of redundant operating-system-
   level notifications.

9. The reference plugin MUST clear its status entry and deregister
   its process ID when the agent process exits.

10. The reference plugin MAY provide verbose status descriptions when
    an environment variable is set, showing tool-level detail instead
    of generic state labels.

### Agent Process Lifecycle

1. The system MUST periodically sweep agent process IDs to detect
   crashed or terminated agent processes.

2. The sweep interval MUST be approximately 30 seconds.

3. When a stale agent PID is detected, the system MUST clear any
   associated status entries for that agent.

4. The sweep MUST run on a background queue, not on the main thread.

5. The system MUST track agent PIDs at both the workspace level and
   the individual panel level.

### Agent Status Display

1. When an agent has an active status entry with an icon, the system
   MUST display that icon on the corresponding workspace tab,
   replacing the default tab icon.

2. The system MUST resolve the effective status icon per panel by
   checking per-panel status entries first, then falling back to
   workspace-level status entries.

3. Agent status icons MUST be tinted with the color specified in the
   status entry.

4. Agent status icons MUST take priority over default tab icons but
   MUST NOT take priority over loading indicators (such as browser
   page loads).

5. The system MUST synchronize agent status icons to tabs whenever
   status entries are mutated, stale agent PIDs are swept, or
   workspace reconciliation occurs.

### Per-Panel Status

1. The system MUST support status entries scoped to individual panels
   (terminal surfaces) in addition to workspace-level status entries.

2. When multiple agents run in different panels of the same workspace,
   each panel's status MUST be independently trackable.

3. Per-panel status entries MUST display the panel label for
   disambiguation when multiple panels have active status.

4. When only one panel has status entries, the system SHOULD omit the
   panel label for cleaner display.

5. The socket API MUST accept a surface identifier to scope status
   operations to a specific panel, falling back to the surface-ID
   environment variable if not provided.

6. Workspace-level status (no surface identifier) MUST continue to
   work alongside per-panel entries.

### Text-to-Speech Notifications

1. The system MAY announce agent events via text-to-speech when a TTS
   binary is available at the expected path.

2. The system MUST NOT fall back to system speech synthesis or other
   TTS mechanisms when the expected binary is not found; TTS is
   opt-in by installing the binary.

3. TTS announcements MUST be fire-and-forget; failures MUST NOT block
   event processing.

4. The system MUST announce when an agent needs user approval,
   including the workspace number and project name.

5. The system MUST announce when an agent completes work or encounters
   an error.

6. The workspace number in announcements MUST be the 1-based workspace
   index.

### Build and Deployment

1. A build script MUST exist that compiles the application in release
   configuration, bundles the CLI tool, and ad-hoc codesigns the
   result.

2. The build script MUST check for active AI agent processes before
   replacing the installed application, unless force mode is
   specified.

3. The build script MUST gracefully quit the running application
   (triggering session save) before replacement, waiting up to
   10 seconds before escalating to forced termination.

4. The build script MUST strip application-specific environment
   variables when relaunching the application to prevent environment
   inheritance.

---

## Error Handling

1. When project creation fails due to an invalid repository path, the
   system MUST return an error indicating the directory is not a git
   repository.

2. When project creation fails because a project already exists for
   that repository, the system MUST return a duplicate-project error.

3. When main branch detection fails, the system MUST return a specific
   branch-detection-failed error rather than silently defaulting.

4. When session restore encounters an incompatible snapshot version,
   the system MUST discard the snapshot entirely and start fresh.

5. When session restore encounters a snapshot with no workspaces, the
   system MUST discard it and start fresh.

6. When the git status service encounters a directory that is not a
   git repository, it MUST offer repository initialization rather
   than displaying an error.

7. When the agent integration plugin fails to communicate with the
   socket, it MUST fail silently without affecting the agent's
   primary operation.

8. When TTS announcements fail (binary not found or execution error),
   the system MUST silently continue without alerting the user.

9. When a worktree removal fails, the system MAY retry with force
   removal for programmatic cleanup scenarios.

10. When filesystem event monitoring triggers during a cooldown period,
    the system MUST suppress the redundant refresh.

11. When the CLI cannot connect to the socket (application not
    running), it MUST report a connection error and exit with a
    non-zero status code.

---

## Open Questions

- ~~Should workspace numbering for keyboard shortcuts (1–8, 9 for last)
  use a global index across all workspaces, or a project-scoped index?~~
  **Resolved**: v1 uses **global indexing** — Cmd+1 through Cmd+8
  select workspaces 1–8 in sidebar order across all projects, and
  Cmd+9 selects the last workspace. This is simpler for a single-window
  application. Project-scoped indexing may be revisited if multi-window
  or many-project workflows demand it.

- Should the system support creating a browser panel from the CLI/socket
  API, or only from the in-app UI? The implementation plan lists
  browser panels as a feature but the CLI commands focus on workspace
  and status management.

- What should happen when the user quits the application while agent
  processes are still running? Should the quit be blocked, warned, or
  allowed silently? The build script checks for agents before
  replacement, but normal quit behavior is unspecified.

- ~~Should the git status sidebar track the working directory of the
  focused terminal panel, or the project root?~~ **Resolved**: In v1,
  the git status sidebar MUST track the worktree root (or project
  repository root for main-checkout workspaces), NOT the terminal's
  live working directory. Shell integration is deferred, so there is
  no reliable mechanism to track `cd` within the shell. Directory
  tracking via shell hooks may be added in a future version.

- What is the maximum number of child files enumerated for untracked
  directories before truncation? The original cmux implementation
  capped this, but the exact limit for Argus is unspecified.
