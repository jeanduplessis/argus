import Foundation
import SwiftUI
import Combine

/// A workspace containing an ordered list of tabbed panels.
///
/// Each workspace maps to a single git worktree (or a standalone directory)
/// and presents its panels as tabs in the content area. Exactly one panel
/// is active (visible) at a time.
///
/// The spec (§Workspaces) requires:
/// - Ordered tabbed panels with tab bar display.
/// - Exactly one active panel per workspace.
/// - Panel creation, removal, reordering, and selection.
/// - Workspace renaming with default name derived from the shell's cwd.
@MainActor
final class Workspace: Identifiable, ObservableObject {

    // MARK: - Identity

    let id: UUID

    // MARK: - Published state

    /// Title derived from shell working directory or process title.
    @Published var title: String

    /// User-assigned custom title. When non-nil and non-empty, takes
    /// precedence over the derived `title` in the sidebar and titlebar.
    @Published var customTitle: String?

    /// Working directory for this workspace (worktree root or standalone dir).
    @Published var currentDirectory: String

    /// Ordered panel IDs defining tab order left-to-right.
    @Published private(set) var panelOrder: [UUID] = []

    /// Panel instances keyed by their `id`. Uses `any Panel` existential
    /// because a workspace can contain mixed terminal and browser panels.
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// The `id` of the currently active (visible) panel, or `nil` if the
    /// workspace has no panels.
    @Published var activePanelId: UUID?

    // MARK: - Computed properties

    /// The currently active panel instance.
    var activePanel: (any Panel)? {
        guard let id = activePanelId else { return nil }
        return panels[id]
    }

    /// The title shown in the sidebar and titlebar.
    /// Prefers the user-assigned `customTitle` over the derived `title`.
    var displayTitle: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        return title.isEmpty ? "Terminal" : title
    }

    /// Number of panels in this workspace.
    var panelCount: Int { panelOrder.count }

    // MARK: - Initializer

    /// Creates a new workspace with a single terminal panel.
    ///
    /// - Parameters:
    ///   - title: Initial workspace title. Defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory. Defaults to the
    ///     user's home directory when `nil`.
    init(title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = UUID()
        self.title = title
        self.currentDirectory = workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Spec §Workspaces rule 7: new workspaces start with one terminal panel.
        let panel = TerminalPanel(workspaceId: id, workingDirectory: workingDirectory)
        addPanel(panel)
    }

    // MARK: - Panel Management

    /// Adds a panel to this workspace at the end of the tab order.
    ///
    /// If no panel is currently active, the new panel becomes active.
    func addPanel(_ panel: any Panel) {
        panels[panel.id] = panel
        panelOrder.append(panel.id)
        if activePanelId == nil {
            activePanelId = panel.id
        }
    }

    /// Creates a new terminal panel, adds it to the workspace, and makes it
    /// the active panel.
    ///
    /// - Parameter workingDirectory: Working directory for the new terminal.
    ///   Defaults to this workspace's `currentDirectory`.
    /// - Returns: The newly created terminal panel.
    @discardableResult
    func addTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel {
        let panel = TerminalPanel(
            workspaceId: id,
            workingDirectory: workingDirectory ?? currentDirectory
        )

        // Insert after the currently active tab (standard tab UX).
        panels[panel.id] = panel
        if let activeId = activePanelId,
           let activeIndex = panelOrder.firstIndex(of: activeId) {
            panelOrder.insert(panel.id, at: activeIndex + 1)
        } else {
            panelOrder.append(panel.id)
        }
        activePanelId = panel.id

        return panel
    }

    /// Removes a panel from this workspace and tears down its resources.
    ///
    /// If the removed panel was active, the last remaining panel becomes active.
    func removePanel(_ panelId: UUID) {
        guard let panel = panels[panelId] else { return }
        panel.close()
        panels.removeValue(forKey: panelId)
        panelOrder.removeAll { $0 == panelId }

        if activePanelId == panelId {
            activePanelId = panelOrder.last
        }
    }

    /// Switches the active panel, unfocusing the previous one and focusing
    /// the new one.
    func selectPanel(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }

        // Unfocus the previously active panel.
        if let prevId = activePanelId, let prev = panels[prevId] {
            prev.unfocus()
        }

        activePanelId = panelId

        if let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Reorders a panel tab from one index to another within the tab bar.
    ///
    /// Both indices must be valid; out-of-range indices are ignored.
    func reorderPanel(from source: Int, to destination: Int) {
        guard source >= 0, source < panelOrder.count,
              destination >= 0, destination < panelOrder.count
        else { return }

        let panelId = panelOrder.remove(at: source)
        panelOrder.insert(panelId, at: destination)
    }

    // MARK: - Title Management

    /// Updates the derived title (from shell cwd / process title).
    ///
    /// Empty or whitespace-only values are ignored.
    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    /// Sets or clears the user-assigned custom title.
    func setCustomTitle(_ newTitle: String?) {
        customTitle = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
