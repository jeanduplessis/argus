// Project and Workspace menus share their close/configuration presentation in this file.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct SidebarProjectContentInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var sidebarProjectContentInset: CGFloat {
        get { self[SidebarProjectContentInsetKey.self] }
        set { self[SidebarProjectContentInsetKey.self] = newValue }
    }
}

// MARK: - ProjectSection

/// A collapsible project section containing a header row and its child
/// workspace rows.
struct ProjectSection: View {
    @ObservedObject var project: Project
    var collectionId: UUID?
    var items: [WorkspaceSidebarItem]
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var pullRequestStatusModel: WorkspacePullRequestStatusModel
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarCollectionContentInset) private var collectionContentInset

    private var disclosure: RepositoryDisclosure {
        workspaceManager.repositoryDisclosure(for: project.id, in: collectionId)
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeaderRow(project: project, collectionId: collectionId)
                .windowFocusChrome()
                .modifier(SidebarNavigationDropTarget(target: collectionId.map { .collection($0) } ?? .ungrouped))
                .padding(.top, 4)

            if disclosure.isExpanded {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        switch item {
                        case .workspace(let workspaceId):
                            workspaceRow(workspaceId)
                        case .stack(let group):
                            stackSection(group)
                                .id(group.id)
                        }
                    }
                }
                .environment(\.sidebarProjectContentInset, sidebarMetrics.projectContentInset)
                .overlay(alignment: .leading) {
                    // Overlay keeps the scope visible across full-width selection fills.
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: collectionContentInset + sidebarMetrics.projectGuideOffset - 0.5)
                        .windowFocusChrome()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            } else {
                SidebarCollapsedWorkspaceSummary(workspaceIds: items.flatMap(\.workspaceIds))
                    .environment(\.sidebarProjectContentInset, sidebarMetrics.projectContentInset)
            }
        }
        .onChange(of: disclosure.isExpanded) { _, isExpanded in
            if isExpanded { pullRequestStatusModel.refreshProject(projectID: project.id) }
        }
    }

    @ViewBuilder
    func workspaceRow(_ workspaceId: UUID, stackRelationship: WorkspaceStackRow? = nil) -> some View {
        if let workspace = workspaceManager.workspaces.first(where: { $0.id == workspaceId }) {
            SidebarWorkspaceEntry(workspace: workspace, stackRelationship: stackRelationship)
        }
    }

    func workspaceMoveActions(for workspaceId: UUID, isStack: Bool) -> some View {
        Group {
            Button("Move Stack Up") { workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: -1) }
                .disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: -1))
            Button("Move Stack Down") { workspaceManager.moveWorkspace(in: project.id, moving: workspaceId, offset: 1) }
                .disabled(!workspaceManager.canMoveWorkspace(in: project.id, moving: workspaceId, offset: 1))
        }
    }
}

struct SidebarWorkspaceEntry: View {
    @ObservedObject var workspace: Workspace
    var stackRelationship: WorkspaceStackRow?
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        SidebarWorkspaceRow(
            workspace: workspace,
            globalIndex: workspaceManager.globalSidebarIndex(for: workspace.id) ?? 1,
            shortcutDigit: workspaceManager.workspaceShortcutDigit(for: workspace.id),
            isSelected: workspace.id == workspaceManager.selectedWorkspaceId,
            onSelect: { workspaceManager.selectWorkspace(workspace.id) },
            stackRelationship: stackRelationship, showsStackGutter: stackRelationship != nil
        )
        .onDrag { workspaceManager.workspaceDrag(workspace.id).itemProvider }
        .modifier(SidebarNavigationDropTarget(target: .workspace(workspace.id)))
        .contextMenu { workspaceContextMenu(for: workspace, isStack: stackRelationship != nil) }
        .id(workspace.id)
    }

    @ViewBuilder
    private func workspaceContextMenu(for workspace: Workspace, isStack: Bool) -> some View {
        Button("Rename…") {
            NotificationCenter.default.post(
                name: .showRenameWorkspaceSheet,
                object: nil,
                userInfo: ["workspaceId": workspace.id]
            )
        }
        if workspace.workspaceType == .external {
            Button("Change Working Directory…") {
                chooseWorkspaceRoot(for: workspace)
            }
            Button("Enter Path Directly…") {
                NotificationCenter.default.post(
                    name: .showChangeWorkspaceRootSheet,
                    object: nil,
                    userInfo: ["workspaceId": workspace.id]
                )
            }
        }
        WorkspaceCollectionMenu(workspaceId: workspace.id)
        workspaceMoveActions(for: workspace.id, isStack: isStack)
        if workspaceManager.setupPanel(in: workspace) != nil || workspaceManager.canRunWorktreeSetup(in: workspace) {
            Divider()
            Button("Show Worktree Setup") { workspaceManager.showWorktreeSetup(in: workspace) }
            Button("Run Setup Again") { workspaceManager.runWorktreeSetupAgain(in: workspace) }
                .disabled(!workspaceManager.canRunWorktreeSetup(in: workspace) || workspace.runningSetupCount > 0)
        }
        if appSettings.showPullRequestStatus, workspace.projectId != nil,
            workspace.workspaceType == .worktree, workspace.worktreePath?.isEmpty == false
        {
            Divider()
            PullRequestStatusMenuItems(workspaceID: workspace.id)
        }
        Divider()
        Button("Copy Path") {
            copyPath(workspace.worktreePath)
        }
        .disabled(workspace.worktreePath == nil)
        Divider()
        Button("Close Workspace") {
            workspaceManager.requestCloseWorkspace(workspace.id)
        }
    }

    @ViewBuilder
    func workspaceMoveActions(for workspaceId: UUID, isStack: Bool) -> some View {
        Button(isStack ? "Move Stack Up" : "Move Up") {
            workspaceManager.moveWorkspace(
                in: workspaceManager.project(for: workspaceId)?.id, moving: workspaceId, offset: -1)
        }
        .disabled(
            !workspaceManager.canMoveWorkspace(
                in: workspaceManager.project(for: workspaceId)?.id, moving: workspaceId, offset: -1))
        Button(isStack ? "Move Stack Down" : "Move Down") {
            workspaceManager.moveWorkspace(
                in: workspaceManager.project(for: workspaceId)?.id, moving: workspaceId, offset: 1)
        }
        .disabled(
            !workspaceManager.canMoveWorkspace(
                in: workspaceManager.project(for: workspaceId)?.id, moving: workspaceId, offset: 1))
    }

    private func copyPath(_ path: String?) {
        guard let path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private func chooseWorkspaceRoot(for workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workspace.currentDirectory)
        panel.message = "Select the working directory for \(workspace.displayTitle)"
        guard panel.runModal() == .OK, let directoryURL = panel.url else { return }
        if !workspaceManager.setStandaloneWorkspaceRoot(workspace.id, directoryURL: directoryURL),
            let error = workspaceManager.lastWorkspaceCreationError
        {
            let alert = NSAlert()
            alert.messageText = "Could Not Change Working Directory"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - ProjectHeaderRow

/// Disclosure-triangle header for a project. Shows repository symbol, optional color dot, display name,
/// and provides a context menu for project operations.
private struct ProjectHeaderRow: View {
    @ObservedObject var project: Project
    let collectionId: UUID?
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarCollectionContentInset) private var collectionContentInset
    @State private var isHovered = false
    @State private var isAddHovered = false
    @State private var showsWorktreeSetup = false
    @FocusState private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case disclosure
        case add
    }

    private var disclosure: RepositoryDisclosure {
        workspaceManager.repositoryDisclosure(for: project.id, in: collectionId)
    }

    private var creationRequest: WorkspaceCreationRequest {
        WorkspaceCreationRequest(projectId: project.id, collectionId: collectionId)
    }

    private var showsAddAction: Bool {
        isHovered || focusedControl != nil
    }

    private var hasStackDiscoveryStatus: Bool {
        (workspaceManager.refreshingWorkspaceStackProjectIds.contains(project.id)
            || workspaceManager.workspaceStackErrors[project.id] != nil)
    }

    var body: some View {
        HStack(spacing: sidebarMetrics.headerSpacing) {
            disclosureButton
            if !sidebarMetrics.isCompact || hasStackDiscoveryStatus {
                SidebarStackDiscoveryStatus(projectId: project.id)
            }
            if !sidebarMetrics.isCompact || !hasStackDiscoveryStatus {
                addWorkspaceButton
            }
        }
        .padding(.leading, collectionContentInset)
        .padding(.horizontal, sidebarMetrics.rowPadding)
        .padding(.vertical, appSettings.presentationMetrics.projectHeaderVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || focusedControl != nil ? ChromeColors.hoveredTabFill : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("New Workspace…") {
                NotificationCenter.default.post(name: .showNewWorkspaceSheet, object: creationRequest)
            }
            Button("Rename Repository…") {
                NotificationCenter.default.post(
                    name: .showRenameProjectSheet, object: nil,
                    userInfo: ["projectId": project.id])
            }
            Button("Worktree Setup…") { showsWorktreeSetup = true }
            Button("Refresh Stacks") { workspaceManager.refreshWorkspaceStacks(in: project.id) }
                .disabled(workspaceManager.refreshingWorkspaceStackProjectIds.contains(project.id))
        }
        .sheet(isPresented: $showsWorktreeSetup) {
            WorktreeSetupSheet(project: project).environmentObject(workspaceManager)
        }

    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                workspaceManager.toggleRepository(project.id, in: collectionId)
            }
        } label: {
            HStack(spacing: 0) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: disclosure.isExpanded)
                    .frame(width: sidebarMetrics.projectDisclosureWidth)
                    .padding(.trailing, sidebarMetrics.headerSpacing)

                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: sidebarMetrics.projectIconWidth)
                    .overlay(alignment: .bottomTrailing) {
                        // A badge preserves the optional color without moving the name column.
                        if let color = project.color {
                            Circle()
                                .fill(Color(nsColor: color.nsColor))
                                .frame(
                                    width: sidebarMetrics.isCompact ? 4 : 8, height: sidebarMetrics.isCompact ? 4 : 8
                                )
                                .offset(x: 2, y: 3)
                        }
                    }
                    .accessibilityHidden(true)
                    .padding(.trailing, sidebarMetrics.rowSpacing)

                Text(project.displayName)
                    .font(
                        .system(
                            size: appSettings.presentationMetrics.textSize(forBaseSize: 13),
                            weight: .semibold
                        )
                    )
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                if !sidebarMetrics.isCompact {
                    Spacer(minLength: 0)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .disclosure)
        .cursor(.pointingHand)
        .accessibilityLabel("\(project.displayName), Project")
        .accessibilityValue(disclosure.isExpanded ? "Expanded" : "Collapsed")
        .help("\(disclosure.isExpanded ? "Collapse" : "Expand") \(project.displayName) Project")
    }

    private var addWorkspaceButton: some View {
        Button {
            NotificationCenter.default.post(name: .showNewWorkspaceSheet, object: creationRequest)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isAddHovered || focusedControl == .add ? ChromeColors.hoveredTabFill : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focused($focusedControl, equals: .add)
        .opacity(showsAddAction ? 1 : 0)
        .allowsHitTesting(showsAddAction)
        .accessibilityHidden(!showsAddAction)
        .onHover { isAddHovered = $0 }
        .cursor(.pointingHand)
        .help("Add Workspace")
        .accessibilityLabel("Add Workspace to \(project.displayName)")
    }

}
