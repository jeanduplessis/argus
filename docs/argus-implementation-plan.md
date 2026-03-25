# Argus — Implementation Plan

## Status

Draft — 2025-03-25.

---

## Project Overview

Argus is a lightweight, personal macOS terminal workspace manager built on
libghostty. It takes the features valued most from a cmux fork — project/worktree
management, git status sidebar, agent integration, browser panels, and session
persistence — and implements them in a focused, single-purpose application
without the complexity of maintaining a fork.

This is a personal project. It runs on macOS only, will not be distributed,
and should not be over-engineered. Simplicity and correctness for a single
user are the priorities.

---

## Tech Stack

| Layer              | Technology                        | Rationale                                                                 |
|--------------------|-----------------------------------|---------------------------------------------------------------------------|
| Terminal engine    | GhosttyKit.xcframework (libghostty) | GPU-accelerated Metal rendering. Non-negotiable requirement.            |
| App framework      | Swift 6 + SwiftUI                 | Native macOS, reactive UI. Same approach as cmux.                        |
| Window management  | AppKit (NSWindow, NSView)         | Required for GhosttyKit NSView rendering and custom titlebar.            |
| Browser panels     | WKWebView                         | Native WebKit integration.                                               |
| IPC                | Embedded Unix socket server (Swift) | Single-process, no Zig daemon. JSON lines protocol only.               |
| CLI                | Swift Argument Parser              | Lightweight CLI binary for socket communication.                         |
| Build              | Xcode project + Swift PM (deps only) | Xcode project for app target (bridging header, framework linking); Swift PM for CLI dependencies (Swift Argument Parser). No Zig toolchain needed at build time (pre-built GhosttyKit). |
| Git operations     | Process spawning (`git` CLI)      | Simple, reliable, no libgit2 dependency.                                 |
| File watching      | FSEvents (`FSEventStream` API)    | Native macOS recursive directory monitoring. Note: `DispatchSource.makeFileSystemObjectSource` only watches a single file descriptor and is NOT suitable for repository-wide change detection. |
| Persistence        | JSON (Codable)                    | Session state to `~/Library/Application Support/Argus/`.                |
| TTS                | External binary (user-installed)  | Fire-and-forget announcements. Opt-in only — no fallback to `say` or system speech synthesis. |

### What We Are NOT Using (vs cmux)

- No Zig toolchain (pre-built GhosttyKit only)
- No Bonsplit (no split panes in v1; simple tab model instead)
- No Sparkle (no auto-update — personal project)
- No Sentry/PostHog (no analytics/crash reporting)
- No localization (English only)
- No V1 text protocol (JSON lines only — simpler)
- No separate daemon process (no cmuxd equivalent)

---

## Architecture

```
Argus.app
├── ArgusApp (@main, SwiftUI)
│   ├── AppDelegate (NSApplicationDelegate)
│   │   ├── Window lifecycle
│   │   ├── Socket server start/stop
│   │   ├── Session save on quit
│   │   └── Menu bar
│   │
│   ├── MainWindowView
│   │   ├── Sidebar (left, toggleable)
│   │   │   ├── Project headers (collapsible)
│   │   │   └── Workspace rows
│   │   ├── ContentArea (center)
│   │   │   ├── Tab bar (terminal + browser tabs)
│   │   │   └── Active panel (terminal or browser)
│   │   ├── GitSidebar (right, toggleable)
│   │   └── Titlebar (custom overlay)
│   │
│   ├── Models
│   │   ├── Project
│   │   ├── Workspace
│   │   ├── Panel (protocol: Terminal | Browser)
│   │   └── GitStatus
│   │
│   ├── Services
│   │   ├── WorkspaceManager
│   │   ├── WorktreeService
│   │   ├── GitStatusService
│   │   ├── SocketServer
│   │   ├── SessionManager
│   │   ├── AgentTracker
│   │   └── TTSService
│   │
│   └── Ghostty Integration
│       ├── GhosttyApp (singleton, ghostty_app_t lifecycle)
│       ├── TerminalSurface (ObservableObject, ghostty_surface_t)
│       ├── TerminalView (NSViewRepresentable wrapping GhosttyNSView)
│       └── GhosttyConfig (config loading, theme resolution)
│
├── argus CLI (separate target)
│   ├── SocketClient (connect, send JSON, read response)
│   └── Commands
│       ├── Project commands (create, list, remove, rename)
│       ├── Workspace commands (create, list, select, close, rename)
│       ├── Panel commands (create, list, focus, close)
│       ├── Status commands (set-status, clear-status, set-agent-pid, clear-agent-pid)
│       └── Notification commands (notify, clear-notifications)
│
└── GhosttyKit.xcframework (pre-built, vendored)
```

---

## Source Directory Structure

```
argus/
├── Argus/                          # Main app target
│   ├── App/
│   │   ├── ArgusApp.swift
│   │   └── AppDelegate.swift
│   ├── Views/
│   │   ├── MainWindowView.swift
│   │   ├── Sidebar/
│   │   ├── Content/
│   │   ├── GitSidebar/
│   │   └── Titlebar/
│   ├── Models/
│   │   ├── Project.swift
│   │   ├── Workspace.swift
│   │   └── Panel.swift
│   ├── Services/
│   │   ├── WorkspaceManager.swift
│   │   ├── WorktreeService.swift
│   │   ├── GitStatusService.swift
│   │   ├── SocketServer.swift
│   │   ├── SessionManager.swift
│   │   ├── AgentTracker.swift
│   │   └── TTSService.swift
│   ├── Ghostty/
│   │   ├── GhosttyApp.swift
│   │   ├── TerminalSurface.swift
│   │   ├── TerminalView.swift
│   │   └── GhosttyConfig.swift
│   ├── Browser/
│   │   ├── BrowserPanel.swift
│   │   └── BrowserView.swift
│   └── Resources/
│       └── Argus-Bridging-Header.h
├── ArgusCLI/                       # CLI target
│   ├── main.swift
│   ├── SocketClient.swift
│   └── Commands/
│       ├── Project/                # create, list, remove, rename
│       ├── Workspace/              # create, list, select, close, rename
│       ├── Panel/                  # create, list, focus, close
│       ├── Status/                 # set-status, clear-status, set-agent-pid, clear-agent-pid
│       └── Notification/           # notify, clear-notifications
├── Frameworks/
│   ├── GhosttyKit.xcframework
│   └── module.modulemap            # Clang module map for non-bridging-header contexts
├── docs/
├── Argus.xcodeproj/              # Xcode project (app + CLI targets)
├── Package.swift                 # SPM manifest for CLI dependencies only (Swift Argument Parser)
└── scripts/
    └── build.sh
```

---

## Key Design Decisions

### 1. Tabs Instead of Split Panes (v1)

Each workspace has a tab bar with terminal and browser panels. No recursive
split layout. This dramatically simplifies the layout engine. Split panes can
be added later — the panel model is designed to be embeddable in either a tab
bar or a split tree.

### 2. JSON-Only Socket Protocol

cmux supports both V1 (text) and V2 (JSON) for backward compatibility.
Since Argus is new, we implement JSON lines only. Simpler parsing,
structured errors, easier to extend.

### 3. Pre-Built GhosttyKit

We vendor `GhosttyKit.xcframework` rather than building from source. Build it
once from the Ghostty source (from the cmux repo's `ghostty/` submodule) and
place it in `Frameworks/`. This eliminates the Zig toolchain from the
development workflow.

### 4. Single Process (No Daemon)

The socket server runs inside the app process. The CLI connects to it
directly. No cmuxd equivalent. If the app is not running, the CLI gets a
connection error — acceptable for a personal tool.

### 5. Ghostty Configuration Compatibility

Argus reads Ghostty-compatible config files (`~/.config/ghostty/config`) for
terminal settings (font, theme, keybindings). No need to reinvent
configuration — reuse Ghostty's format.

### 6. Storage Locations

| Data       | Location                                           |
|------------|----------------------------------------------------|
| Session    | `~/Library/Application Support/Argus/session.json` |
| Worktrees  | `~/.argus/worktrees/<project-uuid>/<branch-slug>/`  |
| Socket     | `~/.argus/argus.sock`                              |
| Config     | Uses Ghostty config for terminal settings          |

---

## GhosttyKit Integration Strategy

Based on the cmux codebase at `/Users/jdp/Development/jeanduplessis/cmux`,
here is how the integration works and how we will port it.

### Obtaining GhosttyKit

Build from the Ghostty source in the cmux repo's `ghostty/` submodule, or
copy the existing built framework. Vendor it in `Frameworks/`.

### Bridging Header and Module Map

The Xcode app target uses an Objective-C bridging header
(`Argus-Bridging-Header.h`) that imports `ghostty.h`, exposing the C API
to Swift. This is an **Xcode target feature** — it does not work with
pure SwiftPM targets. The Xcode project manages the app target directly;
SwiftPM is used only for resolving CLI dependencies (Swift Argument
Parser).

A Clang `module.modulemap` is vendored alongside `GhosttyKit.xcframework`
so the framework can also be imported as a module in contexts where a
bridging header is not available (e.g., unit test targets).

### Core Types to Port (Adapted, Not Copied Verbatim)

| cmux Type          | Argus Equivalent   | Role                                                    |
|--------------------|--------------------|---------------------------------------------------------|
| `GhosttyApp`       | `GhosttyApp`       | Singleton managing `ghostty_app_t` lifecycle, config, tick loop |
| `TerminalSurface`  | `TerminalSurface`  | `ObservableObject` wrapping `ghostty_surface_t`, terminal I/O  |
| `GhosttyNSView`    | `TerminalNSView`   | `NSView` subclass for Metal rendering, keyboard/mouse input    |
| Config loading      | `GhosttyConfig`    | Read Ghostty config files, resolve themes                      |

### Simplifications vs cmux

- No split pane coordination (simpler surface lifecycle)
- No Bonsplit integration (tabs only)
- No copy mode overlay (can add later)
- No clipboard image conversion
- No shell integration features initially

---

## Feature Phases

### Phase 1: Foundation — Terminal + Workspaces

Get a working terminal app with tabbed workspaces.

1. **Xcode project setup** — Xcode project with two targets: app
   (Argus) and CLI (argus). GhosttyKit.xcframework linked to the app
   target with an Objective-C bridging header importing `ghostty.h`.
   Swift Argument Parser added via SPM dependency for the CLI target.
2. **GhosttyKit integration** — Port the core Swift wrappers from cmux:
   `GhosttyApp`, `TerminalSurface`, `TerminalNSView`, Metal rendering
   layer. Adapt for Argus naming and simplified lifecycle.
3. **Window shell** — Custom titlebar (transparent, full-size content),
   three-column layout (sidebar | content | git sidebar), draggable
   dividers.
4. **Workspace model** — `Workspace` with tabs (panels),
   `WorkspaceManager` for CRUD, tab selection, reordering.
5. **Sidebar** — Flat list of workspaces (no projects yet), selection
   state, context menu (rename, close).
6. **Tab bar** — Per-workspace tab bar showing terminal panels, + button
   for new tab, close buttons.
7. **Keyboard shortcuts** — Cmd+N (new tab), Cmd+W (close tab), Cmd+T
   (new workspace). Cmd+1–8 select workspaces by **global sidebar
   index** (across all projects), Cmd+9 selects the last workspace.

### Phase 2: Projects + Git Worktrees

Add the project hierarchy and worktree management.

1. **Project model** — `Project` with immutable UUID (assigned at
   creation, used as storage key), repo path, display name (mutable),
   main branch detection, ordered workspace IDs, expand/collapse,
   optional color.
2. **Catch-all project** — One per window, non-removable, adopts
   unassigned workspaces.
3. **Sidebar hierarchy** — Two-level tree (project headers → workspace
   children), drag-and-drop reordering.
4. **Worktree management** — Create worktrees at
   `~/.argus/worktrees/<project-uuid>/<branch-slug>/`. Each project
   is assigned an immutable UUID at creation time; the UUID is the
   stable storage key (not the display name or repo basename, which
   are mutable and can collide). Slugify branch names into
   filesystem-safe strings, generate unique names with numeric
   suffixes when needed.
5. **New workspace dialog** — Choose new branch or existing branch,
   worktree creation.
6. **Orphan detection** — Scan on launch, dialog to adopt/delete/dismiss
   orphaned worktrees.
7. **Project CRUD** — Create from directory (validate git repo), remove
   (cleanup worktrees), rename.

### Phase 3: Git Status Sidebar

Real-time git status with file operations.

1. **Git status parsing** — `git status --porcelain=v2 --branch` parser,
   diff stats via `git diff --numstat`. **The git root is always the
   workspace's worktree root (or project repo root for main-checkout
   workspaces) — it does NOT follow the terminal's live cwd.** Shell
   integration is deferred to post-v1.
2. **FSEventStream watcher** — Use the `FSEventStream` C API (via
   `FSEventStreamCreate`) to recursively monitor the worktree root
   directory. Apply 300 ms debounce (via `latency` parameter),
   1 s post-refresh cooldown in the callback, and filter out events
   under `.git/` to prevent feedback loops. Do NOT use
   `DispatchSource.makeFileSystemObjectSource` — it monitors a single
   file descriptor and cannot provide the recursive directory-wide
   change stream required here.
3. **Sidebar UI** — Branch info bar (name, ahead/behind), three
   collapsible sections (staged/unstaged/untracked), file rows with
   status icons and diff stats.
4. **File operations** — Stage, unstage, discard, delete with hover
   action buttons. Bulk section operations. Confirmation dialogs for
   destructive actions.
5. **Diff/Blame preview** — Floating NSPanel with colorized git output
   (`git diff --color` or difftastic if available,
   `git blame --color-lines`).
6. **Clean/not-repo states** — "Working tree clean" indicator,
   "Initialize repository" offer.
7. **Titlebar git info** — Branch name, dirty indicator, ahead/behind
   counts.

### Phase 4: Session Persistence

Save and restore full application state.

1. **Snapshot model** — Codable structs for windows, projects,
   workspaces, panels, sidebar state.
2. **Terminal scrollback capture** — Up to 400K chars, ANSI-safe
   truncation at sequence boundaries, reset code wrapping.
3. **Browser state capture** — URL, zoom, dev tools state.
4. **Autosave** — 8-second interval during quiet periods, synchronous
   save on quit.
5. **Restore** — On launch, restore previous session (skip if env var
   disables, or launched with arguments).
6. **Resource limits** — v1 is single-window; the snapshot schema
   stores a window array for forward-compatibility but MUST contain
   exactly one entry. Schema-level caps: 12 windows, 128 workspaces
   per window.

### Phase 5: Browser Panels

Embedded WKWebView browser alongside terminals.

1. **BrowserPanel** — WKWebView with address bar (URL field,
   back/forward/reload, HTTPS indicator).
2. **Tab integration** — Browser panels appear as tabs alongside
   terminals in a workspace.
3. **Find in page** — Cmd+F floating search overlay.
4. **State persistence** — URL, zoom, dev tools saved/restored with
   session.
5. **Focus policy** — Prevent background browser panels from stealing
   focus.

### Phase 6: Agent Integration + TTS

Socket API for external agent status tracking.

1. **Socket server** — Embedded Unix socket at `~/.argus/argus.sock`,
   JSON lines protocol, accept loop on background thread.
2. **Status commands** — `set-status`, `clear-status`, `set-agent-pid`,
   `clear-agent-pid`. All status commands MUST accept an optional
   `surface_id` parameter to scope the entry to a specific panel;
   when omitted, the command falls back to the `ARGUS_SURFACE_ID`
   environment variable, then to workspace-level scope.
3. **Notification commands** — `notify`, `clear-notifications`.
4. **Agent PID tracking** — Register PIDs at both workspace and panel
   (surface) level. 30-second sweep for stale processes on a
   background queue, cleanup on detection.
5. **Per-panel status model** — Status entries are keyed by
   `(workspace_id, surface_id, agent_key)`. When multiple panels in
   the same workspace have active status entries, each entry MUST
   carry the panel label for disambiguation. When only one panel has
   status, the panel label SHOULD be omitted. Workspace-level entries
   (no surface_id) coexist with per-panel entries.
6. **Status display** — Agent status icons on workspace sidebar rows
   AND on individual tabs, color-tinted per state. Tab icon
   resolution: check per-panel status first, fall back to
   workspace-level status. Agent icons replace default tab icons but
   do NOT replace loading indicators (e.g., browser page loads).
   Icons MUST be synchronized whenever status entries are mutated,
   stale PIDs are swept, or workspace reconciliation occurs.
7. **CLI tool** — `argus` binary with Swift Argument Parser, socket
   client, auto-discovery of socket path. The CLI MUST provide the
   full command surface from Phase 1: project CRUD (create, list,
   remove, rename), workspace management (create, list, select,
   close, rename), panel management (create, list, focus, close),
   status commands, and notification commands. The socket protocol
   and command router MUST be designed to support all of these from
   the start — do not build a status-only protocol that must be
   reopened later for core app management flows.
8. **Environment variables** — Inject `ARGUS_SOCKET_PATH`,
   `ARGUS_WORKSPACE_ID`, `ARGUS_SURFACE_ID` into spawned shells.
9. **Kilo Code plugin** — Reference TypeScript plugin (adapted from cmux
   plugin) for agent lifecycle events → status updates + notifications.
   The plugin MUST use the surface-scoped status commands, sending
   `ARGUS_SURFACE_ID` as the `surface_id` parameter.
10. **TTS** — Fire-and-forget announcements via a user-installed TTS
    binary at a well-known path. The system MUST NOT fall back to
    macOS `say` or system speech synthesis; TTS is opt-in by
    installing the external binary. Failures are silent.

---

## Implementation Order Rationale

The phases are ordered by dependency and feedback loop:

1. **Foundation first** — Nothing works without a terminal in a window.
2. **Projects + worktrees** — Core organizational model that everything
   else builds on.
3. **Git sidebar** — High daily-use feature, provides immediate value.
4. **Session persistence** — Prevents data loss, makes the app usable
   for real daily work.
5. **Browser panels** — Adds the second panel type, rounds out the
   workspace model.
6. **Agent integration** — Depends on having a working workspace/panel
   model to attach status to.

---

## Deferred (NOT in Initial Implementation)

These can be added incrementally later if desired:

- **Split panes** — Recursive layout tree. Would require a
  Bonsplit-like component or custom NSSplitView management.
- **Command palette** — Cmd+K fuzzy finder for commands and workspaces.
- **Notification center** — In-app notification list with badge counts
  and sidebar view.
- **Markdown panels** — Markdown file viewer panel type.
- **Settings window** — Full settings UI (use Ghostty config +
  UserDefaults initially).
- **Keyboard shortcut customization** — Hardcoded shortcuts initially.
- **Multi-window** — v1 is strictly single-window. The persistence
  schema uses a window array (capped at 12) for forward-compatibility,
  but the runtime and UI enforce a single window.
- **Copy mode** — Vim-like terminal navigation overlay.
- **Find overlay** — Cmd+F search within terminal content.
- **Shell integration** — Shell hooks for directory tracking, command
  status, etc. In v1, the git sidebar and titlebar git info track the
  worktree/project root only. Shell integration would enable following
  the terminal's live cwd.
