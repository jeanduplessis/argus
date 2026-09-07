import Foundation

enum MergedWorkspaceCleanupError: LocalizedError {
    case changedWorkspace

    var errorDescription: String? {
        "A Workspace, its Git history, or its Pull Request evidence changed. Refresh and review the selection again."
    }
}

extension WorkspaceManager {
    func closeMergedWorkspaces(
        _ candidates: [MergedWorkspaceCloseCandidate],
        evidence: (MergedWorkspaceCloseCandidate) -> WorkspacePullRequestEvidence?
    ) async throws {
        guard !candidates.isEmpty, Set(candidates.map(\.id)).count == candidates.count,
            candidates.allSatisfy({ $0.matchesCurrentWorkspace(in: self) })
        else { throw MergedWorkspaceCleanupError.changedWorkspace }
        let inputProvider = WorktreePullRequestLocalInputProvider(worktreeService: worktreeService)
        var confirmed: [UUID: WorkspacePullRequestEvidence] = [:]
        for candidate in candidates {
            guard let proof = evidence(candidate),
                proof.isExactHeadMerged(
                    for: candidate.target, branchName: candidate.branchName,
                    headCommitID: candidate.headCommitID, at: .now)
            else { throw MergedWorkspaceCleanupError.changedWorkspace }
            let context = try await inspectStackParent(for: candidate.id)
            let inputs = try await inputProvider.readWorktree(target: candidate.target)
            try Task.checkCancellation()
            guard context.repositoryPath == candidate.target.repositoryPath,
                context.worktreePath == candidate.target.worktreePath,
                context.branchName == candidate.branchName,
                context.headCommitID == candidate.headCommitID,
                inputs.branch == proof.branch, GitFetchRemote.normalized(inputs.fetchRemotes) == proof.fetchRemotes
            else { throw MergedWorkspaceCleanupError.changedWorkspace }
            confirmed[candidate.id] = proof
        }
        let closed = finishClosingMergedWorkspaces(candidates) { candidate in
            guard let current = evidence(candidate), current == confirmed[candidate.id] else { return false }
            return current.isExactHeadMerged(
                for: candidate.target, branchName: candidate.branchName,
                headCommitID: candidate.headCommitID, at: .now)
        }
        guard closed else { throw MergedWorkspaceCleanupError.changedWorkspace }
    }

    @discardableResult
    func finishClosingMergedWorkspaces(
        _ candidates: [MergedWorkspaceCloseCandidate],
        validatingEvidence: (MergedWorkspaceCloseCandidate) -> Bool
    ) -> Bool {
        let ids = Set(candidates.map(\.id))
        guard !ids.isEmpty, ids.count == candidates.count,
            candidates.allSatisfy({ $0.matchesCurrentWorkspace(in: self) && validatingEvidence($0) })
        else { return false }
        guard removeWorkspacesFromState(ids) else { return false }
        saveSession()
        return true
    }

    @discardableResult
    func removeWorkspacesFromState(_ workspaceIDs: Set<UUID>) -> Bool {
        let removed = workspaces.filter { workspaceIDs.contains($0.id) }
        guard !removed.isEmpty, removed.allSatisfy({ $0.runningSetupCount == 0 }),
            canRemoveWorkspaces(workspaceIDs)
        else { return false }
        let previousOrder = sidebarOrderedWorkspaces.map(\.workspace.id)
        let removedIDs = Set(removed.map(\.id))
        for workspace in removed {
            turnCompletionRuntime?.removeAttention(forWorkspace: workspace.id)
            agentStatusRuntime?.removeStatuses(forWorkspace: workspace.id)
            for panelID in workspace.panelOrder {
                workspace.closeTab(panelID)
            }
            workspace.worktreeSetupPanel = nil
            removePlacement(workspace.id)
        }
        workspaces.removeAll { removedIDs.contains($0.id) }
        restoreSelectionAfterRemovingWorkspaces(removedIDs, previousOrder: previousOrder)
        return true
    }
}
