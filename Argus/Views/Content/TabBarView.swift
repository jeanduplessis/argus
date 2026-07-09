// TabBarView.swift
// Argus
//
// Per-workspace tab bar displayed at the top of the content area.
// Shows one tab per panel in tab order, with a close button
// and a "+" button to add a new terminal tab.

import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager

    @State private var renamePanelId: UUID?
    @State private var renameText = ""
    @State private var showRenameAlert = false

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.panelOrder, id: \.self) { panelId in
                        if let panel = workspace.panels[panelId] {
                            TabItemView(
                                panel: panel,
                                title: workspace.tabDisplayTitle(for: panelId),
                                isActive: panelId == workspace.activeTabId,
                                onSelect: { workspace.selectPanel(panelId) },
                                onRename: panel.panelType == .terminal ? {
                                    renamePanelId = panelId
                                    renameText = workspace.tabDisplayTitle(for: panelId)
                                    showRenameAlert = true
                                } : nil,
                                onClose: {
                                    if workspace.panelOrder.count == 1,
                                       workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id) {
                                        NotificationCenter.default.post(
                                            name: .showCloseWorkspaceConfirmation,
                                            object: nil,
                                            userInfo: ["workspaceId": workspace.id]
                                        )
                                        return
                                    }

                                    workspace.removePanel(panelId)
                                    if workspace.panelOrder.isEmpty {
                                        workspaceManager.removeWorkspace(workspace.id)
                                    }
                                }
                            )
                            .onDrag {
                                PanelTabDragState.draggedPanelId = panelId
                                return NSItemProvider(object: panelId.uuidString as NSString)
                            }
                            .onDrop(
                                of: [UTType.text],
                                delegate: PanelTabDropDelegate(
                                    workspace: workspace,
                                    targetPanelId: panelId
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // New tab button
            Button(action: { workspace.addTerminalPanel() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
        .frame(height: 30)
        .background(ChromeColors.contentBackground)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
        .alert("Rename Terminal", isPresented: $showRenameAlert) {
            TextField("Terminal title", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let renamePanelId {
                    workspace.renameTerminalPanel(renamePanelId, title: renameText)
                }
            }
        }
    }
}

// MARK: - Tab Drag and Drop

@MainActor
private enum PanelTabDragState {
    static var draggedPanelId: UUID?
}

private struct PanelTabDropDelegate: DropDelegate {
    let workspace: Workspace
    let targetPanelId: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedPanelId = PanelTabDragState.draggedPanelId else { return false }
        defer { PanelTabDragState.draggedPanelId = nil }
        guard draggedPanelId != targetPanelId,
              let source = workspace.panelOrder.firstIndex(of: draggedPanelId),
              let destination = workspace.panelOrder.firstIndex(of: targetPanelId)
        else { return false }

        workspace.reorderPanel(from: source, to: destination)
        return true
    }
}

// MARK: - Tab Item

struct TabItemView: View {
    let panel: any Panel
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onRename: (() -> Void)?
    let onClose: () -> Void

    @State private var isHovered = false

    private var tabFill: Color {
        if isActive { return ChromeColors.activeTabFill }
        if isHovered { return ChromeColors.hoveredTabFill }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 4) {
            // Panel icon
            if let icon = panel.displayIcon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .primary : .secondary)
            }

            // Tab title
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)

            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 14, height: 14)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(tabFill)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Close", role: .destructive, action: onClose)
            if let onRename {
                Button("Rename", action: onRename)
            }
        }
    }
}
