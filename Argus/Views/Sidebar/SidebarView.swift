// SidebarView.swift
// Argus
//
// Left sidebar showing the flat workspace list (Phase 1 — no projects).
// Each row displays a 1-based index, terminal icon, display title,
// and a panel-count badge when the workspace has more than one tab.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            // Header with section title and add-workspace button
            HStack {
                Text("Workspaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button(action: { workspaceManager.addWorkspace() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .padding(.top, 28) // Space for titlebar traffic lights

            // Workspace list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(
                        Array(workspaceManager.workspaces.enumerated()),
                        id: \.element.id
                    ) { index, workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            index: index + 1,
                            isSelected: workspace.id == workspaceManager.selectedWorkspaceId
                        )
                        .onTapGesture {
                            workspaceManager.selectWorkspace(workspace.id)
                        }
                        .contextMenu {
                            Button("Rename…") {
                                // TODO: Phase 1 — show rename dialog
                            }
                            Divider()
                            Button("Close Workspace") {
                                workspaceManager.removeWorkspace(workspace.id)
                            }
                        }
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

// MARK: - Workspace Row

struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    let index: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // 1-based index badge (for Cmd+N shortcut reference)
            Text("\(index)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 16)

            // Terminal icon
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .white : .secondary)

            // Workspace title
            Text(workspace.displayTitle)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Panel count badge (shown when > 1 tab)
            if workspace.panelOrder.count > 1 {
                Text("\(workspace.panelOrder.count)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
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
