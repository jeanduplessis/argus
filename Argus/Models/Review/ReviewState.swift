import Foundation

enum ReviewPullRequestState: String, Codable, Sendable {
    case open, closed, merged, draft
}

enum ReviewMembership: String, Codable, Sendable {
    case inbox, saved
}

enum ReviewSection: String, Codable, CaseIterable, Sendable {
    case files, activity, checks
}

enum ReviewLoadState: String, Codable, Sendable {
    case initialLoading, refreshing, loaded, stale, blocked, failed
}

enum ReviewFileStatus: String, Codable, Sendable {
    case added, modified, deleted, renamed, copied, binary, generated, truncated, unavailable
}

enum ReviewContentState: String, Codable, Sendable {
    case available, binary, generated, oversized, unavailable, providerTruncated, failed
}

enum ReviewViewedState: String, Codable, Sendable {
    case viewed, unviewed, pendingViewed, pendingUnviewed
}

/// An unacknowledged explicit author request. Provider changed-file payloads
/// are replaceable, so this state is durable and revision-scoped.
struct ReviewViewedIntent: Codable, Hashable, Sendable {
    var revision: ReviewRevision
    var path: String
    var viewed: Bool

    init(revision: ReviewRevision, path: String, viewed: Bool) {
        self.revision = revision
        self.path = path
        self.viewed = viewed
    }

    var key: Key { .init(revision: revision, path: path) }

    struct Key: Hashable, Sendable {
        var revision: ReviewRevision
        var path: String
    }
}

struct ReviewChangedFile: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var path: String
    var previousPath: String?
    var status: ReviewFileStatus
    var contentState: ReviewContentState
    var additions: Int?
    var deletions: Int?
    var viewedState: ReviewViewedState
    var publishedConversationCount: Int
    var hasUnresolvedConversation: Bool
    var hasLocalDraft: Bool
    /// Exact immutable Review Revision coordinates GitHub accepts for inline
    /// comments. An empty set deliberately means no inline anchor is known.
    var validAnchorCoordinates: Set<ReviewDiffCoordinate>

    init(
        path: String, previousPath: String? = nil, status: ReviewFileStatus = .modified,
        contentState: ReviewContentState = .available, additions: Int? = nil, deletions: Int? = nil,
        viewedState: ReviewViewedState = .unviewed, publishedConversationCount: Int = 0,
        hasUnresolvedConversation: Bool = false, hasLocalDraft: Bool = false,
        validAnchorCoordinates: Set<ReviewDiffCoordinate> = []
    ) {
        self.id = path
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.contentState = contentState
        self.additions = additions
        self.deletions = deletions
        self.viewedState = viewedState
        self.publishedConversationCount = publishedConversationCount
        self.hasUnresolvedConversation = hasUnresolvedConversation
        self.hasLocalDraft = hasLocalDraft
        self.validAnchorCoordinates = validAnchorCoordinates
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, previousPath, status, contentState, additions, deletions, viewedState,
            publishedConversationCount, hasUnresolvedConversation, hasLocalDraft, validAnchorCoordinates
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try values.decode(String.self, forKey: .path),
            previousPath: try values.decodeIfPresent(String.self, forKey: .previousPath),
            status: try values.decodeIfPresent(ReviewFileStatus.self, forKey: .status) ?? .modified,
            contentState: try values.decodeIfPresent(ReviewContentState.self, forKey: .contentState) ?? .available,
            additions: try values.decodeIfPresent(Int.self, forKey: .additions),
            deletions: try values.decodeIfPresent(Int.self, forKey: .deletions),
            viewedState: try values.decodeIfPresent(ReviewViewedState.self, forKey: .viewedState) ?? .unviewed,
            publishedConversationCount: try values.decodeIfPresent(Int.self, forKey: .publishedConversationCount) ?? 0,
            hasUnresolvedConversation: try values.decodeIfPresent(Bool.self, forKey: .hasUnresolvedConversation) ?? false,
            hasLocalDraft: try values.decodeIfPresent(Bool.self, forKey: .hasLocalDraft) ?? false,
            validAnchorCoordinates: try values.decodeIfPresent(Set<ReviewDiffCoordinate>.self, forKey: .validAnchorCoordinates) ?? []
        )
    }
}

struct ReviewFileFilter: Codable, Hashable, Sendable {
    var pathQuery: String = ""
    var onlyUnviewed = false

    func matches(_ file: ReviewChangedFile) -> Bool {
        (!onlyUnviewed || file.viewedState != .viewed)
            && (pathQuery.isEmpty || file.path.localizedCaseInsensitiveContains(pathQuery))
    }
}

enum ReviewDisposition: String, Codable, CaseIterable, Sendable {
    case approve, comment, requestChanges
}

enum ReviewDraftSide: String, Codable, CaseIterable, Sendable {
    case left = "LEFT"
    case right = "RIGHT"
}

struct ReviewDiffCoordinate: Codable, Hashable, Sendable {
    var side: ReviewDraftSide
    var line: Int
}

struct ReviewDraftAnchor: Codable, Hashable, Sendable {
    var path: String
    var line: Int
    var side: ReviewDraftSide

    private enum CodingKeys: String, CodingKey { case path, line, side }

    init(path: String, line: Int, side: ReviewDraftSide) {
        self.path = path
        self.line = line
        self.side = side
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawSide = try values.decode(String.self, forKey: .side)
        guard let side = ReviewDraftSide(rawValue: rawSide.uppercased()) else {
            throw DecodingError.dataCorruptedError(
                forKey: .side,
                in: values,
                debugDescription: "Review draft anchors require LEFT or RIGHT side"
            )
        }
        self.init(
            path: try values.decode(String.self, forKey: .path),
            line: try values.decode(Int.self, forKey: .line),
            side: side
        )
    }

    func isValid(for file: ReviewChangedFile) -> Bool {
        guard path == file.path, line > 0 else { return false }
        switch file.status {
        case .deleted where side != .left, .added where side != .right:
            return false
        default:
            return file.validAnchorCoordinates.contains(.init(side: side, line: line))
        }
    }
}

struct ReviewInlineDraft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var anchor: ReviewDraftAnchor
    var body: String
    var requiresRemap: Bool

    init(id: UUID = UUID(), anchor: ReviewDraftAnchor, body: String, requiresRemap: Bool = false) {
        self.id = id
        self.anchor = anchor
        self.body = body
        self.requiresRemap = requiresRemap
    }
}

struct ReviewReplyDraft: Codable, Hashable, Sendable, Identifiable {
    let conversationID: String
    var body: String
    var lastSendError: String?
    var id: String { conversationID }
}

struct ReviewConversation: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var path: String?
    var line: Int?
    var isResolved: Bool
    var isOutdated: Bool
    var comments: [ReviewPublishedComment]
    var permissions: ReviewConversationPermissions
}

struct ReviewPublishedComment: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var databaseID: Int?
    var author: String?
    var body: String
    var createdAt: Date
}

struct ReviewConversationPermissions: Codable, Hashable, Sendable {
    var canReply: Bool
    var canResolve: Bool
    var canUnresolve: Bool
}

struct ReviewActivityItem: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var kind: String
    var author: String?
    var body: String?
    var createdAt: Date
}

struct ReviewCheck: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String
    var status: String
    var conclusion: String?
}

struct ReviewChecksState: Codable, Hashable, Sendable {
    var mergeable: String?
    var mergeStateStatus: String?
    var reviewDecision: String?
    var checks: [ReviewCheck]
}

struct ReviewPaneState: Codable, Hashable, Sendable {
    static let fileListWidthBounds: ClosedRange<Double> = 180...480
    static let rightSidebarWidthBounds: ClosedRange<Double> = 180...600

    var filesCollapsed = false
    var conversationsCollapsed = false
    var activeDrawer: ReviewDrawer?
    var filesWidth: Double = 250
    var conversationsWidth: Double = 300

    init(
        filesCollapsed: Bool = false,
        conversationsCollapsed: Bool = false,
        activeDrawer: ReviewDrawer? = nil,
        filesWidth: Double = 250,
        conversationsWidth: Double = 300
    ) {
        self.filesCollapsed = filesCollapsed
        self.conversationsCollapsed = conversationsCollapsed
        self.activeDrawer = activeDrawer
        self.filesWidth = Self.normalizedFileListWidth(filesWidth)
        self.conversationsWidth = Self.normalizedFileListWidth(conversationsWidth)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            filesCollapsed: try values.decodeIfPresent(Bool.self, forKey: .filesCollapsed) ?? false,
            conversationsCollapsed: try values.decodeIfPresent(Bool.self, forKey: .conversationsCollapsed) ?? false,
            activeDrawer: try values.decodeIfPresent(ReviewDrawer.self, forKey: .activeDrawer),
            filesWidth: try values.decodeIfPresent(Double.self, forKey: .filesWidth) ?? 250,
            conversationsWidth: try values.decodeIfPresent(Double.self, forKey: .conversationsWidth) ?? 300
        )
    }

    static func normalizedFileListWidth(_ width: Double) -> Double {
        normalized(width, to: fileListWidthBounds)
    }

    static func normalizedRightSidebarWidth(_ width: Double) -> Double {
        normalized(width, to: rightSidebarWidthBounds)
    }

    static func normalized(_ width: Double, to bounds: ClosedRange<Double>) -> Double {
        min(max(width, bounds.lowerBound), bounds.upperBound)
    }
}

enum ReviewDrawer: String, Codable, Hashable, Sendable { case files, conversations }

enum ReviewAttention: String, Codable, Sendable {
    case none, newRequest, remoteActivity, newCommits, failedOperation
}

enum ReviewRevisionUpdateOutcome: String, Codable, Sendable {
    case unchanged, updated, staleHeadAvailable, draftsMapped, draftsRequireRemap
}

struct ReviewRevisionUpdateResult: Sendable, Equatable {
    let outcome: ReviewRevisionUpdateOutcome
    let mappedDraftIDs: Set<UUID>
    let unmappedDraftIDs: Set<UUID>
}

struct ReviewPullRequest: Codable, Hashable, Sendable, Identifiable {
    var id: PullRequestIdentity { identity }
    let identity: PullRequestIdentity
    var projectID: UUID?
    var title: String
    var author: String
    var state: ReviewPullRequestState
    var membership: ReviewMembership
    var isManuallySaved: Bool
    var latestActivity: Date?
    var attention: ReviewAttention

    init(
        identity: PullRequestIdentity, projectID: UUID? = nil, title: String, author: String,
        state: ReviewPullRequestState = .open,
        membership: ReviewMembership = .inbox, isManuallySaved: Bool = false, latestActivity: Date? = nil,
        attention: ReviewAttention = .none
    ) {
        self.identity = identity
        self.projectID = projectID
        self.title = title
        self.author = author
        self.state = state
        self.membership = membership
        self.isManuallySaved = isManuallySaved
        self.latestActivity = latestActivity
        self.attention = attention
    }
}
