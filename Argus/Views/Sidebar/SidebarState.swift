// SidebarState.swift
// Argus
//
// Observable state for the left workspace sidebar and right git sidebar.
// Tracks visibility and user-adjusted width for each panel.

import SwiftUI

/// State for the left (workspace) sidebar.
@MainActor
final class SidebarState: ObservableObject {
    /// Whether the sidebar is currently shown.
    @Published var isVisible: Bool = true

    /// Current width in points. Constrained to 80–600 by the divider gesture;
    /// default 200 per spec.
    @Published var width: CGFloat = 200

    /// Toggle sidebar visibility.
    func toggle() { isVisible.toggle() }
}

/// State for the right git-status sidebar (Phase 3 placeholder).
@MainActor
final class GitSidebarState: ObservableObject {
    /// Whether the git sidebar is currently shown. Off by default until
    /// Phase 3 is implemented.
    @Published var isVisible: Bool = false

    /// Current width in points. Constrained to 180–600 by the divider gesture;
    /// default 250 per spec.
    @Published var width: CGFloat = 250

    /// Toggle git sidebar visibility.
    func toggle() { isVisible.toggle() }
}
