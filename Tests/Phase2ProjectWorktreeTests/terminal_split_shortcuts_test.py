#!/usr/bin/env python3
from pathlib import Path

workspace = Path("Argus/Models/Workspace.swift").read_text()
manager = Path("Argus/Services/WorkspaceManager.swift").read_text()
content = Path("Argus/Views/Content/ContentAreaView.swift").read_text()
tabbar = Path("Argus/Views/Content/TabBarView.swift").read_text()
app = Path("Argus/App/ArgusApp.swift").read_text()
terminal_ns_view = Path("Argus/Ghostty/TerminalNSView.swift").read_text()
argus_app = Path("Argus/App/ArgusApp.swift").read_text()

if "enum PanelSplitDirection" not in workspace or "case vertical" not in workspace or "case horizontal" not in workspace:
    raise SystemExit("FAIL: Workspace must model vertical and horizontal terminal split directions")

if "indirect enum PanelLayoutNode" not in workspace or "case split(direction:" not in workspace:
    raise SystemExit("FAIL: Workspace must model split-pane layout as a tree")

if "func splitActiveTerminal(direction: PanelSplitDirection)" not in workspace:
    raise SystemExit("FAIL: Workspace must expose splitActiveTerminal(direction:) as the public model operation")

if "func closeActivePaneOrTab()" not in workspace:
    raise SystemExit("FAIL: Workspace must close the focused split pane without closing the whole tab")

split_body = workspace.split("func splitActiveTerminal(direction: PanelSplitDirection)", 1)[1].split("\n    ///", 1)[0]
if "panelOrder.insert" in split_body or "panelOrder.append" in split_body:
    raise SystemExit("FAIL: splitting a terminal pane must not create another top-level tab")

if "func splitActiveTerminal(direction: PanelSplitDirection)" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must expose splitActiveTerminal(direction:) for commands")

if "PanelSplitLayoutView" not in content or "workspace.activeTabLayout" not in content:
    raise SystemExit("FAIL: ContentAreaView must render the active tab split layout, not only one active panel")

if "isActive: panelId == workspace.activeTabId" not in tabbar:
    raise SystemExit("FAIL: TabBarView must highlight the active tab even when a split child pane is focused")

if "Button(\"Split Vertically\")" not in app or ".keyboardShortcut(\"d\", modifiers: [.command])" not in app:
    raise SystemExit("FAIL: Cmd+D must be wired to Split Vertically")

if "Button(\"Split Horizontally\")" not in app or ".keyboardShortcut(\"d\", modifiers: [.command, .shift])" not in app:
    raise SystemExit("FAIL: Cmd+Shift+D must be wired to Split Horizontally")

if "terminalSurfaceDidBecomeFirstResponder" not in argus_app:
    raise SystemExit("FAIL: app must define a focus notification for split panes")

if "NotificationCenter.default.post(" not in terminal_ns_view or "name: .terminalSurfaceDidBecomeFirstResponder" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView focus must notify WorkspaceManager so split commands target the focused pane")
