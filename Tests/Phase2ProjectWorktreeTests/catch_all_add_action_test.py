#!/usr/bin/env python3
from pathlib import Path

text = Path("Argus/Views/Sidebar/SidebarView.swift").read_text()
needle = """Button(action: {
                if project.isCatchAll {
                    workspaceManager.addWorkspace()
                } else {
                    NotificationCenter.default.post(
                        name: .showNewWorkspaceSheet,
                        object: nil,
                        userInfo: [\"projectId\": project.id]
                    )
                }
            })"""
if needle not in text:
    raise SystemExit("FAIL: project header plus button must create a standalone workspace for catch-all and show the worktree sheet only for named projects")

context_needle = """if project.isCatchAll {
                Button(\"Add Workspace…\") {
                    workspaceManager.addWorkspace()
                }
            } else {"""
if context_needle not in text:
    raise SystemExit("FAIL: catch-all context menu add action must create a standalone workspace")
