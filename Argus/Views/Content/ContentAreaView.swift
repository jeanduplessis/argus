// ContentAreaView.swift
// Argus

import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let workspace = workspaceManager.selectedWorkspace {
            WorkspaceContentView(workspace: workspace)
                .id(workspace.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No panels open")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observes a single workspace and renders its tab bar + panel content.
/// This MUST be a separate view with `@ObservedObject` so that changes
/// to `workspace.activePanelId` trigger a re-render.
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            TitlebarView()
                .allowsHitTesting(false)

            TabBarView(workspace: workspace)

            if let layout = workspace.activeTabLayout {
                PanelSplitLayoutView(workspace: workspace, node: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recursively renders the pane layout for the active tab.
struct PanelSplitLayoutView: View {
    @ObservedObject var workspace: Workspace
    let node: PanelLayoutNode

    var body: some View {
        switch node {
        case .leaf(let panelId):
            if let panel = workspace.panels[panelId] {
                let active = panelId == workspace.activePanelId
                PanelContentView(
                    panel: panel,
                    isActive: active
                )
                .contentShape(Rectangle())
                .onTapGesture { workspace.selectPanel(panelId) }
            }
        case .split(let direction, let first, let second):
            switch direction {
            case .vertical:
                HStack(spacing: 0) {
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: first
                    )
                    ChromeColors.separator.frame(width: 1)
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: second
                    )
                }
            case .horizontal:
                VStack(spacing: 0) {
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: first
                    )
                    ChromeColors.separator.frame(height: 1)
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: second
                    )
                }
            }
        }
    }
}

// MARK: - Panel Content View

struct PanelContentView: View {
    let panel: any Panel
    var isActive: Bool = true

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalView(surface: terminalPanel.surface, isActive: isActive)
                    // The representable occupies the same structural position
                    // for every tab. Key it by surface so SwiftUI cannot reuse
                    // the previous tab's TerminalNSView for a new surface.
                    .id(terminalPanel.surface.id)
            }
        case .browser:
            Text("Browser panel — coming in Phase 5")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
