import Foundation

extension WorkspaceManager {
    func createProject(
        repositoryPath: String,
        displayName: String? = nil,
        mainBranchOverride: String? = nil,
        collectionId: UUID? = nil
    ) async -> Project? {
        guard collectionId == nil || collections.contains(where: { $0.id == collectionId }),
            workspaces.count < Self.maxWorkspaces,
            namedProjects.count < Self.maxWorkspaces,
            let repositoryRoot = try? await worktreeService.canonicalRepositoryRoot(for: repositoryPath),
            !hasDuplicateProject(repositoryRoot: repositoryRoot)
        else { return nil }

        let detectedMainBranch = try? await worktreeService.detectMainBranch(
            repositoryPath: repositoryRoot
        )
        let normalizedMainBranch =
            mainBranchOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? "") : normalizedMainBranch
        guard !mainBranch.isEmpty else { return nil }
        let checkoutBranch =
            (try? await worktreeService.currentBranchName(repositoryPath: repositoryRoot))
            ?? mainBranch
        let collectionIndex = collectionId.flatMap { id in collections.firstIndex { $0.id == id } }
        guard collectionId == nil || collectionIndex != nil,
            workspaces.count < Self.maxWorkspaces,
            namedProjects.count < Self.maxWorkspaces,
            !hasDuplicateProject(repositoryRoot: repositoryRoot), canClaimWorkspaceRoot(repositoryRoot)
        else { return nil }
        let project = Project(
            repositoryPath: repositoryRoot,
            displayName: displayName,
            mainBranch: mainBranch
        )
        projects.append(project)
        let workspace = Workspace(
            title: checkoutBranch,
            workingDirectory: repositoryRoot,
            projectId: project.id,
            branchName: checkoutBranch,
            workspaceType: .mainCheckout
        )
        workspaces.append(workspace)
        appendPlacement(workspace.id, to: collectionId)
        selectWorkspace(workspace.id)
        saveSession()
        return project
    }

    func removeProject(_ projectId: UUID) async {
        guard let project = projects.first(where: { $0.id == projectId }),
            !closingSetupProjectIDs.contains(projectId)
        else { return }
        lastWorkspaceDeletionError = nil
        closingSetupProjectIDs.insert(projectId)
        defer { closingSetupProjectIDs.remove(projectId) }
        let closingIDs = Set(workspaceIds(for: project))
        guard closingSetupWorkspaceIDs.isDisjoint(with: closingIDs) else { return }
        let removalTargets = workspaceIds(for: project).compactMap { workspaceID in
            workspaces.first { $0.id == workspaceID }.map { ($0, $0.worktreePath.map(canonicalPath)) }
        }
        guard canRemoveWorkspaces(closingIDs, deletingRoots: Set(removalTargets.compactMap { $0.1 })),
            let deletionRoots = acquireWorktreeDeletionRoots(
                removalTargets.compactMap { $0.1 }, closingWorkspaceIDs: closingIDs
            )
        else { return }
        defer { worktreeDeletionRoots.subtract(deletionRoots) }
        closingSetupWorkspaceIDs.formUnion(closingIDs)
        defer { closingSetupWorkspaceIDs.subtract(closingIDs) }
        guard await stopWorktreeSetups(in: closingIDs), canRemoveWorkspaces(closingIDs) else { return }
        cancelPendingWorkspaceStackReveal(in: projectId)
        for worktreePath in deletionRoots.sorted() {
            do {
                try await worktreeService.removeWorktree(
                    repositoryPath: project.repositoryPath, worktreePath: worktreePath, force: true)
            } catch {
                lastWorkspaceDeletionError = .worktreeRemovalFailed(error.localizedDescription)
                return
            }
        }
        guard canRemoveWorkspaces(closingIDs) else { return }
        for (workspace, _) in removalTargets {
            agentStatusRuntime?.removeStatuses(forWorkspace: workspace.id)
            turnCompletionRuntime?.removeAttention(forWorkspace: workspace.id)
            for panelId in workspace.panelOrder {
                workspace.closeTab(panelId)
            }
            workspace.worktreeSetupPanel = nil
        }
        let previousOrder = sidebarOrderedWorkspaces.map(\.workspace.id)
        workspaces.removeAll { closingIDs.contains($0.id) }
        projects.removeAll { $0.id == projectId }
        for workspaceId in closingIDs { removePlacement(workspaceId) }
        restoreSelectionAfterRemovingWorkspaces(closingIDs, previousOrder: previousOrder)
    }

    @discardableResult
    func removeEmptyProject(_ projectId: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectId }), workspaceIds(for: project).isEmpty,
            !closingSetupProjectIDs.contains(projectId)
        else { return false }
        projects.removeAll { $0.id == projectId }
        ungroupedRepositoryDisclosure.removeAll { $0.projectId == projectId }
        for index in collections.indices {
            collections[index].repositoryDisclosure.removeAll { $0.projectId == projectId }
        }
        saveSession()
        return true
    }

    func renameProject(_ projectId: UUID, name: String) {
        guard let project = projects.first(where: { $0.id == projectId })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            project.displayName = trimmed
            notifyWorkspaceContextChanged()
        }
    }

    func project(for workspaceId: UUID) -> Project? {
        guard let projectId = workspaces.first(where: { $0.id == workspaceId })?.projectId else { return nil }
        return projects.first { $0.id == projectId }
    }

    var namedProjects: [Project] {
        projects
    }

    @discardableResult
    func adoptOrphanedWorktree(_ orphan: OrphanedWorktreeInfo, collectionId: UUID? = nil) -> Workspace? {
        guard validateCreationDestination(collectionId), workspaces.count < Self.maxWorkspaces,
            let project = projects.first(where: { $0.id == orphan.projectId }),
            !closingSetupProjectIDs.contains(project.id), !isStoppingAllWorktreeSetups,
            canClaimWorkspaceRoot(orphan.path)
        else { return nil }
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
        appendPlacement(workspace.id, to: collectionId)
        selectWorkspace(workspace.id)
        saveSession()
        return workspace
    }

    func hasDuplicateProject(repositoryRoot: String) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: repositoryRoot)
            .resolvingSymlinksInPath()
            .path
        return projects.contains {
            URL(fileURLWithPath: $0.repositoryPath).resolvingSymlinksInPath().path == canonicalRoot
        }
    }

    /// `startPoint` leaves parent recording to the caller. CLI creation does not select.
    func addWorkspaceToProject(
        _ projectId: UUID,
        branchName: String,
        createNewBranch: Bool = true,
        customTitle: String? = nil,
        parentBranch: String? = nil,
        collectionId: UUID? = nil,
        startPoint: String? = nil,
        selectsNewWorkspace: Bool = true,
        beforeAutomaticSetup: (@MainActor (Workspace) async -> Void)? = nil
    ) async -> Workspace? {
        lastWorkspaceCreationError = nil
        guard validateCreationDestination(collectionId), workspaces.count < Self.maxWorkspaces,
            let project = projects.first(where: { $0.id == projectId })
        else { return nil }

        let repositoryPath = project.repositoryPath
        let setupCommand = project.worktreeSetupCommand
        do {
            if createNewBranch {
                try await worktreeService.ensureBranchNameAvailable(branchName, repositoryPath: repositoryPath)
            }
            let prepared = try await worktreeService.prepareWorktree(
                projectId: projectId,
                repositoryPath: project.repositoryPath,
                branchName: branchName,
                createNewBranch: createNewBranch,
                parentBranch: parentBranch,
                startPoint: startPoint
            )
            return await attachPreparedWorktree(
                PreparedWorktreeAttachment(
                    path: prepared.path,
                    branchName: branchName,
                    customTitle: customTitle,
                    projectId: projectId,
                    repositoryPath: repositoryPath,
                    reusedExistingWorktree: prepared.reusedExistingWorktree,
                    setupCommand: setupCommand,
                    collectionId: collectionId,
                    selectsNewWorkspace: selectsNewWorkspace,
                    beforeAutomaticSetup: beforeAutomaticSetup
                ))
        } catch let error as WorktreeError {
            lastWorkspaceCreationError = error
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        } catch {
            print("Failed to create worktree workspace: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves one Pull Request through the active GitHub CLI and attaches
    /// its exact head to a Worktree Workspace in the initiating Project.
    /// Provider and Git work happen while this MainActor remains suspended;
    /// Project identity and the Project Repository Root are revalidated before
    /// durable Workspace state is changed.
    @discardableResult
    func createWorkspace(
        fromPullRequest input: String,
        in projectId: UUID,
        collectionId: UUID? = nil
    ) async throws -> Workspace {
        lastPullRequestWorkspaceError = nil
        do {
            guard validateCreationDestination(collectionId) else {
                throw PullRequestWorkspaceError.worktreeCreationFailed(lastWorkspaceCreationError!.localizedDescription)
            }
            let parsedInput = try PullRequestInput.parse(input)
            let context = try pullRequestProjectContext(for: projectId)
            let setupCommand = projects.first(where: { $0.id == projectId })?.worktreeSetupCommand
            let metadata = try await pullRequestService.resolve(
                parsedInput,
                repositoryPath: context.repositoryRoot
            )
            let resolution = try await worktreeService.createPullRequestWorktree(
                projectId: context.projectID,
                repositoryPath: context.repositoryRoot,
                metadata: metadata
            )
            return try await attachPullRequestWorkspace(
                resolution,
                metadata: metadata,
                context: context,
                setupCommand: setupCommand,
                collectionId: collectionId
            )
        } catch let error as PullRequestWorkspaceError {
            lastPullRequestWorkspaceError = error
            throw error
        } catch {
            let mapped = PullRequestWorkspaceError.worktreeCreationFailed(
                error.localizedDescription
            )
            lastPullRequestWorkspaceError = mapped
            throw mapped
        }
    }

    private func pullRequestProjectContext(
        for projectId: UUID
    ) throws -> (projectID: UUID, repositoryRoot: String) {
        guard let project = projects.first(where: { $0.id == projectId }) else {
            throw PullRequestWorkspaceError.projectUnavailable
        }
        guard workspaces.count < Self.maxWorkspaces else {
            throw PullRequestWorkspaceError.workspaceLimitReached
        }
        return (project.id, project.repositoryPath)
    }

    private func attachPullRequestWorkspace(
        _ resolution: PullRequestWorktreeResolution,
        metadata: PullRequestWorkspaceMetadata,
        context: (projectID: UUID, repositoryRoot: String),
        setupCommand: String?,
        collectionId: UUID?
    ) async throws -> Workspace {
        let (projectID, repositoryRoot) = context
        guard let currentProject = projects.first(where: { $0.id == projectID }),
            !closingSetupProjectIDs.contains(projectID), !isStoppingAllWorktreeSetups,
            canonicalPath(currentProject.repositoryPath) == canonicalPath(repositoryRoot)
        else {
            await cleanupPullRequestWorktreeIfNeeded(
                resolution,
                repositoryPath: repositoryRoot
            )
            throw PullRequestWorkspaceError.projectChanged
        }

        guard validateCreationDestination(collectionId), canClaimWorkspaceRoot(resolution.worktreePath) else {
            let error = lastWorkspaceCreationError!.localizedDescription
            await cleanupPullRequestWorktreeIfNeeded(resolution, repositoryPath: repositoryRoot)
            throw PullRequestWorkspaceError.worktreeCreationFailed(error)
        }

        if let existingWorkspace = workspaces.first(where: { workspace in
            workspace.projectId == projectID
                && workspace.branchName == resolution.branchName
                && canonicalPath(workspace.worktreePath ?? workspace.currentDirectory)
                    == canonicalPath(resolution.worktreePath)
        }) {
            if existingWorkspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                existingWorkspace.customTitle = metadata.title
                saveSession()
            }
            selectWorkspace(existingWorkspace.id)
            return existingWorkspace
        }

        guard workspaces.count < Self.maxWorkspaces else {
            await cleanupPullRequestWorktreeIfNeeded(
                resolution,
                repositoryPath: repositoryRoot
            )
            throw PullRequestWorkspaceError.workspaceLimitReached
        }

        let workspace = Workspace(
            title: resolution.branchName,
            workingDirectory: resolution.worktreePath,
            projectId: projectID,
            branchName: resolution.branchName,
            workspaceType: .worktree,
            worktreePath: resolution.worktreePath
        )
        // GitHub's title is the authoritative custom title for newly
        // created Pull Request Workspaces. Preserve it exactly as returned.
        workspace.customTitle = metadata.title
        workspaces.append(workspace)
        appendPlacement(workspace.id, to: collectionId)
        selectWorkspace(workspace.id)
        checkpointAndStartSetup(in: workspace, command: resolution.reusedExistingWorktree ? nil : setupCommand)
        return workspace
    }

    private func cleanupPullRequestWorktreeIfNeeded(
        _ resolution: PullRequestWorktreeResolution,
        repositoryPath: String
    ) async {
        await cleanupUnattachedWorktree(
            path: resolution.worktreePath, repositoryPath: repositoryPath,
            reusedExistingWorktree: resolution.reusedExistingWorktree)
    }
}
