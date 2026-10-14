import AppKit
import Foundation
import SwiftUI

extension AppSettings.RightSidebarView {
    fileprivate var systemImage: String {
        switch self {
        case .files:
            "doc"
        case .changes:
            "arrow.triangle.branch"
        case .notes:
            "note.text"
        }
    }
}

struct RightSidebarView: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var gitSidebarState: GitSidebarState
    @StateObject private var filesViewModel = WorkspaceFilesViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
                .windowFocusChrome()

            ZStack {
                WorkspaceFilesView(
                    viewModel: filesViewModel,
                    workspaceId: workspaceManager.selectedWorkspace?.id,
                    rootPath: workspaceManager.selectedWorkspace?.currentDirectory,
                    showHiddenFiles: appSettings.showHiddenFiles
                )
                .opacity(gitSidebarState.selectedView == .files ? 1 : 0)
                .allowsHitTesting(gitSidebarState.selectedView == .files)
                .accessibilityHidden(gitSidebarState.selectedView != .files)

                GitSidebarView()
                    .opacity(gitSidebarState.selectedView == .changes ? 1 : 0)
                    .allowsHitTesting(gitSidebarState.selectedView == .changes)
                    .accessibilityHidden(gitSidebarState.selectedView != .changes)

                // Mounted only while selected so hiding the Notes View ends
                // editing and flushes its pending Workspace Notes checkpoint.
                if gitSidebarState.selectedView == .notes {
                    WorkspaceNotesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.shellBackground)
        .onChange(of: filesRequest, initial: true) { _, request in
            filesViewModel.activate(request: request)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            // As width shrinks, tabs drop titles first for unselected views,
            // then for every view, so all tabs stay usable at 180 points.
            ViewThatFits(in: .horizontal) {
                tabButtons(titles: .all)
                tabButtons(titles: .selectedOnly)
                tabButtons(titles: .none)
            }

            Spacer(minLength: 0)

            // Notes have no asynchronous load. Their refresh controls stay
            // hidden in place so switching views never reflows the tabs.
            refreshControls
                .opacity(gitSidebarState.selectedView == .notes ? 0 : 1)
                .allowsHitTesting(gitSidebarState.selectedView != .notes)
                .accessibilityHidden(gitSidebarState.selectedView == .notes)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private var refreshControls: some View {
        HStack(spacing: 0) {
            ZStack {
                if gitSidebarState.selectedView == .files, filesViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if gitSidebarState.selectedView == .changes, gitStatusViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 12, height: 12)

            HoverStateView { isHovered in
                Button {
                    Task { await refreshSelectedPanel() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(canRefresh && isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canRefresh)
                .cursor(canRefresh ? .pointingHand : .arrow)
                .help(gitSidebarState.selectedView == .files ? "Refresh files" : "Refresh changes")
                .accessibilityLabel(gitSidebarState.selectedView == .files ? "Refresh files" : "Refresh changes")
                .accessibilityValue(isRefreshActive ? "Refreshing" : "")
            }
            .padding(.trailing, 12)
        }
    }

    private enum TabTitles {
        case all
        case selectedOnly
        case none
    }

    private func tabButtons(titles: TabTitles) -> some View {
        HStack(spacing: 0) {
            ForEach(AppSettings.RightSidebarView.allCases) { panel in
                let showsTitle =
                    switch titles {
                    case .all: true
                    case .selectedOnly: panel == gitSidebarState.selectedView
                    case .none: false
                    }
                tabButton(panel, showsTitle: showsTitle)
            }
        }
    }

    private func tabButton(_ panel: AppSettings.RightSidebarView, showsTitle: Bool) -> some View {
        let isSelected = gitSidebarState.selectedView == panel

        return Button {
            gitSidebarState.selectedView = panel
        } label: {
            HStack(spacing: showsTitle ? 8 : 4) {
                Image(systemName: panel.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 18)
                if showsTitle {
                    Text(panel.title)
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 14), weight: .semibold)
                        )
                        .fixedSize()
                }

                if panel == .changes, let count = changesCount, count > 0 {
                    CountBadge(count: count, prominent: isSelected)
                        .fixedSize()
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, showsTitle ? 12 : 6)
            .frame(height: 44)
            .background(isSelected ? ChromeColors.activeTabFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(panel.title)
        .accessibilityLabel(tabAccessibilityLabel(panel))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tabAccessibilityLabel(_ panel: AppSettings.RightSidebarView) -> String {
        guard panel == .changes, let count = changesCount, count > 0 else { return panel.title }
        return "\(panel.title), \(count)"
    }

    private var isRefreshActive: Bool {
        switch gitSidebarState.selectedView {
        case .files:
            return filesViewModel.isRefreshing
        case .changes:
            return gitStatusViewModel.isRefreshing
        case .notes:
            return false
        }
    }

    private var canRefresh: Bool {
        guard !isRefreshActive else { return false }
        switch gitSidebarState.selectedView {
        case .files:
            return filesRequest != nil
        case .changes:
            return workspaceManager.selectedWorkspace != nil
        case .notes:
            return false
        }
    }

    private var filesRequest: WorkspaceFileTreeRequest? {
        _ = workspaceManager.workspaceContextRevision
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        return WorkspaceFileTreeRequest(
            workspaceId: workspace.id,
            rootPath: workspace.currentDirectory,
            showHiddenFiles: appSettings.showHiddenFiles
        )
    }

    private var changesCount: Int? {
        guard case .loaded(let summary) = gitStatusViewModel.state else { return nil }
        return summary.totalFileCount
    }

    private func refreshSelectedPanel() async {
        switch gitSidebarState.selectedView {
        case .files:
            await refreshFiles()
        case .changes:
            await refreshChanges()
        case .notes:
            return
        }
    }

    private func refreshFiles() async {
        guard let filesRequest else {
            filesViewModel.reset()
            return
        }
        await filesViewModel.refresh(request: filesRequest)
    }

    private func refreshChanges() async {
        guard let workspace = workspaceManager.selectedWorkspace else { return }
        let context = gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )
        await gitStatusViewModel.refresh(
            workspaceId: workspace.id,
            context: context,
            presentation: GitStatusPresentation(
                combineWorkingChangeSections: appSettings.combineWorkingChangeSections,
                showBaseBranchChanges: appSettings.showBaseBranchChanges,
                configuredBaseBranch: context.configuredBaseBranch
            )
        )
    }
}
