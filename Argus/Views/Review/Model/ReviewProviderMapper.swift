import Foundation

enum ReviewProviderMapper {
    static func pullRequest(_ item: GitHubReviewInboxItem) -> ReviewPullRequest {
        .init(
            identity: item.pullRequest.identity,
            title: item.pullRequest.title,
            author: item.pullRequest.authorLogin ?? "",
            state: item.pullRequest.state.lowercased() == "draft" ? .draft : .open,
            membership: .inbox,
            latestActivity: item.latestActivity
        )
    }

    static func file(_ file: GitHubChangedFile) -> ReviewChangedFile {
        let status: ReviewFileStatus = switch file.status {
        case .added: .added
        case .modified, .changed: .modified
        case .removed: .deleted
        case .renamed: .renamed
        case .copied: .copied
        }
        return .init(
            path: file.path,
            previousPath: file.previousPath,
            status: file.isBinary ? .binary : status,
            contentState: file.isBinary ? .binary : .available,
            additions: file.additions,
            deletions: file.deletions,
            viewedState: file.viewedState == .viewed ? .viewed : .unviewed,
            validAnchorCoordinates: Set(file.validAnchorCoordinates.map {
                .init(side: $0.side, line: $0.line)
            })
        )
    }

    static func conversation(_ source: GitHubReviewConversation) -> ReviewConversation {
        .init(
            id: source.id,
            path: source.anchor.path,
            line: source.anchor.line,
            isResolved: source.isResolved,
            isOutdated: source.isOutdated,
            comments: source.comments.map {
                .init(
                    id: $0.id,
                    databaseID: $0.databaseID,
                    author: $0.authorLogin,
                    body: $0.body,
                    createdAt: $0.createdAt
                )
            },
            permissions: .init(
                canReply: source.permissions.canReply,
                canResolve: source.permissions.canResolve,
                canUnresolve: source.permissions.canUnresolve
            )
        )
    }

    static func pullRequestState(_ raw: String) -> ReviewPullRequestState {
        switch raw.lowercased() {
        case "closed": .closed
        case "merged": .merged
        case "draft": .draft
        default: .open
        }
    }
}
