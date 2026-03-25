// ContentAreaView.swift
// Argus

import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let workspace = workspaceManager.selectedWorkspace {
            WorkspaceContentView(workspace: workspace)
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
            TabBarView(workspace: workspace)

            ZStack {
                ForEach(workspace.panelOrder, id: \.self) { panelId in
                    if let panel = workspace.panels[panelId] {
                        let active = panelId == workspace.activePanelId
                        PanelContentView(panel: panel, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        case .browser:
            Text("Browser panel — coming in Phase 5")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
