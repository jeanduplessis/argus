import Foundation

struct WorkspacePullRequestEvidence: Equatable, Sendable {
    struct Ownership: Equatable, Sendable {
        let workspaceGeneration: UUID
        let projectGeneration: UUID
        let repositoryGeneration: UUID
        let observationGeneration: UUID
        let requestID: UUID
    }

    static let freshnessInterval: TimeInterval = 660

    let target: WorkspacePullRequestTarget
    let repository: RepositoryIdentity
    let branch: PullRequestBranchContext
    let fetchRemotes: [GitFetchRemote]
    let ownership: Ownership
    let status: PullRequestStatus
    let validatedAt: Date

    func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(validatedAt)
        return age >= 0 && age <= Self.freshnessInterval
    }

    func matches(
        target: WorkspacePullRequestTarget,
        branchName: String,
        headCommitID: String,
        at date: Date
    ) -> Bool {
        self.target == target && isFresh(at: date)
            && branch.branchName == branchName
            && !headCommitID.isEmpty && branch.headCommitObjectID == headCommitID
            && status.identity.repository == repository
            && status.headBranchName == branchName
            && (branch.upstreamRepository == nil || status.headRepository == branch.upstreamRepository)
    }

    func isExactHeadMerged(
        for target: WorkspacePullRequestTarget,
        branchName: String,
        headCommitID: String,
        at date: Date
    ) -> Bool {
        matches(target: target, branchName: branchName, headCommitID: headCommitID, at: date)
            && status.lifecycle == .merged && status.headCommitObjectID == headCommitID
    }
}
