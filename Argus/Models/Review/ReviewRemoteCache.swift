import Foundation

/// A complete provider read stored outside the user-authored session snapshot.
struct ReviewRemoteCache: Codable, Sendable {
    var pullRequest: PullRequestIdentity
    var revision: ReviewRevision
    var changedFiles: [ReviewChangedFile]
    var conversations: [ReviewConversation]
    var activity: [ReviewActivityItem]
    var checks: ReviewChecksState
    var savedAt: Date

    private enum CodingKeys: String, CodingKey {
        case pullRequest, revision, changedFiles, conversations, activity, checks, savedAt
    }

    init(
        pullRequest: PullRequestIdentity, revision: ReviewRevision, changedFiles: [ReviewChangedFile],
        conversations: [ReviewConversation], activity: [ReviewActivityItem], checks: ReviewChecksState, savedAt: Date
    ) {
        self.pullRequest = pullRequest
        self.revision = revision
        self.changedFiles = changedFiles
        self.conversations = conversations
        self.activity = activity
        self.checks = checks
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            pullRequest: try values.decode(PullRequestIdentity.self, forKey: .pullRequest),
            revision: try values.decode(ReviewRevision.self, forKey: .revision),
            changedFiles: try values.decodeIfPresent([ReviewChangedFile].self, forKey: .changedFiles) ?? [],
            conversations: try values.decodeIfPresent([ReviewConversation].self, forKey: .conversations) ?? [],
            activity: try values.decodeIfPresent([ReviewActivityItem].self, forKey: .activity) ?? [],
            checks: try values.decodeIfPresent(ReviewChecksState.self, forKey: .checks)
                ?? .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
            savedAt: try values.decode(Date.self, forKey: .savedAt)
        )
    }
}
