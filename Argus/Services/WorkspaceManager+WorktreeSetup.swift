import Foundation

extension WorkspaceManager {
    func checkpointAndStartSetup(in workspace: Workspace, command: String?) {
        guard setupPanel(in: workspace)?.isRunning != true else { return }
        do {
            try saveSession(to: sessionSnapshotURL)
            startWorktreeSetup(command: command, in: workspace)
        } catch {
            // Retain the Workspace, but never execute code before a successful checkpoint.
            if command != nil {
                let panel = workspace.openWorktreeSetupPanel()
                panel.finish(
                    .init(outcome: .failedLaunch("Could not save the Workspace. Save the session before retrying.")),
                    generation: panel.generation)
            }
        }
    }

    func setWorktreeSetupCommand(_ command: String, for projectID: UUID) throws {
        let value = try WorktreeSetupCommand.validated(command)
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw WorktreeSetupConfigurationError.projectUnavailable
        }
        objectWillChange.send()
        let previous = project.worktreeSetupCommand
        project.worktreeSetupCommand = value
        do {
            try saveSession(to: sessionSnapshotURL)
        } catch {
            project.worktreeSetupCommand = previous
            throw error
        }
    }

    func setupPanel(in workspace: Workspace) -> WorktreeSetupPanel? {
        workspace.worktreeSetupPanel
    }

    func canRunWorktreeSetup(in workspace: Workspace) -> Bool {
        guard let owner = setupOwner(for: workspace) else { return false }
        return !worktreeDeletionRoots.contains(owner.rootPath)
            && project(for: workspace.id)?.worktreeSetupCommand != nil
            && setupPanel(in: workspace)?.isRunning != true
            && !closingSetupWorkspaceIDs.contains(workspace.id) && !isStoppingAllWorktreeSetups
            && workspace.projectId.map { !closingSetupProjectIDs.contains($0) } == true
    }

    /// Explicit inspection never runs setup. A later explicit retry uses the current setting.
    func showWorktreeSetup(in workspace: Workspace) {
        guard workspaces.contains(where: { $0 === workspace }),
            setupPanel(in: workspace) != nil || canRunWorktreeSetup(in: workspace)
        else { return }
        selectWorkspace(workspace.id)
        _ = workspace.openWorktreeSetupPanel()
    }

    func runWorktreeSetupAgain(in workspace: Workspace) {
        guard canRunWorktreeSetup(in: workspace),
            let command = project(for: workspace.id)?.worktreeSetupCommand
        else { return }
        checkpointAndStartSetup(in: workspace, command: command)
    }

    /// Called only after successful durable attachment of an actually new worktree, or explicit retry.
    func startWorktreeSetup(command: String?, in workspace: Workspace) {
        guard !isStoppingAllWorktreeSetups, !closingSetupWorkspaceIDs.contains(workspace.id),
            let command, (try? WorktreeSetupCommand.validated(command)) != nil,
            let owner = setupOwner(for: workspace), setupPanel(in: workspace)?.isRunning != true
        else { return }
        guard !closingSetupProjectIDs.contains(owner.projectID), !worktreeDeletionRoots.contains(owner.rootPath) else {
            return
        }
        let panel = workspace.openWorktreeSetupPanel()
        let runner = worktreeSetupRunner
        panel.begin(command: command, owner: owner) { [weak self, weak panel] generation, cancellation in
            guard let self, let panel else { return }
            guard await self.validateSetupOwner(owner), !cancellation.isCancelled,
                panel.generation == generation, self.setupOwner(for: workspace) == owner,
                self.project(for: workspace.id)?.worktreeSetupCommand == command,
                !self.isStoppingAllWorktreeSetups, !self.closingSetupWorkspaceIDs.contains(workspace.id),
                !self.closingSetupProjectIDs.contains(owner.projectID),
                !self.worktreeDeletionRoots.contains(owner.rootPath)
            else {
                panel.finish(
                    .init(
                        outcome: cancellation.isCancelled
                            ? .cancelled
                            : .failedLaunch(
                                "The Project command or registered worktree ownership changed before setup could start."
                            )), generation: generation)
                return
            }
            let result = await runner.run(
                WorktreeSetupRequest(command: command, rootPath: owner.rootPath), cancellation: cancellation
            ) { [weak self, weak panel] update in
                await MainActor.run {
                    guard let self, let panel, self.setupOwner(for: workspace) == owner,
                        self.setupPanel(in: workspace) === panel
                    else { return }
                    panel.publish(update, generation: generation)
                }
            }
            // Finish cleanup bookkeeping, but never publish a result for obsolete ownership.
            let currentOwner = self.setupOwner(for: workspace) == owner && self.setupPanel(in: workspace) === panel
            panel.finish(
                currentOwner
                    ? result : .init(outcome: .ownershipChanged, terminationConfirmed: result.terminationConfirmed),
                generation: generation
            )
        }
    }

    func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    func setupOwner(for workspace: Workspace) -> WorktreeSetupOwner? {
        guard workspaces.contains(where: { $0 === workspace }), workspace.workspaceType == .worktree,
            let project = project(for: workspace.id), workspace.projectId == project.id,
            let path = workspace.worktreePath
        else { return nil }
        let root = canonicalPath(path)
        let repository = canonicalPath(project.repositoryPath)
        guard root != repository, canonicalPath(workspace.currentDirectory) == root else { return nil }
        return WorktreeSetupOwner(
            projectID: project.id, repositoryRoot: repository, workspaceID: workspace.id, rootPath: root
        )
    }

    private func validateSetupOwner(_ owner: WorktreeSetupOwner) async -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == owner.workspaceID }),
            setupOwner(for: workspace) == owner,
            let trees = try? await worktreeService.listWorktrees(repositoryPath: owner.repositoryRoot),
            trees.contains(where: { !$0.isHead && canonicalPath($0.path) == owner.rootPath }),
            let root = try? await worktreeService.canonicalRepositoryRoot(for: owner.rootPath),
            canonicalPath(root) == owner.rootPath
        else { return false }
        return setupOwner(for: workspace) == owner
    }

    var totalRunningSetupCount: Int {
        workspaces.reduce(0) { $0 + $1.runningSetupCount }
    }

    /// MainActor-atomic, all-or-nothing acquisition before any await or stop. Callers
    /// release only their returned roots, so a conflicting close cannot release another gate.
    func acquireWorktreeDeletionRoots(_ paths: [String], closingWorkspaceIDs: Set<UUID>) -> Set<String>? {
        let roots = Set(paths.map(canonicalPath))
        guard worktreeDeletionRoots.isDisjoint(with: roots) else {
            lastWorkspaceDeletionError = .worktreeRemovalFailed(
                "A deletion of this worktree is already in progress. Wait for it to finish before retrying."
            )
            return nil
        }
        for workspace in workspaces where !closingWorkspaceIDs.contains(workspace.id) {
            guard let panel = setupPanel(in: workspace), panel.isRunning || !panel.terminationConfirmed,
                let owner = panel.owner, roots.contains(owner.rootPath)
            else { continue }
            let label = WorkspaceTitleFormatter.title(
                workspaceTitle: workspace.displayTitle, contextName: activeWorkspaceContextName(for: workspace)
            )
            lastWorkspaceDeletionError = .worktreeRemovalFailed(
                "Stop Worktree Setup in \"\(label)\" before deleting this shared worktree. "
                    + "Its setup is still pending, running, or awaiting cleanup."
            )
            return nil
        }
        worktreeDeletionRoots.formUnion(roots)
        return roots
    }

    /// A failed creation owns cleanup only while its new root remains unclaimed.
    /// Reservation and claim checks are MainActor-atomic; never stop a peer as cleanup.
    func cleanupUnattachedWorktree(path: String, repositoryPath: String, reusedExistingWorktree: Bool) async {
        let root = canonicalPath(path)
        guard !reusedExistingWorktree, !worktreeDeletionRoots.contains(root),
            !workspaces.contains(where: { workspace in
                let setup = setupPanel(in: workspace)
                return canonicalPath(workspace.currentDirectory) == root
                    || workspace.worktreePath.map(canonicalPath) == root
                    || (setup?.owner?.rootPath == root
                        && (setup?.isRunning == true || setup?.terminationConfirmed == false))
                    || (workspace.workspaceType == .mainCheckout
                        && project(for: workspace.id).map {
                            canonicalPath($0.repositoryPath) == root
                        } == true)
            }),
            let roots = acquireWorktreeDeletionRoots([root], closingWorkspaceIDs: [])
        else { return }
        defer { worktreeDeletionRoots.subtract(roots) }
        // Unforced removal retains edits; failure leaves the normal orphan recovery path.
        try? await worktreeService.removeWorktree(repositoryPath: repositoryPath, worktreePath: root)
    }

    func canClaimWorkspaceRoot(_ path: String) -> Bool {
        guard !worktreeDeletionRoots.contains(canonicalPath(path)) else {
            lastWorkspaceCreationError = .worktreeCreationFailed(
                "This directory is being deleted. Wait for deletion to finish before opening a Workspace here.")
            return false
        }
        return true
    }

    func automaticFallbackDirectory(excluding roots: Set<String> = []) -> String? {
        let reserved = worktreeDeletionRoots.union(roots)
        let preferred = settings.defaultStandaloneWorkspaceDirectory
        if !reserved.contains(canonicalPath(preferred)) { return preferred }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var isDirectory: ObjCBool = false
        guard !reserved.contains(canonicalPath(home)),
            FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return home
    }

    func canRemoveWorkspaces(_ ids: Set<UUID>, deletingRoots: Set<String> = []) -> Bool {
        guard workspaces.allSatisfy({ ids.contains($0.id) }),
            automaticFallbackDirectory(excluding: deletingRoots) == nil
        else { return true }
        lastWorkspaceDeletionError = .worktreeRemovalFailed(
            "The last Workspace must remain open because its default directory and home directory are unavailable "
                + "for a replacement. Wait for deletion to finish before retrying."
        )
        return false
    }

    /// The caller holds the close gate through deletion/state removal, preventing a new retry.
    func stopWorktreeSetup(in workspace: Workspace) async -> Bool {
        guard let panel = setupPanel(in: workspace) else { return true }
        let stopped = await panel.stop()
        if !stopped {
            lastWorkspaceDeletionError = .worktreeRemovalFailed(
                "Worktree Setup could not be stopped. The Workspace and worktree were retained."
            )
        }
        return stopped
    }

    func stopWorktreeSetupAndCloseTab(_ tabID: UUID, in workspace: Workspace) {
        guard !closingSetupWorkspaceIDs.contains(workspace.id) else { return }
        closingSetupWorkspaceIDs.insert(workspace.id)
        Task {
            let stopped = await stopWorktreeSetup(in: workspace)
            closingSetupWorkspaceIDs.remove(workspace.id)
            if stopped { requestCloseTab(tabID, in: workspace.id, confirmingRunningProcess: true) }
        }
    }

    func stopWorktreeSetups(in workspaceIDs: Set<UUID>) async -> Bool {
        for workspace in workspaces where workspaceIDs.contains(workspace.id) {
            guard await stopWorktreeSetup(in: workspace) else { return false }
        }
        return true
    }

    func stopAllWorktreeSetups() async -> Bool {
        isStoppingAllWorktreeSetups = true
        var stopped = true
        for workspace in workspaces where !(await stopWorktreeSetup(in: workspace)) { stopped = false }
        if !stopped { isStoppingAllWorktreeSetups = false }
        return stopped
    }
}

extension Workspace {
    var runningSetupCount: Int {
        worktreeSetupPanel?.isRunning == true ? 1 : 0
    }
}
