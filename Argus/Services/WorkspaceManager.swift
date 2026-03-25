import Foundation
import SwiftUI
import Combine

/// Central state manager for all workspaces in the application.
///
/// WorkspaceManager owns the ordered list of workspaces, tracks the current
/// selection, and provides CRUD operations plus keyboard-shortcut handlers.
/// It is the single source of truth for workspace state and is shared via
/// the SwiftUI environment as an `@EnvironmentObject`.
///
/// Phase 1 manages a flat list of workspaces (no projects). The sidebar
/// index used by Cmd+1–8 shortcuts is therefore a simple array index.
@MainActor
final class WorkspaceManager: ObservableObject {

    // MARK: - Published State

    /// Ordered list of workspaces (determines sidebar order).
    @Published private(set) var workspaces: [Workspace] = []

    /// ID of the currently selected workspace.
    @Published var selectedWorkspaceId: UUID?

    // MARK: - Computed Properties

    /// The currently selected workspace, or `nil` if none is selected.
    var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Index of the currently selected workspace in the sidebar.
    var selectedWorkspaceIndex: Int? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.firstIndex { $0.id == id }
    }

    // MARK: - Constants

    /// Maximum number of workspaces per window (spec: 128).
    static let maxWorkspaces = 128

    // MARK: - Notification Observers

    nonisolated(unsafe) private var closeSurfaceObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        let workspace = Workspace()
        workspaces.append(workspace)
        selectedWorkspaceId = workspace.id

        // Observe surface-close notifications from GhosttyApp callbacks.
        closeSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .argusCloseSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceId = notification.object as? UUID
            else { return }
            self.handleSurfaceClosed(surfaceId)
        }
    }

    deinit {
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Surface Close Handling

    /// Handles a surface-closed notification by removing the corresponding
    /// panel from its workspace.
    private func handleSurfaceClosed(_ surfaceId: UUID) {
        guard let workspace = workspace(containingPanel: surfaceId) else { return }
        workspace.removePanel(surfaceId)

        // An empty workspace is equivalent to a closed workspace.
        if workspace.panelOrder.isEmpty {
            removeWorkspace(workspace.id)
        }
    }

    // MARK: - Workspace CRUD

    /// Creates and appends a new workspace, selecting it immediately.
    ///
    /// - Parameters:
    ///   - title: Display title; defaults to `"Terminal"`.
    ///   - workingDirectory: Initial working directory for the first panel.
    /// - Returns: The new workspace, or `nil` if the limit has been reached.
    @discardableResult
    func addWorkspace(title: String? = nil, workingDirectory: String? = nil) -> Workspace? {
        guard workspaces.count < Self.maxWorkspaces else { return nil }

        let workspace = Workspace(
            title: title ?? "Terminal",
            workingDirectory: workingDirectory
        )
        workspaces.append(workspace)
        selectedWorkspaceId = workspace.id
        return workspace
    }

    /// Removes a workspace by ID, closing all of its panels.
    ///
    /// When the last workspace is removed a new empty workspace is created
    /// automatically (spec: "When the last workspace is closed, the system
    /// MUST create a new empty workspace automatically.").
    func removeWorkspace(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }

        let workspace = workspaces[index]

        // Close all panels in the workspace before removal.
        for panelId in workspace.panelOrder {
            workspace.removePanel(panelId)
        }

        workspaces.remove(at: index)

        // Maintain selection invariant.
        if selectedWorkspaceId == workspaceId {
            if workspaces.isEmpty {
                // Spec: always have at least one workspace.
                let newWorkspace = Workspace()
                workspaces.append(newWorkspace)
                selectedWorkspaceId = newWorkspace.id
            } else {
                // Select the workspace at the same position (clamped).
                let newIndex = min(index, workspaces.count - 1)
                selectedWorkspaceId = workspaces[newIndex].id
            }
        }
    }

    // MARK: - Selection

    /// Selects a workspace by ID, transferring panel focus.
    func selectWorkspace(_ workspaceId: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return }

        // Unfocus the active panel in the outgoing workspace.
        selectedWorkspace?.activePanel?.unfocus()

        selectedWorkspaceId = workspaceId

        // Focus the active panel in the incoming workspace.
        selectedWorkspace?.activePanel?.focus()
    }

    /// Selects a workspace by its zero-based sidebar index.
    func selectWorkspaceByIndex(_ index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        selectWorkspace(workspaces[index].id)
    }

    /// Selects the last workspace in sidebar order (Cmd+9).
    func selectLastWorkspace() {
        guard let last = workspaces.last else { return }
        selectWorkspace(last.id)
    }

    /// Selects the next workspace, wrapping around to the first.
    func selectNextWorkspace() {
        guard let currentId = selectedWorkspaceId,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % workspaces.count
        selectWorkspace(workspaces[nextIndex].id)
    }

    /// Selects the previous workspace, wrapping around to the last.
    func selectPreviousWorkspace() {
        guard let currentId = selectedWorkspaceId,
              let currentIndex = workspaces.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[prevIndex].id)
    }

    // MARK: - Workspace Mutation

    /// Renames a workspace (spec: "The system MUST allow renaming workspaces.").
    func renameWorkspace(_ workspaceId: UUID, title: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.setCustomTitle(title)
    }

    /// Reorders a workspace from one sidebar position to another.
    ///
    /// Both indices must be valid; out-of-range values are silently ignored.
    func reorderWorkspace(from source: Int, to destination: Int) {
        guard source >= 0, source < workspaces.count,
              destination >= 0, destination < workspaces.count,
              source != destination else { return }
        let workspace = workspaces.remove(at: source)
        workspaces.insert(workspace, at: destination)
    }

    // MARK: - Tab Management (within selected workspace)

    /// Adds a new terminal tab to the currently selected workspace.
    ///
    /// - Parameter workingDirectory: Optional initial working directory.
    /// - Returns: The new terminal panel, or `nil` if no workspace is selected.
    @discardableResult
    func addTab(workingDirectory: String? = nil) -> TerminalPanel? {
        guard let workspace = selectedWorkspace else { return nil }
        return workspace.addTerminalPanel(workingDirectory: workingDirectory)
    }

    /// Closes the active tab in the currently selected workspace.
    ///
    /// If the workspace has no remaining panels after removal, the workspace
    /// itself is removed (which may trigger creation of a fresh workspace).
    func closeCurrentTab() {
        guard let workspace = selectedWorkspace,
              let panelId = workspace.activePanelId else { return }

        workspace.removePanel(panelId)

        // An empty workspace is equivalent to a closed workspace.
        if workspace.panelOrder.isEmpty {
            removeWorkspace(workspace.id)
        }
    }

    // MARK: - Keyboard Shortcut Handlers

    /// Handles Cmd+N workspace shortcuts where N is 1–9.
    ///
    /// - Cmd+1 through Cmd+8: select workspace by global sidebar index.
    /// - Cmd+9: select the last workspace.
    func handleWorkspaceShortcut(number: Int) {
        if number == 9 {
            selectLastWorkspace()
        } else {
            selectWorkspaceByIndex(number - 1)
        }
    }

    // MARK: - Lookup

    /// Returns the workspace containing a given panel (surface) ID, if any.
    func workspace(containingPanel panelId: UUID) -> Workspace? {
        workspaces.first { $0.panelOrder.contains(panelId) }
    }

    /// Returns the 1-based sidebar position of a workspace (for TTS, titlebar, etc.).
    func sidebarNumber(for workspaceId: UUID) -> Int? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        return index + 1
    }
}
