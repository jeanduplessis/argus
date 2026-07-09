// TitlebarView.swift
// Argus
//
// Compact content-column titlebar showing the active workspace context.
// It is placed inside the content column so the system traffic-light row
// collapses into the app chrome instead of reserving a full-width strip.

import AppKit
import SwiftUI

struct TitlebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel

    var body: some View {
        HStack(spacing: 10) {
            if let workspace = workspaceManager.selectedWorkspace {
                let project = workspaceManager.project(for: workspace.id)
                let gitContext = gitStatusViewModel.titlebarGitContext(for: workspace.id)

                Text(titleContext(for: workspace, project: project))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("/")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Text(workspace.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let gitContext {
                    Text(gitContext.visibleText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(WorkspaceTitleFormatter.fallbackTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 44)
        .background(ChromeColors.contentBackground)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
        .onAppear(perform: syncWindowTitle)
        .task(id: workspaceManager.selectedWorkspaceId) {
            await refreshSharedStatusForActiveWorkspace()
        }
        .onChange(of: workspaceManager.selectedWorkspaceId) { _, _ in syncWindowTitle() }
        .onChange(of: gitStatusViewModel.state) { _, _ in syncWindowTitle() }
        .onChange(of: gitStatusViewModel.stateWorkspaceId) { _, _ in syncWindowTitle() }
    }

    private func syncWindowTitle() {
        NSApp.mainWindow?.title = currentWindowTitle
    }

    private func refreshSharedStatusForActiveWorkspace() async {
        guard let workspace = workspaceManager.selectedWorkspace,
              gitStatusViewModel.stateWorkspaceId != workspace.id,
              let context = statusContext(for: workspace)
        else { return }

        await gitStatusViewModel.refresh(workspaceId: workspace.id, context: context)
    }

    private func statusContext(for workspace: Workspace) -> GitStatusRootContext? {
        let project = workspaceManager.project(for: workspace.id)
        let projectRepositoryPath = project?.isCatchAll == false ? project?.repositoryPath : nil

        let kind: GitStatusRootContext.WorkspaceKind
        switch workspace.workspaceType {
        case .worktree:
            kind = .worktree
        case .mainCheckout:
            kind = .mainCheckout
        case .external:
            kind = .standalone
        }

        return GitStatusRootContext(
            kind: kind,
            currentDirectory: workspace.currentDirectory,
            worktreePath: workspace.worktreePath,
            projectRepositoryPath: projectRepositoryPath
        )
    }

    private var currentWindowTitle: String {
        guard let workspace = workspaceManager.selectedWorkspace else {
            return WorkspaceTitleFormatter.fallbackTitle
        }

        let gitContext = gitStatusViewModel.titlebarGitContext(for: workspace.id)
        guard gitContext != nil else { return workspaceManager.activeWorkspaceTitle }

        return WorkspaceTitleFormatter.title(
            workspaceTitle: workspace.displayTitle,
            contextName: workspaceManager.activeWorkspaceContextName(for: workspace),
            gitContext: gitContext?.windowTitleText
        )
    }

    private func titleContext(for workspace: Workspace, project: Project?) -> String {
        if let project, !project.isCatchAll {
            return project.displayName
        }

        return workspaceManager.activeWorkspaceContextName(for: workspace)
    }
}
