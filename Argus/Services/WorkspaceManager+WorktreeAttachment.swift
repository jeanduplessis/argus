import Foundation

extension WorkspaceManager {
    struct PreparedWorktreeAttachment {
        let path: String
        let branchName: String
        let customTitle: String?
        let projectId: UUID
        let repositoryPath: String
        let reusedExistingWorktree: Bool
        let setupCommand: String?
        let collectionId: UUID?
        let selectsNewWorkspace: Bool
        let beforeAutomaticSetup: (@MainActor (Workspace) async -> Void)?
    }

    func attachPreparedWorktree(_ attachment: PreparedWorktreeAttachment) async -> Workspace? {
        guard validateCreationDestination(attachment.collectionId),
            let project = projects.first(where: { $0.id == attachment.projectId }),
            !closingSetupProjectIDs.contains(project.id), !isStoppingAllWorktreeSetups,
            canonicalPath(project.repositoryPath) == canonicalPath(attachment.repositoryPath),
            workspaces.count < Self.maxWorkspaces, canClaimWorkspaceRoot(attachment.path)
        else {
            let error = lastWorkspaceCreationError
            await cleanupUnattachedWorktree(
                path: attachment.path, repositoryPath: attachment.repositoryPath,
                reusedExistingWorktree: attachment.reusedExistingWorktree)
            lastWorkspaceCreationError = error
            return nil
        }

        let workspace = Workspace(
            title: attachment.branchName,
            workingDirectory: attachment.path,
            projectId: attachment.projectId,
            branchName: attachment.branchName,
            workspaceType: .worktree,
            worktreePath: attachment.path
        )
        if let customTitle = attachment.customTitle {
            workspace.setCustomTitle(customTitle)
        }
        workspaces.append(workspace)
        appendPlacement(workspace.id, to: attachment.collectionId)
        if attachment.selectsNewWorkspace {
            selectWorkspace(workspace.id)
        } else {
            refreshWorkspaceStacks(in: attachment.projectId)
        }
        let preparation = attachment.beforeAutomaticSetup.map { action in Task { await action(workspace) } }
        checkpointAndStartSetup(
            in: workspace, command: attachment.reusedExistingWorktree ? nil : attachment.setupCommand,
            after: preparation)
        await preparation?.value
        return workspace
    }
}
