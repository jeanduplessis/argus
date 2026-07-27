import Foundation

protocol ReviewProviding: Sendable {
    func authenticationStatus(host: String) async throws -> GitHubAccount
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem]
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws
        -> [GitHubChangedFile]
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity]
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation]
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws
    func setResolved(threadID: String, resolved: Bool, host: String) async throws
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview)
        async throws
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data
}

extension GitHubCLIProvider: ReviewProviding {}
