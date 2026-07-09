// MainWindowView.swift
// Argus
//
// Root view for the main window. Three-column layout with draggable dividers:
// left sidebar | content area | right side panel.

import SwiftUI

private struct NewWorkspaceSheetRequest: Identifiable {
    let id = UUID()
    let projectId: UUID
}

struct MainWindowView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var gitSidebarState = GitSidebarState()
    @StateObject private var gitStatusViewModel = GitStatusViewModel()

    // MARK: - Sheet State

    @State private var showNewProjectSheet = false
    @State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?
    @State private var showOrphanedWorktreesSheet = false
    @State private var orphanedWorktrees: [OrphanedWorktreeInfo] = []
    @State private var showRenameProjectAlert = false
    @State private var renameProjectId: UUID?
    @State private var renameProjectText = ""
    @State private var showRenameWorkspaceAlert = false
    @State private var renameWorkspaceId: UUID?
    @State private var renameWorkspaceText = ""
    @State private var showCloseWorkspaceConfirmation = false
    @State private var closeWorkspaceId: UUID?
    @State private var closeWorkspaceTitle = ""
    @State private var closeWorkspaceWorktreePath = ""

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Left sidebar
                if sidebarState.isVisible {
                    SidebarView()
                        .frame(width: sidebarState.width)
                    SidebarDivider(
                        position: $sidebarState.width,
                        minValue: SidebarLayout.leftMinWidth,
                        maxValue: SidebarLayout.leftMaxWidth(forWindowWidth: geometry.size.width)
                    )
                }

                // Content area fills remaining space and draws into the
                // transparent titlebar, matching the compact cmux-style chrome.
                ContentAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ChromeColors.contentBackground)

                // Right side panel
                if gitSidebarState.isVisible {
                    GitSidebarDivider(
                        position: $gitSidebarState.width,
                        minValue: 180,
                        maxValue: 600
                    )
                    RightSidebarView()
                        .frame(width: gitSidebarState.width)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear {
                sidebarState.width = SidebarLayout.clampLeftWidth(
                    sidebarState.width,
                    windowWidth: geometry.size.width
                )
            }
            .onChange(of: geometry.size.width) { _, newWidth in
                sidebarState.width = SidebarLayout.clampLeftWidth(
                    sidebarState.width,
                    windowWidth: newWidth
                )
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(ChromeColors.contentBackground)
        .environmentObject(sidebarState)
        .environmentObject(gitSidebarState)
        .environmentObject(gitStatusViewModel)
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarState.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGitSidebar)) { _ in
            gitSidebarState.toggle()
        }
        // Sheet: New Project
        .sheet(isPresented: $showNewProjectSheet) {
            NewProjectSheet()
                .environmentObject(workspaceManager)
        }
        // Sheet: New Workspace
        .sheet(item: $newWorkspaceSheetRequest) { request in
            NewWorkspaceSheet(projectId: request.projectId)
                .environmentObject(workspaceManager)
        }
        // Sheet: Orphaned Worktrees
        .sheet(isPresented: $showOrphanedWorktreesSheet) {
            OrphanedWorktreesSheet(orphans: orphanedWorktrees)
                .environmentObject(workspaceManager)
        }
        // Alert: Rename Project
        .alert("Rename Project", isPresented: $showRenameProjectAlert) {
            TextField("Project name", text: $renameProjectText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let id = renameProjectId {
                    workspaceManager.renameProject(id, name: renameProjectText)
                }
            }
        }
        // Alert: Rename Workspace
        .alert("Rename Workspace", isPresented: $showRenameWorkspaceAlert) {
            TextField("Workspace name", text: $renameWorkspaceText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let id = renameWorkspaceId {
                    workspaceManager.renameWorkspace(id, title: renameWorkspaceText)
                }
            }
        }
        // Alert: Close Workspace with optional worktree deletion
        .alert("Close Workspace?", isPresented: $showCloseWorkspaceConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Close Only") {
                if let id = closeWorkspaceId {
                    workspaceManager.removeWorkspace(id)
                }
            }
            Button("Delete Worktree and Close", role: .destructive) {
                if let id = closeWorkspaceId {
                    Task {
                        _ = await workspaceManager.removeWorkspace(id, deletingWorktree: true)
                    }
                }
            }
        } message: {
            Text("Do you also want to delete the git worktree for \(closeWorkspaceTitle) at \(closeWorkspaceWorktreePath)?")
        }
        // Notification receivers for sheet/alert triggers
        .onReceive(NotificationCenter.default.publisher(for: .showNewProjectSheet)) { _ in
            showNewProjectSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewWorkspaceSheet)) { notification in
            if let projectId = notification.userInfo?["projectId"] as? UUID {
                newWorkspaceSheetRequest = NewWorkspaceSheetRequest(projectId: projectId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRenameProjectSheet)) { notification in
            if let projectId = notification.userInfo?["projectId"] as? UUID,
               let project = workspaceManager.projects.first(where: { $0.id == projectId }) {
                renameProjectId = projectId
                renameProjectText = project.displayName
                showRenameProjectAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showRenameWorkspaceSheet)) { notification in
            if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
               let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) {
                renameWorkspaceId = workspaceId
                renameWorkspaceText = workspace.displayTitle
                showRenameWorkspaceAlert = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCloseWorkspaceConfirmation)) { notification in
            if let workspaceId = notification.userInfo?["workspaceId"] as? UUID,
               let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) {
                closeWorkspaceId = workspaceId
                closeWorkspaceTitle = workspace.displayTitle
                closeWorkspaceWorktreePath = workspace.worktreePath ?? ""
                showCloseWorkspaceConfirmation = true
            }
        }
        .task {
            await detectOrphanedWorktrees()
        }
    }

    /// Scans for orphaned worktrees on launch and shows the dialog if any are found.
    private func detectOrphanedWorktrees() async {
        var allOrphans: [OrphanedWorktreeInfo] = []

        for project in workspaceManager.namedProjects {
            let knownPaths = Set(
                workspaceManager.workspaces
                    .filter { $0.projectId == project.id }
                    .compactMap(\.worktreePath)
            )
            let orphans = workspaceManager.worktreeService.detectOrphanedWorktrees(
                projectId: project.id,
                knownWorkspacePaths: knownPaths
            )
            allOrphans.append(contentsOf: orphans)
        }

        if !allOrphans.isEmpty {
            orphanedWorktrees = allOrphans
            showOrphanedWorktreesSheet = true
        }
    }
}
