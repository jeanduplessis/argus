// SidebarView.swift
// Argus
//
// Left sidebar showing the two-level project hierarchy (Phase 2).
// Projects appear as collapsible headers; workspaces are children.
// The catch-all project shows standalone workspaces under "Workspaces".

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notification Names

extension Notification.Name {
    static let showNewProjectSheet = Notification.Name("ArgusShowNewProjectSheet")
    static let showNewWorkspaceSheet = Notification.Name("ArgusShowNewWorkspaceSheet")
    static let showRenameProjectSheet = Notification.Name("ArgusShowRenameProjectSheet")
    static let showRenameWorkspaceSheet = Notification.Name("ArgusShowRenameWorkspaceSheet")
    static let showCloseWorkspaceConfirmation = Notification.Name("ArgusShowCloseWorkspaceConfirmation")
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and global add buttons
            SidebarHeader()

            // Project sections
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Named projects first
                    ForEach(workspaceManager.namedProjects, id: \.id) { project in
                        ProjectSection(project: project)
                    }

                    // Catch-all project last
                    if let catchAll = workspaceManager.catchAllProject {
                        ProjectSection(project: catchAll)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }
}

// MARK: - Sidebar Header

/// Top header with "Projects" label and add-project / add-workspace buttons.
private struct SidebarHeader: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack {
            Text("Projects")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            // Global add menu for standalone workspaces and projects.
            Menu {
                Button(action: {
                    workspaceManager.addWorkspace()
                }) {
                    Label("New Workspace", systemImage: "terminal")
                }

                Button(action: {
                    NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
                }) {
                    Label("New Project…", systemImage: "folder.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundColor(.secondary)
            .help("New Workspace or Project")
            .accessibilityLabel("New Workspace or Project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .padding(.top, 28) // Space for titlebar traffic lights
    }
}

// MARK: - ProjectSection

/// A collapsible project section containing a header row and its child
/// workspace rows.
private struct ProjectSection: View {
    @ObservedObject var project: Project
    @EnvironmentObject var workspaceManager: WorkspaceManager

    /// Workspaces belonging to this project, in project workspace order.
    private var childWorkspaces: [Workspace] {
        project.workspaceIds.compactMap { wsId in
            workspaceManager.workspaces.first { $0.id == wsId }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeaderRow(project: project)
                .padding(.top, 4)

            if project.isExpanded {
                ForEach(childWorkspaces, id: \.id) { workspace in
                    if let globalIndex = workspaceManager.globalSidebarIndex(for: workspace.id) {
                        SidebarWorkspaceRow(
                            workspace: workspace,
                            globalIndex: globalIndex,
                            isSelected: workspace.id == workspaceManager.selectedWorkspaceId,
                            onSelect: { workspaceManager.selectWorkspace(workspace.id) }
                        )
                        .onDrag {
                            SidebarWorkspaceDragState.draggedWorkspaceId = workspace.id
                            return NSItemProvider(object: workspace.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: SidebarWorkspaceDropDelegate(
                                workspaceManager: workspaceManager,
                                projectId: project.id,
                                targetWorkspaceId: workspace.id
                            )
                        )
                        .contextMenu {
                            Button("Rename…") {
                                NotificationCenter.default.post(
                                    name: .showRenameWorkspaceSheet,
                                    object: nil,
                                    userInfo: ["workspaceId": workspace.id]
                                )
                            }
                            Button("Move Up") {
                                moveWorkspaceUp(workspace.id)
                            }
                            .disabled(project.workspaceIds.first == workspace.id)
                            Button("Move Down") {
                                moveWorkspaceDown(workspace.id)
                            }
                            .disabled(project.workspaceIds.last == workspace.id)
                            Divider()
                            Button("Close Workspace") {
                                if workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id) {
                                    NotificationCenter.default.post(
                                        name: .showCloseWorkspaceConfirmation,
                                        object: nil,
                                        userInfo: ["workspaceId": workspace.id]
                                    )
                                } else {
                                    workspaceManager.removeWorkspace(workspace.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func moveWorkspaceUp(_ workspaceId: UUID) {
        guard let index = project.workspaceIds.firstIndex(of: workspaceId),
              index > 0 else { return }
        workspaceManager.reorderWorkspace(
            in: project.id,
            moving: workspaceId,
            before: project.workspaceIds[index - 1]
        )
    }

    private func moveWorkspaceDown(_ workspaceId: UUID) {
        guard let index = project.workspaceIds.firstIndex(of: workspaceId),
              index < project.workspaceIds.count - 1 else { return }
        workspaceManager.reorderWorkspace(
            in: project.id,
            moving: project.workspaceIds[index + 1],
            before: workspaceId
        )
    }
}

// MARK: - Workspace Drag and Drop

@MainActor
private enum SidebarWorkspaceDragState {
    static var draggedWorkspaceId: UUID?
}

private struct SidebarWorkspaceDropDelegate: DropDelegate {
    let workspaceManager: WorkspaceManager
    let projectId: UUID
    let targetWorkspaceId: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedWorkspaceId = SidebarWorkspaceDragState.draggedWorkspaceId else { return false }
        defer { SidebarWorkspaceDragState.draggedWorkspaceId = nil }
        workspaceManager.reorderWorkspace(
            in: projectId,
            moving: draggedWorkspaceId,
            before: targetWorkspaceId
        )
        return true
    }
}

// MARK: - ProjectHeaderRow

/// Disclosure-triangle header for a project. Shows color dot, display name,
/// and provides a context menu for project operations.
private struct ProjectHeaderRow: View {
    @ObservedObject var project: Project
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isAddHovered = false
    @State private var showRemoveConfirmation = false
    @State private var isRemovingProject = false
    @FocusState private var focusedControl: FocusedControl?

    private enum FocusedControl: Hashable {
        case disclosure
        case add
    }

    private var childWorkspaces: [Workspace] {
        project.workspaceIds.compactMap { workspaceId in
            workspaceManager.workspaces.first { $0.id == workspaceId }
        }
    }

    private var showsAddAction: Bool {
        isHovered || focusedControl != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    project.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: project.isExpanded)
                        .frame(width: 12)

                    if let color = project.color {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 8, height: 8)
                    }

                    Text(project.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .disclosure)
            .cursor(.pointingHand)
            .accessibilityLabel("\(project.displayName), Project")
            .accessibilityValue(project.isExpanded ? "Expanded" : "Collapsed")
            .help(project.isExpanded ? "Collapse Project" : "Expand Project")

            // Add workspace to this project
            Button(action: {
                if project.isCatchAll {
                    workspaceManager.addWorkspace()
                } else {
                    NotificationCenter.default.post(
                        name: .showNewWorkspaceSheet,
                        object: nil,
                        userInfo: ["projectId": project.id]
                    )
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isAddHovered || focusedControl == .add ? Color.primary.opacity(0.1) : Color.clear)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered || focusedControl != nil ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            if project.isCatchAll {
                Button("Add Workspace…") {
                    workspaceManager.addWorkspace()
                }
            } else {
                Button("Rename…") {
                    NotificationCenter.default.post(
                        name: .showRenameProjectSheet,
                        object: nil,
                        userInfo: ["projectId": project.id]
                    )
                }
                Button("Add Workspace…") {
                    NotificationCenter.default.post(
                        name: .showNewWorkspaceSheet,
                        object: nil,
                        userInfo: ["projectId": project.id]
                    )
                }
                Divider()
                Button("Remove Project", role: .destructive) {
                    showRemoveConfirmation = true
                }
                .disabled(isRemovingProject)
            }
        }
        .alert("Remove Project \"\(project.displayName)\"?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove Project", role: .destructive) {
                isRemovingProject = true
                Task {
                    await workspaceManager.removeProject(project.id)
                }
            }
        } message: {
            Text(projectRemovalMessage)
        }
    }

    private var projectRemovalMessage: String {
        let workspaceCount = childWorkspaces.count
        let worktreeCount = childWorkspaces.filter { $0.worktreePath != nil }.count
        let workspaceLabel = workspaceCount == 1 ? "Workspace" : "Workspaces"
        let worktreeLabel = worktreeCount == 1 ? "worktree" : "worktrees"
        return "This permanently removes \(workspaceCount) \(workspaceLabel) from Argus and deletes \(worktreeCount) associated \(worktreeLabel) from disk. This cannot be undone."
    }
}

// MARK: - SidebarWorkspaceRow

/// Individual workspace row showing global index, type icon, display title,
/// branch name, and panel count badge.
private struct SidebarWorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var agentStatusStore: AgentStatusStore
    let globalIndex: Int
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // 1-based global index (for Cmd+N shortcut reference)
                Text("\(globalIndex)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                if let agentStatus {
                    Image(systemName: agentStatus.state.symbolName)
                        .font(.system(size: 11))
                        .foregroundColor(agentStatus.state.color)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: workspace.workspaceType.icon)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white : .secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }

                // Title and branch
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.displayTitle)
                        .font(.system(size: 13))
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let branch = workspace.branchName {
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                // Panel count badge (shown when > 1 tab)
                if workspace.panelCount > 1 {
                    Text("\(workspace.panelCount)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(focusColor, lineWidth: isFocused ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .cursor(.pointingHand)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(workspaceAccessibilityLabel)
        .accessibilityValue(workspaceAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var agentStatus: AgentStatusEntry? {
        let panels = Array(workspace.panels.values)
        return agentStatusStore.workspaceSummary(
            workspaceId: workspace.id,
            terminalSurfaceIds: panels.filter { $0.panelType == .terminal }.map(\.id),
            includesNonterminalPanels: panels.contains { $0.panelType != .terminal }
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered || isFocused {
            return Color.secondary.opacity(0.1)
        } else {
            return Color.clear
        }
    }

    private var focusColor: Color {
        isSelected ? Color.white.opacity(0.7) : Color.accentColor
    }

    private var workspaceAccessibilityLabel: String {
        var parts = ["Workspace \(globalIndex)", workspace.displayTitle, workspace.workspaceType.label]
        if let branch = workspace.branchName {
            parts.append("branch \(branch)")
        }
        if workspace.panelCount > 1 {
            parts.append("\(workspace.panelCount) tabs")
        }
        return parts.joined(separator: ", ")
    }

    private var workspaceAccessibilityValue: String {
        var values = [isSelected ? "Selected" : "Not selected"]
        if let agentStatus {
            values.append("Agent status: \(agentStatus.state.label)")
        }
        return values.joined(separator: ", ")
    }
}

// MARK: - NSVisualEffectView Wrapper

/// NSViewRepresentable wrapping `NSVisualEffectView` for vibrancy backgrounds
/// (sidebar material).
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
