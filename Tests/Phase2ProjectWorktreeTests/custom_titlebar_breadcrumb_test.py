#!/usr/bin/env python3
from pathlib import Path

app_delegate = Path("Argus/App/AppDelegate.swift").read_text()
app = Path("Argus/App/ArgusApp.swift").read_text()
titlebar = Path("Argus/Views/Titlebar/TitlebarView.swift").read_text()

if "window.titleVisibility = .hidden" not in app_delegate:
    raise SystemExit("FAIL: native title text should be hidden; Argus renders its own content-column titlebar")

if "window.titleVisibility = .visible" in app_delegate:
    raise SystemExit("FAIL: native title visibility must not be visible")

if ".windowStyle(.hiddenTitleBar)" not in app:
    raise SystemExit("FAIL: SwiftUI scene should use hiddenTitleBar so content owns the titlebar area")

required_titlebar_fragments = [
    "workspaceManager.selectedWorkspace",
    "workspaceManager.project(for: workspace.id)",
    "workspace.workspaceType.icon",
    "project.displayName",
    "workspace.displayTitle",
    "workspace.branchName",
    "Text(\"/\")",
]
for fragment in required_titlebar_fragments:
    if fragment not in titlebar:
        raise SystemExit(f"FAIL: custom titlebar breadcrumb missing {fragment}")

if "workspaceManager.activeWorkspaceTitle" in titlebar:
    raise SystemExit("FAIL: custom titlebar should not be a flat native-style title string")
