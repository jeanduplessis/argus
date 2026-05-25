#!/usr/bin/env python3
from pathlib import Path

app_delegate = Path("Argus/App/AppDelegate.swift").read_text()
app = Path("Argus/App/ArgusApp.swift").read_text()

if "window.titleVisibility = .hidden" not in app_delegate:
    raise SystemExit("FAIL: native title text should stay hidden when Argus renders custom chrome")

if "window.titleVisibility = .visible" in app_delegate:
    raise SystemExit("FAIL: native title text should not be visible in the custom titlebar design")

if "window.titlebarAppearsTransparent = true" not in app_delegate:
    raise SystemExit("FAIL: window should keep the transparent custom titlebar chrome")

if "window.styleMask.insert(.fullSizeContentView)" not in app_delegate:
    raise SystemExit("FAIL: window should keep full-size content view mode")

if "targetWindow?.title = workspaceManager?.activeWorkspaceTitle" not in app_delegate:
    raise SystemExit("FAIL: window metadata title should still track the active workspace title")

if ".windowStyle(.hiddenTitleBar)" not in app:
    raise SystemExit("FAIL: SwiftUI scene should hide native titlebar text while custom titlebar renders in content")
