#!/usr/bin/env python3
from pathlib import Path

text = Path("Argus/Views/Sidebar/SidebarView.swift").read_text()

if "Menu {" not in text:
    raise SystemExit("FAIL: projects sidebar header add control must be a menu")

new_workspace = """Button(action: {
                    workspaceManager.addWorkspace()
                }) {
                    Label("New Workspace", systemImage: "terminal")
                }"""
if new_workspace not in text:
    raise SystemExit("FAIL: projects header menu must include New Workspace action")

new_project = """Button(action: {
                    NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
                }) {
                    Label("New Project…", systemImage: "folder.badge.plus")
                }"""
if new_project not in text:
    raise SystemExit("FAIL: projects header menu must include New Project action")

label = """Image(systemName: "plus")
                    .font(.system(size: 12))"""
if label not in text:
    raise SystemExit("FAIL: projects header add menu must keep the plus icon label")
