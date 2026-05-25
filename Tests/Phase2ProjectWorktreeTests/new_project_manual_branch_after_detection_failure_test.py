#!/usr/bin/env python3
from pathlib import Path

sheet = Path("Argus/Views/Dialogs/NewProjectSheet.swift").read_text()
manager = Path("Argus/Services/WorkspaceManager.swift").read_text()

if "@State private var isRepositoryValid: Bool = false" not in sheet:
    raise SystemExit("FAIL: NewProjectSheet must track valid repo separately from branch detection")

if "@State private var branchDetectionWarning: String?" not in sheet:
    raise SystemExit("FAIL: branch detection failure must be represented as a non-blocking warning")

can_create = sheet.split("private var canCreate: Bool {", 1)[1].split("\n    }", 1)[0]
if "isRepositoryValid" not in can_create:
    raise SystemExit("FAIL: Create should depend on valid repository state")
if "detectedBranch != nil" in can_create:
    raise SystemExit("FAIL: Create must not require detectedBranch when user can type a branch")
if "branchDetectionWarning" in can_create:
    raise SystemExit("FAIL: branch detection warning must not block Create")

if "TextField(\"Main branch\", text: $mainBranch)" not in sheet:
    raise SystemExit("FAIL: main branch text field must remain available for manual entry")

if 'branchDetectionWarning = "Could not detect main branch. Enter one manually."' not in sheet:
    raise SystemExit("FAIL: detection failure should show a non-blocking manual-entry warning")

if "guard !mainBranch.isEmpty else { return nil }" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must accept explicit main branch without requiring detection")

if "let detectedMainBranch = try? await worktreeService.detectMainBranch" not in manager:
    raise SystemExit("FAIL: WorkspaceManager should still use detected branch when no override is provided")
