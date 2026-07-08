import Foundation
import SwiftUI
import Combine

/// Direction for splitting terminal panes inside a workspace tab.
enum PanelSplitDirection: String, Codable, Sendable {
    /// Side-by-side panes separated by a vertical divider.
    case vertical
    /// Stacked panes separated by a horizontal divider.
    case horizontal
}

/// Tree describing the panes visible inside one workspace tab.
indirect enum PanelLayoutNode: Equatable, Sendable {
    case leaf(UUID)
    case split(direction: PanelSplitDirection, first: PanelLayoutNode, second: PanelLayoutNode)

    var leaves: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, let first, let second):
            return first.leaves + second.leaves
        }
    }

    func contains(_ panelId: UUID) -> Bool {
        leaves.contains(panelId)
    }

    func replacingLeaf(_ panelId: UUID, with replacement: PanelLayoutNode) -> PanelLayoutNode {
        switch self {
        case .leaf(let id):
            return id == panelId ? replacement : self
        case .split(let direction, let first, let second):
            return .split(
                direction: direction,
                first: first.replacingLeaf(panelId, with: replacement),
                second: second.replacingLeaf(panelId, with: replacement)
            )
        }
    }

    func removingLeaf(_ panelId: UUID) -> PanelLayoutNode? {
        switch self {
        case .leaf(let id):
            return id == panelId ? nil : self
        case .split(let direction, let first, let second):
            let newFirst = first.removingLeaf(panelId)
            let newSecond = second.removingLeaf(panelId)
            switch (newFirst, newSecond) {
            case (nil, nil): return nil
            case (let remaining?, nil): return remaining
            case (nil, let remaining?): return remaining
            case (let first?, let second?):
                return .split(direction: direction, first: first, second: second)
            }
        }
    }
}

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

    // MARK: - Project Association (Phase 2)

    /// The project this workspace belongs to. `nil` for standalone workspaces
    /// (adopted by the catch-all project).
    @Published var projectId: UUID?

    /// The git branch this workspace is checked out on.
    @Published var branchName: String?

    /// How this workspace relates to its project's git repository.
    @Published var workspaceType: WorkspaceType = .external

    /// Filesystem path to the worktree, if this workspace uses a project worktree.
    /// `nil` for standalone or main-checkout workspaces.
    @Published var worktreePath: String?

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

    /// The `id` of the currently active (focused) panel, or `nil` if the
    /// workspace has no panels.
    @Published var activePanelId: UUID?

    /// Split-pane layout for each top-level tab, keyed by that tab's root
    /// panel id. Tabs without an entry are single-pane tabs.
    @Published private(set) var tabLayouts: [UUID: PanelLayoutNode] = [:]

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

    /// Number of top-level tabs in this workspace.
    var panelCount: Int { panelOrder.count }

    /// The top-level tab that owns the active focused pane.
    var activeTabId: UUID? {
        guard let activePanelId else { return panelOrder.first }
        if panelOrder.contains(activePanelId) { return activePanelId }
        return panelOrder.first { tabId in
            layout(for: tabId).contains(activePanelId)
        } ?? panelOrder.first
    }

    /// Split layout for the active tab.
    var activeTabLayout: PanelLayoutNode? {
        guard let activeTabId else { return nil }
        return layout(for: activeTabId)
    }

    /// Returns the layout for a top-level tab, falling back to a single leaf.
    func layout(for tabId: UUID) -> PanelLayoutNode {
        tabLayouts[tabId] ?? .leaf(tabId)
    }

    /// Returns the ordinal label shown in the tab bar for a top-level tab.
    func tabDisplayTitle(for panelId: UUID) -> String {
        guard let index = panelOrder.firstIndex(of: panelId) else { return "Tab" }
        return "Tab \(index + 1)"
    }

    // MARK: - Initializer

    /// Creates a new workspace with a single terminal panel.
    ///
    /// - Parameters:
    ///   - title: Initial workspace title. Defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory. Defaults to the
    ///     user's home directory when `nil`.
    init(id: UUID = UUID(), title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = id
        self.title = title
        self.currentDirectory = workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Spec §Workspaces rule 7: new workspaces start with one terminal panel.
        let panel = TerminalPanel(workspaceId: id, workingDirectory: workingDirectory)
        addPanel(panel)
    }

    /// Creates a workspace within a project, associated with a git branch/worktree.
    ///
    /// - Parameters:
    ///   - title: Initial workspace title. Defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory. Defaults to the
    ///     user's home directory when `nil`.
    ///   - projectId: The owning project's identifier.
    ///   - branchName: The git branch this workspace is checked out on.
    ///   - workspaceType: How this workspace relates to its project's repo.
    ///   - worktreePath: Filesystem path to the worktree, if applicable.
    init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String? = nil,
        projectId: UUID,
        branchName: String,
        workspaceType: WorkspaceType,
        worktreePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.currentDirectory = workingDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.projectId = projectId
        self.branchName = branchName
        self.workspaceType = workspaceType
        self.worktreePath = worktreePath

        let panel = TerminalPanel(workspaceId: id, workingDirectory: workingDirectory)
        addPanel(panel)
    }

    /// Restores a workspace from a persisted Phase 2 snapshot.
    init(snapshot: WorkspaceSnapshot) {
        self.id = snapshot.id
        self.title = snapshot.title
        self.customTitle = snapshot.customTitle
        self.currentDirectory = snapshot.currentDirectory
        self.projectId = snapshot.projectId
        self.branchName = snapshot.branchName
        self.workspaceType = snapshot.workspaceType
        self.worktreePath = snapshot.worktreePath

        let terminalDirectories = snapshot.restoredTerminalDirectories
        let firstPanel = TerminalPanel(workspaceId: id, workingDirectory: terminalDirectories[0])
        addPanel(firstPanel)
        for directory in terminalDirectories.dropFirst() {
            addTerminalPanel(workingDirectory: directory)
        }
    }

    /// Creates a minimal durable snapshot for Phase 2 persistence.
    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            projectId: projectId,
            branchName: branchName,
            workspaceType: workspaceType,
            worktreePath: worktreePath,
            title: title,
            customTitle: customTitle,
            currentDirectory: currentDirectory,
            panelCount: max(panelOrder.count, 1),
            terminalDirectories: terminalDirectoriesForSnapshot()
        )
    }

    private func terminalDirectoriesForSnapshot() -> [String] {
        let directories = panelOrder.compactMap { panelId -> String? in
            guard let terminal = panels[panelId] as? TerminalPanel else { return nil }
            let directory = terminal.directory.trimmingCharacters(in: .whitespacesAndNewlines)
            return directory.isEmpty ? currentDirectory : directory
        }
        return directories.isEmpty ? [currentDirectory] : directories
    }

    // MARK: - Panel Management

    /// Adds a panel to this workspace at the end of the tab order.
    ///
    /// If no panel is currently active, the new panel becomes active.
    func addPanel(_ panel: any Panel) {
        panels[panel.id] = panel
        panelOrder.append(panel.id)
        tabLayouts[panel.id] = .leaf(panel.id)
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
        if let tabId = activeTabId,
           let activeIndex = panelOrder.firstIndex(of: tabId) {
            panelOrder.insert(panel.id, at: activeIndex + 1)
        } else {
            panelOrder.append(panel.id)
        }
        tabLayouts[panel.id] = .leaf(panel.id)
        selectPanel(panel.id)

        return panel
    }

    /// Splits the focused terminal pane inside the active tab. The new pane
    /// starts in the focused pane's working directory and becomes focused.
    ///
    /// Splits are pane-local: they do not create another top-level tab.
    @discardableResult
    func splitActiveTerminal(direction: PanelSplitDirection) -> TerminalPanel? {
        guard let activePanelId,
              let activeTerminal = panels[activePanelId] as? TerminalPanel,
              let tabId = activeTabId
        else { return nil }

        let panel = TerminalPanel(
            workspaceId: id,
            workingDirectory: activeTerminal.directory.isEmpty ? currentDirectory : activeTerminal.directory
        )
        panels[panel.id] = panel

        let split = PanelLayoutNode.split(
            direction: direction,
            first: .leaf(activePanelId),
            second: .leaf(panel.id)
        )
        tabLayouts[tabId] = layout(for: tabId).replacingLeaf(activePanelId, with: split)
        selectPanel(panel.id)

        return panel
    }

    /// Removes a panel from this workspace and tears down its resources.
    ///
    /// Removing a top-level tab closes all split panes inside that tab. Removing
    /// a split leaf closes only that pane and collapses the remaining layout.
    func removePanel(_ panelId: UUID) {
        guard panels[panelId] != nil else { return }
        if panelOrder.contains(panelId) {
            removeTab(panelId)
        } else {
            removeSplitLeaf(panelId)
        }
    }

    /// Closes the focused pane. If it is the only pane in the tab, this closes
    /// the top-level tab.
    func closeActivePaneOrTab() {
        guard let activePanelId else { return }
        if let activeTabId,
           layout(for: activeTabId).leaves.count > 1 {
            removeSplitLeaf(activePanelId)
        } else {
            removePanel(activeTabId ?? activePanelId)
        }
    }

    /// Switches the active panel, unfocusing the previous one and focusing
    /// the new one.
    func selectPanel(_ panelId: UUID) {
        let focusPanelId: UUID
        if panelOrder.contains(panelId) {
            focusPanelId = layout(for: panelId).leaves.first ?? panelId
        } else {
            focusPanelId = panelId
        }
        guard panels[focusPanelId] != nil else { return }

        if activePanelId == focusPanelId {
            panels[focusPanelId]?.focus()
            return
        }

        // Unfocus the previously active panel.
        if let prevId = activePanelId, let prev = panels[prevId] {
            prev.unfocus()
        }

        activePanelId = focusPanelId

        if let panel = panels[focusPanelId] {
            panel.focus()
        }
    }

    /// Reorders a panel tab from one index to another within the tab bar.
    ///
    /// Both indices must be valid; out-of-range indices are ignored.
    func reorderPanel(from source: Int, to destination: Int) {
        guard source >= 0, source < panelOrder.count,
              destination >= 0, destination <= panelOrder.count,
              source != destination
        else { return }

        let panelId = panelOrder.remove(at: source)
        let insertionIndex = min(destination, panelOrder.count)
        panelOrder.insert(panelId, at: insertionIndex)
    }

    private func removeTab(_ tabId: UUID) {
        let removedIndex = panelOrder.firstIndex(of: tabId)
        let leafIds = layout(for: tabId).leaves
        for leafId in leafIds {
            panels[leafId]?.close()
            panels.removeValue(forKey: leafId)
        }
        panelOrder.removeAll { $0 == tabId }
        tabLayouts.removeValue(forKey: tabId)

        if let activePanelId, leafIds.contains(activePanelId) {
            let nextIndex = min(removedIndex ?? panelOrder.count - 1, panelOrder.count - 1)
            if panelOrder.indices.contains(nextIndex) {
                selectPanel(panelOrder[nextIndex])
            } else {
                self.activePanelId = nil
            }
        }
    }

    private func removeSplitLeaf(_ panelId: UUID) {
        guard let tabId = panelOrder.first(where: { layout(for: $0).contains(panelId) }) else { return }
        panels[panelId]?.close()
        panels.removeValue(forKey: panelId)
        tabLayouts[tabId] = layout(for: tabId).removingLeaf(panelId)
        if tabLayouts[tabId] == nil {
            panelOrder.removeAll { $0 == tabId }
        }

        if activePanelId == panelId {
            if let nextId = layout(for: tabId).leaves.first, panels[nextId] != nil {
                selectPanel(nextId)
            } else {
                activePanelId = panelOrder.last
            }
        }
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
