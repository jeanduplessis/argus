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
/// Phase 2 adds project management: workspaces are grouped under projects,
/// each backed by a git repository with worktree support. The sidebar index
/// used by Cmd+1–8 shortcuts reflects project-grouped ordering.
@MainActor
final class WorkspaceManager: ObservableObject {

    // MARK: - Published State

    /// Ordered list of workspaces (determines sidebar order).
    @Published private(set) var workspaces: [Workspace] = []

    /// ID of the currently selected workspace.
    @Published var selectedWorkspaceId: UUID? {
        didSet { notifyWorkspaceContextChanged() }
    }

    /// Ordered list of projects (named projects first, catch-all last).
    @Published private(set) var projects: [Project] = []

    /// The non-removable catch-all project for standalone workspaces.
    private(set) var catchAllProject: Project!

    /// Shared worktree service for git operations.
    let worktreeService = WorktreeService()

    /// Last workspace creation error for user-visible sheet feedback.
    private(set) var lastWorkspaceCreationError: WorktreeError?

    /// Location of the minimal Phase 2 session snapshot.
    private let sessionSnapshotURL: URL

    // MARK: - Computed Properties

    /// The currently selected workspace, or `nil` if none is selected.
    var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Formatted title for the active workspace context.
    var activeWorkspaceTitle: String {
        guard let workspace = selectedWorkspace else {
            return WorkspaceTitleFormatter.fallbackTitle
        }
        return WorkspaceTitleFormatter.title(
            workspaceTitle: workspace.displayTitle,
            contextName: activeWorkspaceContextName(for: workspace)
        )
    }

    /// Context component for the active workspace title: named project when
    /// available, otherwise the workspace directory basename.
    func activeWorkspaceContextName(for workspace: Workspace) -> String {
        let project = project(for: workspace.id)
        let projectName = project?.isCatchAll == false ? project?.displayName : nil
        return WorkspaceTitleFormatter.contextName(
            projectName: projectName,
            directoryPath: workspace.currentDirectory
        )
    }

    /// Index of the currently selected workspace in the sidebar.
    var selectedWorkspaceIndex: Int? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.firstIndex { $0.id == id }
    }

    // MARK: - Constants

    /// Maximum number of workspaces per window (spec: 128).
    static let maxWorkspaces = 128

    /// Default application support path for persisted session state.
    static let defaultSessionSnapshotURL: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Argus/session.json")

    // MARK: - Notification Observers

    nonisolated(unsafe) private var closeSurfaceObserver: NSObjectProtocol?
    nonisolated(unsafe) private var focusSurfaceObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(sessionSnapshotURL: URL = WorkspaceManager.defaultSessionSnapshotURL) {
        self.sessionSnapshotURL = sessionSnapshotURL

        if !Self.isRunningUnderAutomatedTests,
           restoreSessionIfAvailable(from: sessionSnapshotURL) {
            // Restored from disk.
        } else {
            createFreshSession()
        }

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

        // Track the focused split pane so split commands target the pane the
        // user last clicked or typed in.
        focusSurfaceObserver = NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeFirstResponder,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceId = notification.object as? UUID
            else { return }
            self.focusPanel(surfaceId)
        }
    }

    deinit {
        if let observer = closeSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = focusSurfaceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Session Persistence

    /// Returns true when app session restore must be skipped for tests.
    private static var isRunningUnderAutomatedTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["ARGUS_DISABLE_SESSION_RESTORE"] == "1"
            || environment["ARGUS_UNDER_TEST"] == "1"
    }

    /// Creates a new default session with one catch-all workspace.
    private func createFreshSession() {
        let catchAll = Project.catchAll()
        self.catchAllProject = catchAll
        self.projects = [catchAll]

        let workspace = Workspace()
        workspaces = [workspace]
        catchAll.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
    }

    /// Builds the minimal durable Phase 2 session snapshot.
    func makeSessionSnapshot() -> ArgusSessionSnapshot {
        ArgusSessionSnapshot(
            selectedWorkspaceId: selectedWorkspaceId,
            projects: projects.map { $0.snapshot() },
            workspaces: workspaces.map { $0.snapshot() }
        )
    }

    /// Writes the current minimal session snapshot to disk.
    func saveSession(to url: URL? = nil) throws {
        let targetURL = url ?? sessionSnapshotURL
        let snapshot = makeSessionSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: targetURL, options: [.atomic])
    }

    /// Best-effort save used by app lifecycle hooks.
    func saveSession() {
        do {
            try saveSession(to: sessionSnapshotURL)
        } catch {
            print("Failed to save Argus session: \(error.localizedDescription)")
        }
    }

    /// Restores a minimal Phase 2 session snapshot from disk if it is valid.
    @discardableResult
    private func restoreSessionIfAvailable(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        else { return false }
        return restoreSession(from: snapshot)
    }

    /// Restores a decoded session snapshot. Incompatible or empty snapshots are
    /// discarded by returning `false` so callers can create a fresh session.
    @discardableResult
    func restoreSession(from snapshot: ArgusSessionSnapshot) -> Bool {
        guard snapshot.isCompatible,
              !snapshot.workspaces.isEmpty,
              snapshot.workspaces.count <= Self.maxWorkspaces
        else { return false }

        let reconciledSnapshot = snapshot.reconciledForRestore()
        let restoredProjects = reconciledSnapshot.projects.map(Project.init(snapshot:))
        let catchAll = restoredProjects.first(where: { $0.isCatchAll }) ?? Project.catchAll()
        let restoredWorkspaces = reconciledSnapshot.workspaces.map(Workspace.init(snapshot:))

        self.catchAllProject = catchAll
        self.projects = restoredProjects
        self.workspaces = restoredWorkspaces
        self.selectedWorkspaceId = reconciledSnapshot.selectedWorkspaceId
        notifyWorkspaceContextChanged()
        return true
    }

    // MARK: - Surface Close Handling

    /// Handles a surface-closed notification by removing the corresponding
    /// panel from its workspace.
    private func handleSurfaceClosed(_ surfaceId: UUID) {
        guard let workspace = workspace(containingPanel: surfaceId) else { return }
        workspace.closePane(surfaceId)

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
        catchAllProject.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        return workspace
    }

    /// Removes a workspace by ID, closing all of its panels.
    ///
    /// When the last workspace is removed a new empty workspace is created
    /// automatically (spec: "When the last workspace is closed, the system
    /// MUST create a new empty workspace automatically.").
    func removeWorkspace(_ workspaceId: UUID) {
        removeWorkspaceFromState(workspaceId)
    }

    /// Removes a workspace, optionally deleting its associated git worktree first.
    @discardableResult
    func removeWorkspace(_ workspaceId: UUID, deletingWorktree: Bool) async -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return false }

        if deletingWorktree,
           let worktreePath = workspace.worktreePath,
           let project = project(for: workspaceId),
           !project.isCatchAll {
            do {
                try await worktreeService.removeWorktree(
                    repositoryPath: project.repositoryPath,
                    worktreePath: worktreePath,
                    force: true
                )
            } catch {
                print("Failed to remove worktree before closing workspace: \(error.localizedDescription)")
                return false
            }
        }

        removeWorkspaceFromState(workspaceId)
        return true
    }

    func shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
              workspace.worktreePath != nil,
              let project = project(for: workspaceId),
              !project.isCatchAll
        else { return false }
        return true
    }

    private func removeWorkspaceFromState(_ workspaceId: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }

        let workspace = workspaces[index]

        // Close all panels in the workspace before removal.
        for panelId in workspace.panelOrder {
            workspace.closeTab(panelId)
        }

        // Remove from parent project.
        if let project = project(for: workspaceId) {
            project.removeWorkspace(workspaceId)
        }

        workspaces.remove(at: index)

        // Maintain selection invariant.
        if selectedWorkspaceId == workspaceId {
            if workspaces.isEmpty {
                // Spec: always have at least one workspace.
                let newWorkspace = Workspace()
                workspaces.append(newWorkspace)
                catchAllProject.addWorkspace(newWorkspace.id)
                selectedWorkspaceId = newWorkspace.id
            } else {
                // Select the workspace at the same position (clamped).
                let newIndex = min(index, workspaces.count - 1)
                selectedWorkspaceId = workspaces[newIndex].id
            }
        }
    }

    // MARK: - Project CRUD

    /// Creates a new project from a git repository path.
    ///
    /// Validates that the path is a git repository and that no existing
    /// project uses the same repository path.
    ///
    /// - Parameters:
    ///   - repositoryPath: Absolute path to the git repo root.
    ///   - displayName: Optional custom name. Defaults to repo basename.
    /// - Returns: The new project, or `nil` if validation fails.
    func createProject(
        repositoryPath: String,
        displayName: String? = nil,
        mainBranchOverride: String? = nil
    ) async -> Project? {
        // Validate and normalize to the canonical git repo root.
        guard let repositoryRoot = try? await worktreeService.canonicalRepositoryRoot(for: repositoryPath) else {
            return nil
        }

        // Check for duplicate.
        guard !hasDuplicateProject(repositoryRoot: repositoryRoot) else { return nil }

        // Detect main branch when possible, but accept an explicit user override.
        let detectedMainBranch = try? await worktreeService.detectMainBranch(
            repositoryPath: repositoryRoot
        )
        let normalizedMainBranch = mainBranchOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? "") : normalizedMainBranch
        guard !mainBranch.isEmpty else { return nil }

        let checkoutBranch = (try? await worktreeService.currentBranchName(repositoryPath: repositoryRoot))
            ?? mainBranch

        let project = Project(
            repositoryPath: repositoryRoot,
            displayName: displayName,
            mainBranch: mainBranch
        )

        // Insert before catch-all (catch-all is always last).
        let insertIndex = projects.count - 1
        projects.insert(project, at: max(insertIndex, 0))

        // Create the main-checkout workspace for this project.
        let workspace = Workspace(
            title: checkoutBranch,
            workingDirectory: repositoryRoot,
            projectId: project.id,
            branchName: checkoutBranch,
            workspaceType: .mainCheckout
        )
        workspaces.append(workspace)
        project.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id

        return project
    }

    /// Removes a project and all its child workspaces.
    ///
    /// Worktrees are cleaned up via `WorktreeService`. The catch-all project
    /// cannot be removed.
    func removeProject(_ projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }),
              !project.isCatchAll else { return }

        // Remove all child workspaces and their worktrees.
        for workspaceId in project.workspaceIds {
            if let workspace = workspaces.first(where: { $0.id == workspaceId }) {
                // Clean up worktree if applicable.
                if let worktreePath = workspace.worktreePath {
                    try? await worktreeService.removeWorktree(
                        repositoryPath: project.repositoryPath,
                        worktreePath: worktreePath,
                        force: true
                    )
                }
                // Close all panels.
                for panelId in workspace.panelOrder {
                    workspace.closeTab(panelId)
                }
            }
        }

        // Remove workspaces from the flat list.
        let idsToRemove = Set(project.workspaceIds)
        workspaces.removeAll { idsToRemove.contains($0.id) }

        // Remove the project.
        projects.removeAll { $0.id == projectId }

        // Fix selection.
        if let selectedId = selectedWorkspaceId,
           idsToRemove.contains(selectedId) {
            if workspaces.isEmpty {
                // Spec: always have at least one workspace.
                let newWorkspace = Workspace()
                workspaces.append(newWorkspace)
                catchAllProject.addWorkspace(newWorkspace.id)
                selectedWorkspaceId = newWorkspace.id
            } else {
                selectedWorkspaceId = workspaces.first?.id
            }
        }
    }

    /// Renames a project.
    func renameProject(_ projectId: UUID, name: String) {
        guard let project = projects.first(where: { $0.id == projectId }),
              !project.isCatchAll else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            project.displayName = trimmed
            notifyWorkspaceContextChanged()
        }
    }

    /// Returns the project that owns a workspace, falling back to the catch-all.
    func project(for workspaceId: UUID) -> Project? {
        projects.first { $0.containsWorkspace(workspaceId) }
    }

    /// Returns all named (non-catch-all) projects.
    var namedProjects: [Project] {
        projects.filter { !$0.isCatchAll }
    }

    /// Adopts an orphaned worktree already present on disk without invoking
    /// `git worktree add` or creating a duplicate directory.
    @discardableResult
    func adoptOrphanedWorktree(_ orphan: OrphanedWorktreeInfo) -> Workspace? {
        guard workspaces.count < Self.maxWorkspaces else { return nil }
        guard let project = projects.first(where: { $0.id == orphan.projectId }),
              !project.isCatchAll else { return nil }

        let branchName = orphan.branchName ?? (orphan.path as NSString).lastPathComponent
        let workspace = Workspace(
            title: branchName,
            workingDirectory: orphan.path,
            projectId: orphan.projectId,
            branchName: branchName,
            workspaceType: .worktree,
            worktreePath: orphan.path
        )
        workspaces.append(workspace)
        project.addWorkspace(workspace.id)
        selectedWorkspaceId = workspace.id
        return workspace
    }

    func hasDuplicateProject(repositoryRoot: String) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: repositoryRoot)
            .resolvingSymlinksInPath()
            .path
        return projects.contains {
            !$0.isCatchAll
                && URL(fileURLWithPath: $0.repositoryPath).resolvingSymlinksInPath().path == canonicalRoot
        }
    }

    /// Creates a new workspace within a project, optionally with a new git worktree.
    ///
    /// - Parameters:
    ///   - projectId: The project to add the workspace to.
    ///   - branchName: The git branch name.
    ///   - createNewBranch: If `true`, creates a new branch; otherwise checks out existing.
    /// - Returns: The new workspace, or `nil` on failure.
    func addWorkspaceToProject(
        _ projectId: UUID,
        branchName: String,
        createNewBranch: Bool = true
    ) async -> Workspace? {
        lastWorkspaceCreationError = nil
        guard workspaces.count < Self.maxWorkspaces else { return nil }
        guard let project = projects.first(where: { $0.id == projectId }),
              !project.isCatchAll else { return nil }

        do {
            if createNewBranch {
                try await worktreeService.ensureBranchNameAvailable(branchName, repositoryPath: project.repositoryPath)
            }
            let worktreePath = try await worktreeService.createWorktree(
                projectId: projectId,
                repositoryPath: project.repositoryPath,
                branchName: branchName,
                createNewBranch: createNewBranch
            )

            let workspace = Workspace(
                title: branchName,
                workingDirectory: worktreePath,
                projectId: projectId,
                branchName: branchName,
                workspaceType: .worktree,
                worktreePath: worktreePath
            )
            workspaces.append(workspace)
            project.addWorkspace(workspace.id)
            selectedWorkspaceId = workspace.id
            return workspace
        } catch let error as WorktreeError {
            lastWorkspaceCreationError = error
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        } catch {
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
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
        let ordered = sidebarOrderedWorkspaces
        guard index >= 0, index < ordered.count else { return }
        selectWorkspace(ordered[index].workspace.id)
    }

    /// Selects the last workspace in sidebar order (Cmd+9).
    func selectLastWorkspace() {
        let ordered = sidebarOrderedWorkspaces
        guard let last = ordered.last else { return }
        selectWorkspace(last.workspace.id)
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
        if selectedWorkspaceId == workspaceId {
            notifyWorkspaceContextChanged()
        }
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

    /// Reorders a workspace within a project section, keeping project order as
    /// the source of truth for sidebar display and Cmd+number shortcuts.
    func reorderWorkspace(in projectId: UUID, moving workspaceId: UUID, before targetWorkspaceId: UUID) {
        guard let project = projects.first(where: { $0.id == projectId }),
              let source = project.workspaceIds.firstIndex(of: workspaceId),
              let target = project.workspaceIds.firstIndex(of: targetWorkspaceId),
              source != target
        else { return }

        let destination = source < target ? max(target - 1, 0) : target
        project.moveWorkspace(from: source, to: destination)
        syncFlatWorkspaceOrderToSidebarOrder()
    }

    private func syncFlatWorkspaceOrderToSidebarOrder() {
        let orderedIds = sidebarOrderedWorkspaces.map(\.workspace.id)
        let indexById = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) })
        workspaces.sort { lhs, rhs in
            (indexById[lhs.id] ?? Int.max) < (indexById[rhs.id] ?? Int.max)
        }
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

    /// Adds a Browser Panel as a top-level tab in the Selected Workspace.
    @discardableResult
    func addBrowserTab(url: URL? = nil) -> BrowserPanel? {
        selectedWorkspace?.addBrowserPanel(url: url)
    }

    func requestFindInActiveBrowser() {
        (selectedWorkspace?.activePanel as? BrowserPanel)?.requestFind()
    }

    /// Splits the active terminal pane in the selected workspace.
    @discardableResult
    func splitActiveTerminal(direction: PanelSplitDirection) -> TerminalPanel? {
        selectedWorkspace?.splitActiveTerminal(direction: direction)
    }

    /// Closes the active pane in the currently selected workspace.
    ///
    /// If the active tab has no remaining panes after removal, the tab closes.
    /// If the workspace has no remaining tabs, the workspace itself is removed.
    func closeCurrentTab() {
        guard let workspace = selectedWorkspace else { return }

        let closesLastWorkspaceTab = workspace.panelOrder.count == 1
            && (workspace.activeTabLayout?.leaves.count ?? 1) == 1
        if closesLastWorkspaceTab,
           shouldConfirmWorktreeDeletionBeforeClosing(workspace.id) {
            NotificationCenter.default.post(
                name: .showCloseWorkspaceConfirmation,
                object: nil,
                userInfo: ["workspaceId": workspace.id]
            )
            return
        }

        workspace.closeActivePaneOrTab()

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
        workspaces.first { $0.panels[panelId] != nil }
    }

    /// Marks a terminal surface as the focused panel when its NSView becomes
    /// first responder.
    func focusPanel(_ panelId: UUID) {
        guard let workspace = workspace(containingPanel: panelId) else { return }
        if selectedWorkspaceId != workspace.id {
            selectedWorkspaceId = workspace.id
        }
        workspace.selectPanel(panelId)
    }

    /// Returns the 1-based sidebar position of a workspace (for TTS, titlebar, etc.).
    func sidebarNumber(for workspaceId: UUID) -> Int? {
        globalSidebarIndex(for: workspaceId)
    }

    // MARK: - Sidebar Ordering

    /// Returns workspaces in sidebar display order: project workspaces first
    /// (in project order, then workspace order within each project),
    /// then catch-all workspaces.
    var sidebarOrderedWorkspaces: [(project: Project, workspace: Workspace)] {
        var result: [(Project, Workspace)] = []
        for project in projects {
            for wsId in project.workspaceIds {
                if let workspace = workspaces.first(where: { $0.id == wsId }) {
                    result.append((project, workspace))
                }
            }
        }
        return result
    }

    /// Returns the global 1-based sidebar index for a workspace.
    /// This replaces the simple array-index approach from Phase 1
    /// since workspaces are now grouped under projects.
    func globalSidebarIndex(for workspaceId: UUID) -> Int? {
        let ordered = sidebarOrderedWorkspaces
        guard let idx = ordered.firstIndex(where: { $0.workspace.id == workspaceId }) else {
            return nil
        }
        return idx + 1
    }

    private func notifyWorkspaceContextChanged() {
        NotificationCenter.default.post(name: .workspaceContextDidChange, object: nil)
    }
}
