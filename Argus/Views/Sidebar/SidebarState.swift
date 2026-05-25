// SidebarState.swift
// Argus
//
// Observable state for the left workspace sidebar and right git sidebar.
// Tracks visibility and user-adjusted width for each panel.

import SwiftUI

/// State for the left (workspace) sidebar.
@MainActor
final class SidebarState: ObservableObject {
    private enum Keys {
        static let isVisible = "Argus.sidebar.isVisible"
        static let width = "Argus.sidebar.width"
    }

    private let defaults: UserDefaults
    static let defaultWidth: CGFloat = 200
    static let minWidth: CGFloat = 80
    static let maxPersistedWidth: CGFloat = 600

    /// Whether the sidebar is currently shown.
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Keys.isVisible) }
    }

    /// Current width in points. Constrained to 80–600 by persisted restore;
    /// live drag constraints may apply a smaller geometry-based max.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Keys.width) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isVisible) == nil {
            self.isVisible = true
        } else {
            self.isVisible = defaults.bool(forKey: Keys.isVisible)
        }

        if defaults.object(forKey: Keys.width) == nil {
            self.width = Self.defaultWidth
        } else {
            self.width = Self.clamp(defaults.double(forKey: Keys.width))
        }
    }

    /// Toggle sidebar visibility.
    func toggle() { isVisible.toggle() }

    static func clamp(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), minWidth), maxPersistedWidth)
    }
}

/// State for the right git-status sidebar (Phase 3 placeholder).
@MainActor
final class GitSidebarState: ObservableObject {
    private enum Keys {
        static let isVisible = "Argus.gitSidebar.isVisible"
        static let width = "Argus.gitSidebar.width"
    }

    private let defaults: UserDefaults
    static let defaultWidth: CGFloat = 250
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 600

    /// Whether the git sidebar is currently shown. Off by default until
    /// Phase 3 is implemented.
    @Published var isVisible: Bool {
        didSet { defaults.set(isVisible, forKey: Keys.isVisible) }
    }

    /// Current width in points. Constrained to 180–600 by persisted restore;
    /// the divider gesture applies the same live range.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Keys.width) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isVisible) == nil {
            self.isVisible = false
        } else {
            self.isVisible = defaults.bool(forKey: Keys.isVisible)
        }

        if defaults.object(forKey: Keys.width) == nil {
            self.width = Self.defaultWidth
        } else {
            self.width = Self.clamp(defaults.double(forKey: Keys.width))
        }
    }

    /// Toggle git sidebar visibility.
    func toggle() { isVisible.toggle() }

    static func clamp(_ width: Double) -> CGFloat {
        min(max(CGFloat(width), minWidth), maxWidth)
    }
}
