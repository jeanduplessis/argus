// TabBarView.swift
// Argus
//
// Per-workspace tab bar displayed at the top of the content area.
// Shows one tab per panel in tab order, with a close button on hover
// and a "+" button to add a new terminal tab.

import SwiftUI

struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack(spacing: 0) {
            // Scrollable tab strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.panelOrder, id: \.self) { panelId in
                        if let panel = workspace.panels[panelId] {
                            TabItemView(
                                panel: panel,
                                isActive: panelId == workspace.activePanelId,
                                onSelect: { workspace.selectPanel(panelId) },
                                onClose: {
                                    workspace.removePanel(panelId)
                                    if workspace.panelOrder.isEmpty {
                                        workspaceManager.removeWorkspace(workspace.id)
                                    }
                                }
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
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Tab Item

struct TabItemView: View {
    let panel: any Panel
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            // Panel icon
            if let icon = panel.displayIcon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(isActive ? .primary : .secondary)
            }

            // Panel title
            Text(panel.displayTitle)
                .font(.system(size: 12))
                .foregroundColor(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)

            // Close button — visible on hover or when tab is active
            if isHovered || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 14, height: 14)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onSelect)
    }
}
