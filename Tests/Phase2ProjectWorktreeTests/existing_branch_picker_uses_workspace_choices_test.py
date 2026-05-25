#!/usr/bin/env python3
from pathlib import Path

sheet = Path("Argus/Views/Dialogs/NewWorkspaceSheet.swift").read_text()
service = Path("Argus/Services/WorktreeService.swift").read_text()

if "listWorkspaceBranchChoices(" not in sheet or "repositoryPath: project.repositoryPath" not in sheet:
    raise SystemExit("FAIL: Existing Branch picker must use workspace branch choices, not worktree-creation-only availability")

if "func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String]" not in service:
    raise SystemExit("FAIL: WorktreeService must expose branch choices for the workspace picker")

choices = service.split("func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String]", 1)[1].split("\n    private func", 1)[0]
if "!worktree.isHead" not in choices:
    raise SystemExit("FAIL: workspace branch choices should include non-main checked-out worktree branches")
