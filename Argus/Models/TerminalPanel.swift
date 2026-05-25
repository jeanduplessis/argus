import Foundation
import Combine
import AppKit

/// Concrete `Panel` implementation wrapping a `TerminalSurface`.
///
/// Each `TerminalPanel` owns a single Ghostty terminal surface. The panel's
/// `id` is the same as the surface's `id` so that socket-API callers can
/// address a panel by its `surface_id`.
@MainActor
final class TerminalPanel: Panel, ObservableObject {

    // MARK: - Panel identity

    let id: UUID
    let panelType: PanelType = .terminal

    // MARK: - Terminal surface

    let surface: TerminalSurface

    /// The workspace this panel currently belongs to. Updated when a panel
    /// is moved between workspaces.
    private(set) var workspaceId: UUID

    // MARK: - Published state (drives tab bar UI)

    @Published private(set) var title: String = "Terminal"
    @Published private(set) var directory: String = ""

    // MARK: - Combine subscriptions

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Panel protocol

    var displayTitle: String { title.isEmpty ? "~" : title }
    var displayIcon: String? { "terminal.fill" }
    var isDirty: Bool { false }

    // MARK: - Initializer

    /// Creates a new terminal panel with its own Ghostty surface.
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace this panel belongs to.
    ///   - workingDirectory: Initial working directory for the shell.
    ///     Defaults to the user's home directory when `nil`.
    ///   - additionalEnvironment: Extra environment variables injected into
    ///     the spawned shell (e.g. `ARGUS_WORKSPACE_ID`).
    init(
        workspaceId: UUID,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:]
    ) {
        let surface = TerminalSurface(
            workspaceId: workspaceId,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment
        )
        self.id = surface.id
        self.workspaceId = workspaceId
        self.surface = surface

        // Derive initial title from the working directory so the tab
        // doesn't flash "Terminal" → "~" when the shell starts.
        let dir = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.title = Self.titleFromPath(dir)
        self.directory = dir

        // Observe surface title changes (shell sets the terminal title).
        surface.$title
            .dropFirst()
            .sink { [weak self] (newTitle: String) in
                let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.title = trimmed
                }
            }
            .store(in: &cancellables)

        // Observe surface working-directory changes.
        surface.$pwd
            .sink { [weak self] newPwd in
                let trimmed = newPwd.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.directory = trimmed
                }
            }
            .store(in: &cancellables)
    }

    /// Derive a short display title from a directory path.
    /// Home directory becomes "~", otherwise uses the last path component.
    private static func titleFromPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home || path == home + "/" {
            return "~"
        }
        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? "~" : lastComponent
    }

    // MARK: - Panel lifecycle

    func focus() {
        surface.setFocus(true)
    }

    func unfocus() {
        surface.setFocus(false)
    }

    func close() {
        surface.teardownSurface()
    }

    // MARK: - Mutations

    /// Re-parent this panel to a different workspace.
    func updateWorkspaceId(_ newId: UUID) {
        workspaceId = newId
    }
}
