#!/usr/bin/env python3
from pathlib import Path

manager = Path("Argus/Services/WorkspaceManager.swift").read_text()
sheet = Path("Argus/Views/Dialogs/OrphanedWorktreesSheet.swift").read_text()

if "func adoptOrphanedWorktree(" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must expose a dedicated orphan adoption API")
if "workingDirectory: orphan.path" not in manager or "worktreePath: orphan.path" not in manager:
    raise SystemExit("FAIL: adopted workspace must point workingDirectory and worktreePath at the orphan path")
if "orphan.branchName ??" not in manager:
    raise SystemExit("FAIL: adopted workspace must use detected orphan branch metadata when available")
if "workspaceManager.adoptOrphanedWorktree(orphan)" not in sheet:
    raise SystemExit("FAIL: orphan sheet must call dedicated adoption API")
adopt_body = sheet.split("private func adoptOrphan", 1)[1].split("private func deleteOrphan", 1)[0]
if "addWorkspaceToProject" in adopt_body:
    raise SystemExit("FAIL: orphan adoption must not call addWorkspaceToProject / git worktree add")
