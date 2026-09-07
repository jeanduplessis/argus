import Foundation

extension WorkspaceManager {
    func inspectStackParent(for workspaceId: UUID) async throws -> StackParentContext {
        let owner = try stackWorkspaceOwner(for: workspaceId)
        let context = try await worktreeService.stackParentService.inspect(
            repositoryPath: owner.repositoryPath, worktreePath: owner.worktreePath)
        try validateStackWorkspaceOwner(owner)
        return context
    }

    @discardableResult
    func setStackParent(
        _ parent: String?, for workspaceId: UUID, expected: StackParentContext
    ) async throws -> StackParentContext {
        let owner = try stackWorkspaceOwner(for: workspaceId)
        try validateStackContext(expected, owner: owner)
        let current = try await worktreeService.stackParentService.inspect(
            repositoryPath: owner.repositoryPath, worktreePath: owner.worktreePath)
        try validateStackWorkspaceOwner(owner)
        guard current == expected else { throw StackParentError.contextChanged }
        let edit = try await worktreeService.stackParentService.editParent(parent, expected: expected)
        do {
            try validateStackWorkspaceOwner(owner)
            let verified = try await worktreeService.stackParentService.inspect(
                repositoryPath: owner.repositoryPath, worktreePath: owner.worktreePath)
            try Task.checkCancellation()
            try validateStackWorkspaceOwner(owner)
            guard verified == edit.context else { throw StackParentError.contextChanged }
            refreshWorkspaceStacks(in: owner.project.id)
            notifyWorkspaceContextChanged()
            return verified
        } catch {
            if let write = edit.write, !(await worktreeService.stackParentService.restore(write)) {
                throw StackParentError.retainedConfiguration(write.path)
            }
            throw error
        }
    }

    @discardableResult
    func addDependentWorkspace(
        to projectId: UUID, parentWorkspaceID: UUID, newBranch: String, expectedParent: StackParentContext
    ) async throws -> Workspace {
        let owner = try stackWorkspaceOwner(for: parentWorkspaceID)
        guard owner.project.id == projectId else { throw StackParentError.projectChanged }
        try validateStackContext(expectedParent, owner: owner)
        guard workspaces.count < Self.maxWorkspaces else { throw StackParentError.workspaceLimitReached }
        let selectedId = selectedWorkspaceId
        let revealRevision = workspaceRevealRevision
        let contextRevision = workspaceContextRevision
        let creation = try await worktreeService.createDependentWorktree(
            projectId: projectId, repositoryPath: owner.repositoryPath,
            branchName: newBranch, expectedParent: expectedParent)
        do {
            try Task.checkCancellation()
            try validateStackWorkspaceOwner(owner)
            guard workspaces.count < Self.maxWorkspaces else { throw StackParentError.workspaceLimitReached }
            try await worktreeService.validateDependentWorktree(creation)
            try Task.checkCancellation()
            try validateStackWorkspaceOwner(owner)
            guard workspaces.count < Self.maxWorkspaces else { throw StackParentError.workspaceLimitReached }
            guard !hasWorkspace(atDependentPath: creation.worktreePath),
                canClaimWorkspaceRoot(creation.worktreePath)
            else {
                throw DependentWorkspaceError.resourcesChanged
            }
            let workspace = Workspace(
                title: creation.branchName, workingDirectory: creation.worktreePath,
                projectId: projectId, branchName: creation.branchName,
                workspaceType: .worktree, worktreePath: creation.worktreePath)
            workspaces.append(workspace)
            appendPlacement(workspace.id, to: nil)
            if selectedWorkspaceId == selectedId, workspaceRevealRevision == revealRevision,
                workspaceContextRevision == contextRevision
            {
                selectWorkspace(workspace.id)
            }
            refreshWorkspaceStacks(in: projectId)
            saveSession()
            return workspace
        } catch {
            guard !hasWorkspace(atDependentPath: creation.worktreePath),
                await worktreeService.rollbackDependentWorktree(creation)
            else { throw worktreeService.dependentRecoveryError(creation.attempt) }
            throw error
        }
    }

    private struct StackWorkspaceOwner {
        let project: Project
        let workspace: Workspace
        let repositoryPath: String
        let worktreePath: String
        let workspaceRoot: String
        let workspaceType: WorkspaceType
        let storedWorktreePath: String?
    }

    private func stackWorkspaceOwner(for workspaceId: UUID) throws -> StackWorkspaceOwner {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }),
            let project = project(for: workspaceId),
            workspace.projectId == project.id
        else { throw StackParentError.workspaceUnavailable }
        let path: String
        switch workspace.workspaceType {
        case .mainCheckout:
            path = project.repositoryPath
        case .worktree:
            guard let worktreePath = workspace.worktreePath, !worktreePath.isEmpty else {
                throw StackParentError.workspaceUnavailable
            }
            path = worktreePath
        case .external:
            throw StackParentError.workspaceUnavailable
        }
        return StackWorkspaceOwner(
            project: project, workspace: workspace,
            repositoryPath: StackGitCommand.canonicalPath(project.repositoryPath),
            worktreePath: StackGitCommand.canonicalPath(path), workspaceRoot: workspace.currentDirectory,
            workspaceType: workspace.workspaceType, storedWorktreePath: workspace.worktreePath)
    }

    private func validateStackWorkspaceOwner(_ owner: StackWorkspaceOwner) throws {
        guard projects.contains(where: { $0 === owner.project }),
            workspaces.contains(where: { $0 === owner.workspace }),
            project(for: owner.workspace.id) === owner.project,
            owner.workspace.projectId == owner.project.id,
            owner.workspace.workspaceType == owner.workspaceType,
            owner.workspace.currentDirectory == owner.workspaceRoot,
            owner.workspace.worktreePath == owner.storedWorktreePath,
            StackGitCommand.canonicalPath(owner.project.repositoryPath) == owner.repositoryPath,
            StackGitCommand.canonicalPath(owner.storedWorktreePath ?? owner.project.repositoryPath)
                == owner.worktreePath
        else { throw StackParentError.projectChanged }
    }

    private func validateStackContext(_ context: StackParentContext, owner: StackWorkspaceOwner) throws {
        guard context.repositoryPath == owner.repositoryPath, context.worktreePath == owner.worktreePath else {
            throw StackParentError.contextChanged
        }
    }

    private func hasWorkspace(atDependentPath path: String) -> Bool {
        workspaces.contains {
            StackGitCommand.canonicalPath($0.worktreePath ?? $0.currentDirectory) == path
        }
    }
}
