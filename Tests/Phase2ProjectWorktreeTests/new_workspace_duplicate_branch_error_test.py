#!/usr/bin/env python3
from pathlib import Path

manager = Path("Argus/Services/WorkspaceManager.swift").read_text()
service = Path("Argus/Services/WorktreeService.swift").read_text()
sheet = Path("Argus/Views/Dialogs/NewWorkspaceSheet.swift").read_text()

add_workspace = manager.split("func addWorkspaceToProject(", 1)[1].split("\n    // MARK: - Selection", 1)[0]
if "uniqueBranchName(branchName" in add_workspace:
    raise SystemExit("FAIL: new workspace creation must not auto-suffix duplicate branch names")

if "try await worktreeService.ensureBranchNameAvailable(branchName, repositoryPath: project.repositoryPath)" not in add_workspace:
    raise SystemExit("FAIL: WorkspaceManager must validate new branch availability and reject duplicates")

if "func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws" not in service:
    raise SystemExit("FAIL: WorktreeService must expose branch availability validation")

validator = service.split("func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws", 1)[1].split("\n    private func canonicalBranchNameSet", 1)[0]
if "throw WorktreeError.branchAlreadyExists(baseName)" not in validator:
    raise SystemExit("FAIL: branch availability validation must throw branchAlreadyExists")

if "case .branchAlreadyExists(let branchName):" not in sheet:
    raise SystemExit("FAIL: NewWorkspaceSheet must show a specific duplicate branch error")

if "errorMessage = \"Branch '\\(branchName)' already exists\"" not in sheet:
    raise SystemExit("FAIL: duplicate branch error text must tell the user the branch already exists")
