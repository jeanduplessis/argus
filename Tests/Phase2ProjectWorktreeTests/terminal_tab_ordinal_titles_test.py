#!/usr/bin/env python3
from pathlib import Path

workspace = Path("Argus/Models/Workspace.swift").read_text()
tabbar = Path("Argus/Views/Content/TabBarView.swift").read_text()

if "func tabDisplayTitle(for panelId: UUID) -> String" not in workspace:
    raise SystemExit("FAIL: Workspace must expose ordinal tabDisplayTitle(for:)")

helper = workspace.split("func tabDisplayTitle(for panelId: UUID) -> String", 1)[1].split("\n    ///", 1)[0]
if '"Tab \\(index + 1)"' not in helper:
    raise SystemExit("FAIL: tabDisplayTitle(for:) must return Tab 1, Tab 2, ... based on panelOrder")

if "workspace.tabDisplayTitle(for: panelId)" not in tabbar:
    raise SystemExit("FAIL: TabBarView must render workspace ordinal tab titles")

if "let title: String" not in tabbar:
    raise SystemExit("FAIL: TabItemView should accept an explicit tab title")

tab_item = tabbar.split("struct TabItemView: View", 1)[1]
if "Text(panel.displayTitle)" in tab_item:
    raise SystemExit("FAIL: TabItemView must not use terminal path/process title for tab labels")

if "Text(title)" not in tab_item:
    raise SystemExit("FAIL: TabItemView must display the explicit ordinal title")
