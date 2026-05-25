#!/usr/bin/env python3
from pathlib import Path

text = Path("Argus/Views/MainWindowView.swift").read_text()

if "private struct NewWorkspaceSheetRequest: Identifiable" not in text:
    raise SystemExit("FAIL: New workspace sheet must use an identifiable request instead of optional content")

if "@State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?" not in text:
    raise SystemExit("FAIL: MainWindowView must store a non-nil sheet request carrying the project id")

if ".sheet(item: $newWorkspaceSheetRequest) { request in" not in text:
    raise SystemExit("FAIL: NewWorkspaceSheet must be presented with sheet(item:) so content is never empty")

if "NewWorkspaceSheet(projectId: request.projectId)" not in text:
    raise SystemExit("FAIL: NewWorkspaceSheet must receive the project id from the sheet request")

if "showNewWorkspaceSheet = true" in text:
    raise SystemExit("FAIL: New workspace sheet presentation must not toggle a boolean before content exists")

if ".sheet(isPresented: $showNewWorkspaceSheet)" in text:
    raise SystemExit("FAIL: New workspace sheet must not use boolean presentation with optional inner content")
