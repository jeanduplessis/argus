#!/usr/bin/env python3
from pathlib import Path

service = Path("Argus/Services/WorktreeService.swift").read_text()
sheet = Path("Argus/Views/Dialogs/NewWorkspaceSheet.swift").read_text()

if "timeout: TimeInterval? = nil" not in service:
    raise SystemExit("FAIL: WorktreeService runGit must support an optional timeout")

if "Task.sleep(nanoseconds:" not in service or "process.terminate()" not in service:
    raise SystemExit("FAIL: timed git commands must terminate instead of blocking forever")

remote_heads = service.split("private func listRemoteHeadBranches", 1)[1].split("\n    /// Lists all worktrees", 1)[0]
if "ls-remote" not in remote_heads or "timeout:" not in remote_heads:
    raise SystemExit("FAIL: remote head discovery must run ls-remote with a timeout")

load_branches = sheet.split("private func loadBranches()", 1)[1].split("\n    private func createWorkspace()", 1)[0]
if "defer { isLoadingBranches = false }" not in load_branches:
    raise SystemExit("FAIL: NewWorkspaceSheet must always clear the loading state")

if "errorMessage = error.localizedDescription" not in load_branches:
    raise SystemExit("FAIL: branch loading failures should surface instead of leaving an indefinite spinner")
