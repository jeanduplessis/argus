#!/usr/bin/env python3
from pathlib import Path

sheet = Path("Argus/Views/Dialogs/NewProjectSheet.swift").read_text()
manager = Path("Argus/Services/WorkspaceManager.swift").read_text()

if "@State private var mainBranch: String = \"\"" not in sheet:
    raise SystemExit("FAIL: NewProjectSheet must store an editable main branch value")

if "TextField(\"Main branch\", text: $mainBranch)" not in sheet:
    raise SystemExit("FAIL: main branch must be editable with a text field")

if "mainBranch = branch" not in sheet:
    raise SystemExit("FAIL: detected branch must populate the editable main branch field")

if "mainBranchOverride: branch.isEmpty ? nil : branch" not in sheet:
    raise SystemExit("FAIL: create action must pass the main branch override")

if "mainBranchOverride: String? = nil" not in manager:
    raise SystemExit("FAIL: WorkspaceManager.createProject must accept a main branch override")

if "let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? \"\") : normalizedMainBranch" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must use override when provided and detected branch otherwise")

if ".padding(.vertical, 28)" not in sheet:
    raise SystemExit("FAIL: NewProjectSheet must add more vertical padding without changing horizontal padding")
