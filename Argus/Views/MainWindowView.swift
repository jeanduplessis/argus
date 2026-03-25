// MainWindowView.swift
// Argus
//
// Root view for the main window. Three-column layout with draggable dividers:
// left sidebar | content area | right git sidebar.

import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @StateObject private var sidebarState = SidebarState()
    @StateObject private var gitSidebarState = GitSidebarState()

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar
            if sidebarState.isVisible {
                SidebarView()
                    .frame(width: sidebarState.width)
                SidebarDivider(
                    position: $sidebarState.width,
                    minValue: 80,
                    maxValue: maxSidebarWidth
                )
            }

            // Content area (fills remaining space)
            ContentAreaView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right git sidebar
            if gitSidebarState.isVisible {
                GitSidebarDivider(
                    position: $gitSidebarState.width,
                    minValue: 180,
                    maxValue: 600
                )
                GitSidebarPlaceholder()
                    .frame(width: gitSidebarState.width)
            }
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(sidebarState)
        .environmentObject(gitSidebarState)
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            sidebarState.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleGitSidebar)) { _ in
            gitSidebarState.toggle()
        }
    }

    /// Maximum sidebar width — capped at a reasonable value since we don't
    /// track the live window width from SwiftUI geometry.
    private var maxSidebarWidth: CGFloat { 400 }
}
