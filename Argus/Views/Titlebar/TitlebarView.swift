// TitlebarView.swift
// Argus
//
// Custom titlebar overlay showing the active workspace title.
// Transparent background so the system titlebar and traffic lights
// show through. Placeholder right area reserved for Phase 3 git info.

import SwiftUI

struct TitlebarView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        HStack {
            // Left spacer for macOS traffic light buttons (~70px)
            Color.clear.frame(width: 70)

            Spacer()

            // Center: active workspace title
            if let workspace = workspaceManager.selectedWorkspace {
                Text(workspace.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Right spacer (reserved for git branch info in Phase 3)
            Color.clear.frame(width: 70)
        }
        .frame(height: 28)
        .background(Color.clear)
    }
}
