#!/usr/bin/env python3
from pathlib import Path

sheet = Path("Argus/Views/Dialogs/NewWorkspaceSheet.swift").read_text()

if "@State private var branchFilter: String = \"\"" not in sheet:
    raise SystemExit("FAIL: NewWorkspaceSheet must track branch filter text")

if "private var filteredAvailableBranches: [String]" not in sheet:
    raise SystemExit("FAIL: NewWorkspaceSheet must expose filtered branch list")

if "localizedCaseInsensitiveContains(filter)" not in sheet:
    raise SystemExit("FAIL: branch filtering must be case-insensitive substring matching")

if "TextField(\"Filter branches\", text: $branchFilter)" not in sheet:
    raise SystemExit("FAIL: existing branch mode must allow filtering by typing")

if "ForEach(filteredAvailableBranches, id: \\.self)" not in sheet:
    raise SystemExit("FAIL: existing branch choices must be driven by the filtered branch list")

if "selectedExistingBranch = branch" not in sheet:
    raise SystemExit("FAIL: selecting a filtered branch must update selectedExistingBranch")
