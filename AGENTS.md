# Argus — Agent Instructions

## First Thing: Read the Spec

**Before any work, read `.specs/argus-application.md`** — it is the authoritative specification. The implementation plan at `docs/argus-implementation-plan.md` provides additional context (architecture, phasing, rationale) but the spec governs correctness.

## Domain Context

Before changing domain behavior, read `CONTEXT.md`.
Use canonical terms from `CONTEXT.md` in code, docs, task descriptions, tests, and agent outputs.
Do not introduce synonyms for existing concepts unless updating `CONTEXT.md` first.
Do not duplicate the full context contract inside `AGENTS.md`.

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
