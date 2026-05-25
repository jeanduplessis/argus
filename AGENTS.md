# Argus — Agent Instructions

## First Thing: Read the Spec

**Before any work, read `.specs/argus-application.md`** — it is the authoritative specification. The implementation plan at `docs/argus-implementation-plan.md` provides additional context (architecture, phasing, rationale) but the spec governs correctness.

## What This Is

Argus is a **personal macOS terminal workspace manager** built on libghostty. Single user, single machine, not distributed. Simplicity and correctness are the priorities — do not over-engineer.

## Tech Stack

- **Swift 6 + SwiftUI** for the app, **AppKit** for window/NSView management
- **GhosttyKit.xcframework** (pre-built, vendored in `Frameworks/`) for GPU-accelerated Metal terminal rendering
- **WKWebView** for embedded browser panels
- **Unix domain socket** (embedded in app process) with **JSON Lines** protocol for IPC
- **Swift Argument Parser** for the CLI tool (SwiftPM dependency)
- **FSEvents API** (`FSEventStreamCreate`) for filesystem watching — NOT `DispatchSource.makeFileSystemObjectSource`
- **Process spawning** (`git` CLI) for all git operations — no libgit2
- **JSON (Codable)** for persistence at `~/Library/Application Support/Argus/`

## Architecture

Single-process app with two build targets:

1. **Argus** (app) — Xcode project target with Obj-C bridging header for GhosttyKit
2. **argus** (CLI) — SwiftPM-based, connects to app's Unix socket

```
Argus/
  App/          ArgusApp.swift, AppDelegate.swift
  Views/        MainWindowView, Sidebar/, Content/, GitSidebar/, Titlebar/
  Models/       Project, Workspace, Panel (protocol: Terminal | Browser)
  Services/     WorkspaceManager, WorktreeService, GitStatusService,
                SocketServer, SessionManager, AgentTracker, TTSService
  Ghostty/      GhosttyApp, TerminalSurface, TerminalView, GhosttyConfig
  Browser/      BrowserPanel, BrowserView
ArgusCLI/
  Commands/     Project/, Workspace/, Panel/, Status/, Notification/
```

## Key Domain Concepts

- **Project** — UUID-keyed collection of workspaces tied to a git repo. One catch-all project (non-removable) holds unassigned workspaces.
- **Workspace** — Ordered list of tabbed **Panels** (terminal or browser). Each workspace maps to a git worktree.
- **Panel** — Protocol with two conformers: TerminalPanel and BrowserPanel. Identified by surface_id.
- **Worktrees** stored at `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
- **Socket** at `~/.argus/argus.sock`
- **Environment variables** injected into shells: `ARGUS_SOCKET_PATH`, `ARGUS_WORKSPACE_ID`, `ARGUS_SURFACE_ID`

## Implementation Phases (Build Order)

| Phase | Feature | Status |
|-------|---------|--------|
| 1 | Foundation — Terminal + Workspaces (GhosttyKit, window shell, tab bar, sidebar, shortcuts) | Current |
| 2 | Projects + Git Worktrees (project model, worktree CRUD, orphan detection) | Planned |
| 3 | Git Status Sidebar (porcelain v2 parsing, FSEvents, file operations, diff/blame) | Planned |
| 4 | Session Persistence (autosave 8s, scrollback 400K chars, synchronous quit-save) | Planned |
| 5 | Browser Panels (WKWebView, address bar, find-in-page) | Planned |
| 6 | Agent Integration + TTS (socket server, status/notification commands, PID tracking, CLI) | Planned |

## Critical Design Constraints

- **Tabs only in v1** — no split panes. Panel model supports future embedding in a split tree.
- **Single window in v1** — persistence schema uses a window array (max 12) for forward-compat but runtime enforces exactly one.
- **JSON Lines only** — no legacy text protocol. Newline-delimited JSON on the socket.
- **No daemon** — socket server is embedded in the app. CLI gets connection error if app isn't running.
- **Git root is the worktree root** — does NOT follow terminal's live cwd. Shell integration is deferred.
- **FSEvents with 300ms debounce, 1s cooldown** — filter `.git/` events to prevent feedback loops.
- **Agent status is keyed by `(workspace_id, surface_id, agent_key)`** — per-panel when surface_id present, workspace-level when omitted.
- **TTS is opt-in only** — external binary at a well-known path. No fallback to `say` or system speech. Failures are silent.
- **Ghostty config compatibility** — reads `~/.config/ghostty/config` for terminal settings.
- **Max 128 workspaces per window, max 12 windows in schema.**

## Conventions

- RFC 2119 keywords in the spec (MUST, SHOULD, MAY) are normative.
- One type per file. Subdirectories group by feature.
- `ObservableObject` for reactive state. `Codable` for all persistence models.
- Background queues for I/O (FSEvents, socket, agent sweep). Main thread only for UI.
- Keyboard shortcuts: Cmd+N (new tab), Cmd+W (close tab), Cmd+T (new workspace), Cmd+1-8 (select workspace by global sidebar index), Cmd+9 (last workspace).

<!-- AIT START -->
# Agent Issue Tracker (ait)

This repo uses `ait` CLI for structured, durable, repo-local issue tracking. 

## Project State

- Project data lives in `.ait/`.
- The CLI is the mutation surface; do not edit `.ait/state.sqlite` or `.ait/issues.jsonl` directly.
- Non-view commands return JSON envelopes: success is `{"ok": true, "data": ...}`; failure is `{"ok": false, "error": ...}`.
- Mutating commands require an actor: pass `--actor agent` or set `AIT_ACTOR`.

## Usage

When working with `ait`, load and follow the `ait-cli` skill.

Use the skill for creating, claiming, updating, closing, listing, inspecting, validating, or resuming issues; finding ready work; managing dependencies; and any workflow needing persistent issue state.

## Safety Rules

- Do not run bare `ait` in automation; it opens the TUI.
- Do not initialize, import, export, or force-close unless requested or clearly required.
- Use `ait check` before handoff and after unusual failures.
- On command failure, report `error.code`, `error.message`, and next safe action.
<!-- AIT END -->
