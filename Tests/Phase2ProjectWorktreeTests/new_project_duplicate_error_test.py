#!/usr/bin/env python3
from pathlib import Path

sheet = Path("Argus/Views/Dialogs/NewProjectSheet.swift").read_text()
manager = Path("Argus/Services/WorkspaceManager.swift").read_text()

if "workspaceManager.hasDuplicateProject(repositoryRoot: repositoryRoot)" not in sheet:
    raise SystemExit("FAIL: NewProjectSheet validation must check canonical duplicate projects")

if 'validationError = "Project already exists for this repository"' not in sheet:
    raise SystemExit("FAIL: duplicate project validation must show a user-visible error")

create_guard = """guard project != nil else {
                validationError = "Could not create project"
                isCreating = false
                return
            }
            dismiss()"""
if create_guard not in sheet:
    raise SystemExit("FAIL: create action must keep the sheet open and show an error when project creation fails")

if "func hasDuplicateProject(repositoryRoot: String) -> Bool" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must expose canonical duplicate-project detection to the sheet")
