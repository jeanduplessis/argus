#!/usr/bin/env python3
from pathlib import Path

sidebar = Path("Argus/Views/Sidebar/SidebarView.swift").read_text()
manager = Path("Argus/Services/WorkspaceManager.swift").read_text()
main_window = Path("Argus/Views/MainWindowView.swift").read_text()
tabbar = Path("Argus/Views/Content/TabBarView.swift").read_text()

if "static let showCloseWorkspaceConfirmation" not in sidebar:
    raise SystemExit("FAIL: workspace close confirmation notification must exist")

if "shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must expose a predicate for project worktree close confirmation")

predicate = manager.split("shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool", 1)[1].split("\n    ///", 1)[0]
if "workspace.worktreePath != nil" not in predicate or "!project.isCatchAll" not in predicate:
    raise SystemExit("FAIL: close confirmation should only apply to named-project worktree workspaces")

if "func removeWorkspace(_ workspaceId: UUID, deletingWorktree: Bool) async -> Bool" not in manager:
    raise SystemExit("FAIL: WorkspaceManager must support removing the git worktree before removing workspace state")

close_current_tab = manager.split("func closeCurrentTab()", 1)[1].split("\n    // MARK: - Keyboard", 1)[0]
if "shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)" not in close_current_tab:
    raise SystemExit("FAIL: Cmd-W closing the last tab in a worktree workspace must request confirmation before removing it")

if "try await worktreeService.removeWorktree" not in manager:
    raise SystemExit("FAIL: deletingWorktree removal path must call WorktreeService.removeWorktree")

if "workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)" not in sidebar:
    raise SystemExit("FAIL: sidebar Close Workspace action must request confirmation for worktree workspaces")

if "name: .showCloseWorkspaceConfirmation" not in sidebar:
    raise SystemExit("FAIL: sidebar Close Workspace action must post confirmation notification")

if "workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)" not in tabbar:
    raise SystemExit("FAIL: closing the last tab must also request workspace close confirmation")

if ".alert(\"Close Workspace?\", isPresented: $showCloseWorkspaceConfirmation)" not in main_window:
    raise SystemExit("FAIL: MainWindowView must show a close-workspace confirmation alert")

if "Button(\"Close Only\")" not in main_window:
    raise SystemExit("FAIL: confirmation alert must allow closing without deleting the worktree")

if "Button(\"Delete Worktree and Close\", role: .destructive)" not in main_window:
    raise SystemExit("FAIL: confirmation alert must offer destructive worktree deletion")
