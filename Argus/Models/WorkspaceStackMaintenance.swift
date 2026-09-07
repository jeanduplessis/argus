import Foundation

struct WorkspaceStackMergedPresentation: Equatable {
    let mergedWorkspaceIDs: [UUID]
    let hiddenWorkspaceIDs: Set<UUID>

    init(
        group: WorkspaceStackGroup,
        verifiedMergedWorkspaceIDs: Set<UUID>,
        protectedWorkspaceIDs: Set<UUID> = [],
        isExpanded: Bool
    ) {
        var prefix: [UUID] = []
        for row in group.rows {
            guard let workspaceID = row.workspaceId else { continue }
            guard verifiedMergedWorkspaceIDs.contains(workspaceID) else { break }
            prefix.append(workspaceID)
        }
        mergedWorkspaceIDs = prefix
        hiddenWorkspaceIDs = isExpanded ? [] : Set(prefix).subtracting(protectedWorkspaceIDs)
    }
}

@MainActor
struct MergedWorkspaceCloseCandidate: Identifiable {
    nonisolated let id: UUID
    let workspace: Workspace
    let project: Project
    let target: WorkspacePullRequestTarget
    let branchName: String
    let headCommitID: String
    let title: String
    private let storedBranchName: String?

    init?(workspace: Workspace, project: Project, branchName: String, headCommitID: String) {
        guard workspace.workspaceType == .worktree,
            workspace.projectId == project.id,
            let path = workspace.worktreePath, !path.isEmpty
        else { return nil }
        id = workspace.id
        self.workspace = workspace
        self.project = project
        target = WorkspacePullRequestTarget(
            workspaceID: workspace.id, projectID: project.id,
            repositoryPath: project.repositoryPath, worktreePath: path
        )
        self.branchName = branchName
        self.headCommitID = headCommitID
        title = workspace.displayTitle
        storedBranchName = workspace.branchName
    }

    func matchesCurrentWorkspace(in manager: WorkspaceManager) -> Bool {
        guard let path = workspace.worktreePath, !path.isEmpty else { return false }
        return manager.workspaces.contains { $0 === workspace }
            && manager.projects.contains { $0 === project }
            && workspace.workspaceType == .worktree
            && workspace.projectId == project.id
            && workspace.branchName == storedBranchName
            && target
                == WorkspacePullRequestTarget(
                    workspaceID: id, projectID: project.id,
                    repositoryPath: project.repositoryPath, worktreePath: path)
            && workspace.runningProcessCount == 0
    }

    func matchesStackSnapshot(_ snapshot: WorkspaceStackSnapshot?) -> Bool {
        guard let snapshot else { return false }
        let bindings = snapshot.worktrees.filter { $0.path == target.worktreePath }
        guard bindings.count == 1, let worktree = bindings.first else { return false }
        return worktree.branch == branchName && worktree.headCommitID == headCommitID
    }
}
