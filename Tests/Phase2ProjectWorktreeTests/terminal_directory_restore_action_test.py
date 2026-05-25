#!/usr/bin/env python3
from pathlib import Path

workspace = Path("Argus/Models/Workspace.swift").read_text()
terminal_panel = Path("Argus/Models/TerminalPanel.swift").read_text()

restore_needle = """let terminalDirectories = snapshot.restoredTerminalDirectories
        let firstPanel = TerminalPanel(workspaceId: id, workingDirectory: terminalDirectories[0])
        addPanel(firstPanel)
        for directory in terminalDirectories.dropFirst() {
            addTerminalPanel(workingDirectory: directory)
        }"""
if restore_needle not in workspace:
    raise SystemExit("FAIL: workspace restore must recreate each terminal with its persisted working directory")

snapshot_needle = """terminalDirectories: terminalDirectoriesForSnapshot()"""
if snapshot_needle not in workspace:
    raise SystemExit("FAIL: workspace snapshot must persist terminal directories")

panel_directory_needle = """self.title = Self.titleFromPath(dir)
        self.directory = dir"""
if panel_directory_needle not in terminal_panel:
    raise SystemExit("FAIL: terminal panels must initialize their persisted directory from the shell working directory")
