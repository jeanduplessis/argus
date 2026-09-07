import Foundation

struct StackComparisonAdvisory: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case parentMergedNeedsSync
        case pullRequestTargetMismatch
    }

    let kind: Kind
    let recordedParentBranch: String
    let pullRequestBaseBranch: String
    let mergedParentPullRequest: PullRequestIdentity?
}

enum StackComparisonAdvisoryResolver {
    static func resolve(
        target: WorkspacePullRequestTarget,
        comparison: GitBaseComparisonContext?,
        childEvidence: WorkspacePullRequestEvidence?,
        parentTarget: WorkspacePullRequestTarget? = nil,
        parentEvidence: WorkspacePullRequestEvidence? = nil,
        at date: Date
    ) -> StackComparisonAdvisory? {
        guard let comparison, comparison.rootPath == target.worktreePath,
            let branchName = comparison.branchName, let head = comparison.headCommitID,
            let parent = comparison.recordedParentBranch, parent != branchName,
            GitReferenceValidation.isValidBranchName(parent),
            let childEvidence,
            childEvidence.matches(target: target, branchName: branchName, headCommitID: head, at: date),
            GitReferenceValidation.isValidBranchName(childEvidence.status.baseBranchName)
        else { return nil }
        let mergedParent = matchingMergedParent(
            comparison: comparison, childEvidence: childEvidence,
            parentTarget: parentTarget, parentEvidence: parentEvidence, at: date)
        guard mergedParent != nil || childEvidence.status.baseBranchName != parent else { return nil }
        return StackComparisonAdvisory(
            kind: mergedParent == nil ? .pullRequestTargetMismatch : .parentMergedNeedsSync,
            recordedParentBranch: parent, pullRequestBaseBranch: childEvidence.status.baseBranchName,
            mergedParentPullRequest: mergedParent
        )
    }

    private static func matchingMergedParent(
        comparison: GitBaseComparisonContext,
        childEvidence: WorkspacePullRequestEvidence,
        parentTarget: WorkspacePullRequestTarget?,
        parentEvidence: WorkspacePullRequestEvidence?,
        at date: Date
    ) -> PullRequestIdentity? {
        guard let parentTarget, let parentEvidence,
            let parent = comparison.recordedParentBranch, let parentHead = comparison.baseCommitID,
            comparison.baseBranchName == parent,
            comparison.resolvedRef == "refs/heads/\(parent)"
                || comparison.resolvedRef == "refs/remotes/origin/\(parent)",
            parentTarget.projectID == childEvidence.target.projectID,
            parentTarget.repositoryPath == childEvidence.target.repositoryPath,
            parentTarget.workspaceID != childEvidence.target.workspaceID,
            parentTarget.worktreePath != childEvidence.target.worktreePath,
            parentEvidence.repository == childEvidence.repository,
            parentEvidence.isExactHeadMerged(
                for: parentTarget, branchName: parent, headCommitID: parentHead, at: date)
        else { return nil }
        return parentEvidence.status.identity
    }
}
