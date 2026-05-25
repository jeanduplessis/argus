#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2]
main_window = (root / "Argus/Views/MainWindowView.swift").read_text()
git_sidebar = (root / "Argus/Views/GitSidebar/GitSidebarView.swift").read_text()
titlebar = (root / "Argus/Views/Titlebar/TitlebarView.swift").read_text()

assert "@StateObject private var gitStatusViewModel = GitStatusViewModel()" in main_window, "MainWindowView owns shared git status state"
assert ".environmentObject(gitStatusViewModel)" in main_window, "shared git status state is injected into titlebar/sidebar subtree"
assert "@EnvironmentObject private var viewModel: GitStatusViewModel" in git_sidebar, "GitSidebarView observes shared git status state instead of owning private state"
assert "viewModel.refresh(workspaceId: workspace.id, context: context)" in git_sidebar, "manual/automatic refreshes are scoped to the selected workspace"
assert "@EnvironmentObject private var gitStatusViewModel: GitStatusViewModel" in titlebar, "TitlebarView observes shared git status state"
assert "gitStatusViewModel.titlebarGitContext(for: workspace.id)" in titlebar, "TitlebarView reads git metadata for the active workspace only"
assert "gitContext.visibleText" in titlebar, "TitlebarView renders visible git metadata"
assert ".task(id: workspaceManager.selectedWorkspaceId)" in titlebar, "TitlebarView requests shared status for the active workspace even when the sidebar is closed"
assert "gitStatusViewModel.stateWorkspaceId != workspace.id" in titlebar, "TitlebarView avoids duplicate refresh when shared state already belongs to the active workspace"
assert "gitStatusViewModel.refresh(workspaceId: workspace.id, context: context)" in titlebar, "TitlebarView refreshes the shared status state instead of running git directly"
assert "WorkspaceTitleFormatter.title(" in titlebar and "gitContext: gitContext?.windowTitleText" in titlebar, "TitlebarView computes the macOS window title from visible git context"
assert "NSApp.mainWindow?.title" in titlebar, "TitlebarView synchronizes the macOS window title when git status changes"
