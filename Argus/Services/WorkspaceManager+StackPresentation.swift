import Foundation

extension WorkspaceManager {
    func refreshMergedStackCandidates(
        in workspaceIDs: [UUID], projectID: UUID, statusModel: WorkspacePullRequestStatusModel
    ) async throws -> [MergedWorkspaceCloseCandidate] {
        try Task.checkCancellation()
        guard let project = projects.first(where: { $0.id == projectID }) else {
            throw MergedWorkspaceCleanupError.changedWorkspace
        }
        let requestedIDs = workspaceIDs.filter { workspaceIds(for: project).contains($0) }
        async let stackRefresh: Void = refreshWorkspaceStacksAndWait(in: projectID)
        statusModel.refresh(workspaceIDs: requestedIDs)
        await statusModel.waitForIdle()
        try await stackRefresh
        try Task.checkCancellation()
        guard projects.contains(where: { $0 === project }) else {
            throw MergedWorkspaceCleanupError.changedWorkspace
        }
        return mergedStackCandidates(in: requestedIDs, statusModel: statusModel, at: statusModel.now())
            .filter { $0.project === project && $0.matchesCurrentWorkspace(in: self) }
    }

    func mergedStackCandidates(
        in workspaceIDs: [UUID],
        statusModel: WorkspacePullRequestStatusModel,
        at date: Date
    ) -> [MergedWorkspaceCloseCandidate] {
        let targets = Dictionary(uniqueKeysWithValues: pullRequestStatusTargets.map { ($0.workspaceID, $0) })
        return workspaceIDs.compactMap { workspaceID in
            guard let target = targets[workspaceID],
                let workspace = workspaces.first(where: { $0.id == workspaceID }),
                let project = projects.first(where: { $0.id == target.projectID }),
                let snapshot = workspaceStackSnapshots[project.id]
            else { return nil }
            let matches = snapshot.worktrees.filter { $0.path == target.worktreePath }
            guard matches.count == 1, let worktree = matches.first,
                let branch = worktree.branch, let head = worktree.headCommitID,
                let evidence = statusModel.evidence(for: target, at: date),
                evidence.isExactHeadMerged(for: target, branchName: branch, headCommitID: head, at: date)
            else { return nil }
            return MergedWorkspaceCloseCandidate(
                workspace: workspace, project: project, branchName: branch, headCommitID: head
            )
        }
    }

    func stackPullRequestEvidence(
        for workspaceID: UUID,
        context: StackParentContext,
        statusModel: WorkspacePullRequestStatusModel,
        at date: Date
    ) -> WorkspacePullRequestEvidence? {
        guard let target = pullRequestStatusTargets.first(where: { $0.workspaceID == workspaceID }),
            target.repositoryPath == context.repositoryPath, target.worktreePath == context.worktreePath,
            let evidence = statusModel.evidence(for: target, at: date),
            evidence.status.headCommitObjectID == context.headCommitID,
            evidence.matches(
                target: target, branchName: context.branchName, headCommitID: context.headCommitID, at: date)
        else { return nil }
        return evidence
    }

    func stackComparisonAdvisory(
        owner: GitStatusSnapshotOwner,
        comparison: GitBaseComparisonContext?,
        statusModel: WorkspacePullRequestStatusModel,
        at date: Date
    ) -> StackComparisonAdvisory? {
        let targets = pullRequestStatusTargets
        guard let target = targets.first(where: { $0.workspaceID == owner.workspaceId }),
            target.worktreePath == WorkspacePullRequestTarget.normalizedPath(owner.rootPath)
        else { return nil }
        let parentTargets: [WorkspacePullRequestTarget]
        if let parent = comparison?.recordedParentBranch,
            let snapshot = workspaceStackSnapshots[target.projectID]
        {
            parentTargets = targets.filter { candidate in
                candidate.projectID == target.projectID && candidate.repositoryPath == target.repositoryPath
                    && snapshot.worktrees.contains {
                        $0.path == candidate.worktreePath && $0.branch == parent
                    }
            }
        } else {
            parentTargets = []
        }
        let parentTarget = parentTargets.count == 1 ? parentTargets.first : nil
        return StackComparisonAdvisoryResolver.resolve(
            target: target, comparison: comparison,
            childEvidence: statusModel.evidence(for: target, at: date),
            parentTarget: parentTarget,
            parentEvidence: parentTarget.flatMap { statusModel.evidence(for: $0, at: date) },
            at: date
        )
    }
}
