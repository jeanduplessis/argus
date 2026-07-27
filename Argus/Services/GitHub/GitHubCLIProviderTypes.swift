import Foundation

struct GitHubAccount: Codable, Hashable, Sendable {
    let login: String
    let host: String
}

struct GitHubPullRequest: Codable, Hashable, Sendable {
    let identity: PullRequestIdentity
    let nodeID: String
    let title: String
    let state: String
    let authorLogin: String?
    let baseCommit: String
    let headCommit: String
    let url: URL
}

struct GitHubReviewInboxItem: Codable, Hashable, Sendable {
    let pullRequest: GitHubPullRequest
    let requestedByLogin: String?
    let latestActivity: Date?
}

struct GitHubPullRequestActivity: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case commit
        case review
        case issueComment
    }

    let id: String
    let kind: Kind
    let authorLogin: String?
    let body: String?
    let createdAt: Date
    let url: URL?
}

struct GitHubCheckRun: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let status: String
    let conclusion: String?
    let detailsURL: URL?
}

struct GitHubPullRequestChecks: Codable, Hashable, Sendable {
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let checkRuns: [GitHubCheckRun]
}

struct GitHubReviewAnchor: Codable, Hashable, Sendable {
    let path: String?
    let line: Int?
    let startLine: Int?
    let side: String?
    let startSide: String?
}

struct GitHubPublishedComment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let databaseID: Int?
    let authorLogin: String?
    let body: String
    let createdAt: Date
    let updatedAt: Date?
    let url: URL?
}

struct GitHubReviewConversationPermissions: Codable, Hashable, Sendable {
    let canReply: Bool
    let canResolve: Bool
    let canUnresolve: Bool
}

struct GitHubReviewConversation: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let anchor: GitHubReviewAnchor
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [GitHubPublishedComment]
    let permissions: GitHubReviewConversationPermissions
}

enum GitHubChangedFileStatus: String, Codable, Sendable {
    case added
    case modified
    case removed
    case renamed
    case copied
    case changed
}

enum GitHubChangedFileViewedState: String, Codable, Sendable {
    case viewed
    case unviewed
}

struct GitHubChangedFile: Codable, Hashable, Sendable {
    let path: String
    let previousPath: String?
    let status: GitHubChangedFileStatus
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let viewedState: GitHubChangedFileViewedState
    /// Immutable reviewable line coordinates derived from this revision's REST
    /// patch. An empty set means the provider did not supply a complete patch.
    let validAnchorCoordinates: Set<GitHubDiffCoordinate>

    init(
        path: String,
        previousPath: String? = nil,
        status: GitHubChangedFileStatus = .changed,
        additions: Int = 0,
        deletions: Int = 0,
        isBinary: Bool = false,
        viewedState: GitHubChangedFileViewedState = .unviewed,
        validAnchorCoordinates: Set<GitHubDiffCoordinate> = []
    ) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
        self.viewedState = viewedState
        self.validAnchorCoordinates = validAnchorCoordinates
    }
}

struct GitHubDiffCoordinate: Codable, Hashable, Sendable {
    let side: ReviewDraftSide
    let line: Int
}

struct GitHubPage<Value: Sendable>: Sendable {
    let values: [Value]
    let nextPage: Int?
}

enum GitHubCLIProviderError: Error, LocalizedError, Sendable, Equatable {
    case cliUnavailable
    case unauthenticated(host: String)
    case authorization(String)
    case rateLimited(String)
    case network(String)
    case validation(String)
    case notFound(String)
    case timedOut
    case cancelled
    case commandFailed(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: "GitHub CLI (`gh`) is not installed"
        case .unauthenticated(let host): "GitHub CLI is not authenticated for \(host). Run: gh auth login --hostname \(host)"
        case .authorization(let detail), .rateLimited(let detail), .network(let detail), .validation(let detail), .notFound(let detail), .commandFailed(let detail), .malformedResponse(let detail): detail
        case .timedOut: "GitHub request timed out"
        case .cancelled: "GitHub request was cancelled"
        }
    }
}
