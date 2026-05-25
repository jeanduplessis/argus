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
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundColor(.secondary)
            .help("New Workspace or Project")
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
                            isSelected: workspace.id == workspaceManager.selectedWorkspaceId
                        )
                        .onTapGesture {
                            workspaceManager.selectWorkspace(workspace.id)
                        }
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
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Disclosure triangle
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: project.isExpanded)
                .frame(width: 12)

            // Optional color dot
            if let color = project.color {
                Circle()
                    .fill(Color(nsColor: color.nsColor))
                    .frame(width: 8, height: 8)
            }

            // Project name
            Text(project.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

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
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Add Workspace")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                project.isExpanded.toggle()
            }
        }
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
                Button("Remove Project") {
                    Task {
                        await workspaceManager.removeProject(project.id)
                    }
                }
            }
        }
    }
}

// MARK: - SidebarWorkspaceRow

/// Individual workspace row showing global index, type icon, display title,
/// branch name, and panel count badge.
private struct SidebarWorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    let globalIndex: Int
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // 1-based global index (for Cmd+N shortcut reference)
            Text("\(globalIndex)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 16)

            // Workspace type icon
            Image(systemName: workspace.workspaceType.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 14)

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
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor
        } else if isHovered {
            return Color.secondary.opacity(0.1)
        } else {
            return Color.clear
        }
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
