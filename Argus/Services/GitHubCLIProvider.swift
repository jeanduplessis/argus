import Foundation

/// GitHub provider boundary. It relies on the active `gh` account and never
/// reads, writes, or exposes credentials.
final class GitHubCLIProvider: Sendable {
    let runner: any CommandRunning
    let executableURL: URL
    let timeout: TimeInterval
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        runner: any CommandRunning = CommandRunner(),
        executableURL: URL? = nil,
        timeout: TimeInterval = 30
    ) {
        self.runner = runner
        self.executableURL = executableURL ?? Self.trustedExecutableURL()
        self.timeout = timeout
    }

    static func parsePullRequestURL(_ url: URL) -> PullRequestIdentity? {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              let host = canonicalHost(url.host)
        else {
            return nil
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 4,
              components[2].lowercased() == "pull",
              let number = Int(components[3]),
              number > 0,
              validRepositorySegment(String(components[0])),
              validRepositorySegment(String(components[1]))
        else {
            return nil
        }
        return PullRequestIdentity(
            repository: .init(
                host: host,
                owner: String(components[0]),
                name: String(components[1])
            ),
            number: number
        )
    }

    func authenticationStatus(host: String = "github.com") async throws -> GitHubAccount {
        guard let host = Self.canonicalHost(host) else {
            throw GitHubCLIProviderError.validation("GitHub host is invalid")
        }
        struct User: Decodable { let login: String }
        let user: User = try await apiJSON(["user"], host: host)
        return GitHubAccount(login: user.login, host: host)
    }

    /// Explicitly verifies the active GitHub CLI credential for one exact host.
    func authenticate(host: String) async throws -> GitHubAccount {
        try await authenticationStatus(host: host)
    }

    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        try validate(identity)
        _ = try await authenticate(host: identity.repository.host)
        struct Response: Decodable {
            struct User: Decodable {
                let login: String?
            }

            struct Ref: Decodable {
                let sha: String
            }

            let nodeID: String
            let title: String
            let state: String
            let user: User?
            let base: Ref
            let head: Ref
            let htmlURL: URL

            enum CodingKeys: String, CodingKey {
                case nodeID = "node_id"
                case title
                case state
                case user
                case base
                case head
                case htmlURL = "html_url"
            }
        }
        let response: Response = try await apiJSON([pullRequestEndpoint(identity)], host: identity.repository.host)
        return GitHubPullRequest(
            identity: identity,
            nodeID: response.nodeID,
            title: response.title,
            state: response.state,
            authorLogin: response.user?.login,
            baseCommit: response.base.sha,
            headCommit: response.head.sha,
            url: response.htmlURL
        )
    }

    func reviewRevision(_ identity: PullRequestIdentity) async throws -> ReviewRevision {
        let metadata = try await pullRequestMetadata(identity)
        return ReviewRevision(baseCommit: metadata.baseCommit, headCommit: metadata.headCommit)
    }

    /// Discovers open review requests for exactly the supplied active account and host.
    /// Search establishes eligibility; requested reviewers identify direct requests and,
    /// when unambiguous, the eligible team request without guessing membership.
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] {
        guard let host = Self.canonicalHost(account.host), !account.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubCLIProviderError.validation("GitHub account is invalid")
        }
        struct Response: Decodable {
            struct Data: Decodable {
                struct Viewer: Decodable {
                    let login: String
                }
                let viewer: Viewer
                struct Search: Decodable {
                    struct PullRequest: Decodable {
                        struct Repository: Decodable { let nameWithOwner: String }
                        struct Author: Decodable { let login: String? }
                        let id: String
                        let number: Int
                        let title: String
                        let state: String
                        let isDraft: Bool
                        let url: URL
                        let updatedAt: Date
                        let author: Author?
                        let baseRefOid: String
                        let headRefOid: String
                        let repository: Repository
                        let requestedReviewers: RequestedReviewers
                    }
                    let nodes: [PullRequest]
                    let pageInfo: PageInfo
                }
                let search: Search
            }
            let data: Data
        }
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        struct Reviewer: Decodable {
            let typename: String
            let login: String?
            let slug: String?

            enum CodingKeys: String, CodingKey {
                case typename = "__typename"
                case login
                case slug
            }
        }
        struct RequestedReviewers: Decodable {
            let nodes: [Reviewer]
            let pageInfo: PageInfo
        }
        struct RequestedReviewersResponse: Decodable {
            struct Data: Decodable {
                struct Node: Decodable { let requestedReviewers: RequestedReviewers? }
                let node: Node?
            }
            let data: Data
        }
        var inbox: [GitHubReviewInboxItem] = []
        var seenPullRequests = Set<PullRequestIdentity>()
        var after: String?
        while true {
            let response: Response = try await graphqlJSON(
                query: Self.reviewInboxQuery,
                variables: ["after": after ?? NSNull()],
                host: host
            )
            guard response.data.viewer.login.caseInsensitiveCompare(account.login) == .orderedSame else {
                throw GitHubCLIProviderError.authorization("GitHub CLI active account changed for \(account.host)")
            }
            for pullRequest in response.data.search.nodes {
                let repositoryParts = pullRequest.repository.nameWithOwner.split(separator: "/", maxSplits: 1).map(String.init)
                guard repositoryParts.count == 2 else { throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid repository identity") }
                guard Self.validRepositorySegment(repositoryParts[0]), Self.validRepositorySegment(repositoryParts[1]), pullRequest.number > 0 else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid repository identity")
                }
                let identity = PullRequestIdentity(
                    repository: .init(
                        host: host,
                        owner: repositoryParts[0],
                        name: repositoryParts[1]
                    ),
                    number: pullRequest.number
                )
                guard seenPullRequests.insert(identity).inserted else { continue }
                let reviewers = try await allRequestedReviewers(
                    initial: pullRequest.requestedReviewers,
                    pullRequestNodeID: pullRequest.id,
                    host: host
                )
                let state = pullRequest.isDraft ? "draft" : pullRequest.state
                inbox.append(GitHubReviewInboxItem(
                    pullRequest: .init(
                        identity: identity,
                        nodeID: pullRequest.id,
                        title: pullRequest.title,
                        state: state,
                        authorLogin: pullRequest.author?.login,
                        baseCommit: pullRequest.baseRefOid,
                        headCommit: pullRequest.headRefOid,
                        url: pullRequest.url
                    ),
                    requestedByLogin: requestedByLogin(reviewers, accountLogin: account.login),
                    latestActivity: pullRequest.updatedAt
                ))
            }
            let pageInfo = response.data.search.pageInfo
            guard pageInfo.hasNextPage else { return inbox }
            guard let endCursor = pageInfo.endCursor else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned a review inbox page without a cursor")
            }
            after = endCursor
        }

        func allRequestedReviewers(initial: RequestedReviewers, pullRequestNodeID: String, host: String) async throws -> [Reviewer] {
            var reviewers = initial.nodes
            var pageInfo = initial.pageInfo
            var after: String?
            while pageInfo.hasNextPage {
                guard let cursor = pageInfo.endCursor else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned a requested reviewer page without a cursor")
                }
                after = cursor
                let response: RequestedReviewersResponse = try await graphqlJSON(
                    query: Self.requestedReviewersQuery,
                    variables: ["id": pullRequestNodeID, "after": after],
                    host: host
                )
                guard let next = response.data.node?.requestedReviewers else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid requested reviewer page")
                }
                reviewers += next.nodes
                pageInfo = next.pageInfo
            }
            return reviewers
        }

        func requestedByLogin(_ reviewers: [Reviewer], accountLogin: String) -> String? {
            var identities = Set<String>()
            var users: [String] = []
            var teams: [String] = []
            for reviewer in reviewers {
                switch reviewer.typename {
                case "User":
                    guard let login = reviewer.login, !login.isEmpty else { continue }
                    if identities.insert("user:\(login.lowercased())").inserted { users.append(login) }
                case "Team":
                    guard let slug = reviewer.slug, !slug.isEmpty else { continue }
                    if identities.insert("team:\(slug.lowercased())").inserted { teams.append(slug) }
                default:
                    continue
                }
            }
            if let directRequest = users.first(where: { $0.caseInsensitiveCompare(accountLogin) == .orderedSame }) {
                return directRequest
            }
            // Search proves the viewer is eligible for a team request, but cannot
            // identify which team when more than one was requested.
            return teams.count == 1 ? teams[0] : nil
        }
    }

    /// Fetches one deterministic page. Callers own aggregation and stale-result
    /// handling, which keeps pagination observable and testable at this boundary.
    func changedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, page: Int = 1, pageSize: Int = 100) async throws -> GitHubPage<GitHubChangedFile> {
        guard valid(identity), valid(revision), (1...100).contains(pageSize), page > 0 else {
            throw GitHubCLIProviderError.validation("Changed-file page bounds are invalid")
        }
        struct Response: Decodable {
            let filename: String
            let previousFilename: String?
            let status: String
            let additions: Int
            let deletions: Int
            let patch: String?

            enum CodingKeys: String, CodingKey {
                case filename
                case previousFilename = "previous_filename"
                case status
                case additions
                case deletions
                case patch
            }
        }
        let endpoint = "\(pullRequestEndpoint(identity))/files?per_page=\(pageSize)&page=\(page)"
        let response: [Response] = try await apiJSON(
            [endpoint],
            host: identity.repository.host
        )
        let files = try response.map { response in
            guard let status = GitHubChangedFileStatus(rawValue: response.status) else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned an unsupported changed-file status")
            }
            return GitHubChangedFile(
                path: response.filename,
                previousPath: response.previousFilename,
                status: status,
                additions: response.additions,
                deletions: response.deletions,
                isBinary: false,
                validAnchorCoordinates: Self.validAnchorCoordinates(from: response.patch)
            )
        }
        return GitHubPage(values: files, nextPage: files.count == pageSize ? page + 1 : nil)
    }

    /// Loads every changed-file page. The returned collection is complete, or this
    /// method throws so callers can retain their last complete cached revision.
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int = 100) async throws -> [GitHubChangedFile] {
        guard valid(identity), valid(revision), (1...100).contains(pageSize) else {
            throw GitHubCLIProviderError.validation(
                "A valid pull request, review revision, and page size are required"
            )
        }
        let initialMetadata = try await pullRequestMetadata(identity)
        guard ReviewRevision(baseCommit: initialMetadata.baseCommit, headCommit: initialMetadata.headCommit) == revision else {
            throw GitHubCLIProviderError.validation("Pull Request revision changed before loading files")
        }
        var files: [GitHubChangedFile] = []
        var page = 1
        while true {
            let result = try await changedFiles(for: identity, at: revision, page: page, pageSize: pageSize)
            files.append(contentsOf: result.values)
            guard let nextPage = result.nextPage else {
                let viewedStates = try await allChangedFileViewedStates(for: identity)
                let uniqueFilePaths = Set(files.map(\.path))
                guard uniqueFilePaths.count == files.count else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned duplicate changed-file paths")
                }
                guard Set(viewedStates.keys) == uniqueFilePaths else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned incomplete changed-file viewed state")
                }
                let finalMetadata = try await pullRequestMetadata(identity)
                guard ReviewRevision(baseCommit: finalMetadata.baseCommit, headCommit: finalMetadata.headCommit) == revision else {
                    throw GitHubCLIProviderError.validation("Pull Request revision changed while loading files")
                }
                return files.map { file in
                    var file = file
                    file = GitHubChangedFile(
                        path: file.path, previousPath: file.previousPath, status: file.status,
                        additions: file.additions, deletions: file.deletions, isBinary: file.isBinary,
                        viewedState: viewedStates[file.path]!, validAnchorCoordinates: file.validAnchorCoordinates)
                    return file
                }
            }
            page = nextPage
        }
    }

    /// Parses only complete unified-diff hunks. A missing, malformed, or
    /// truncated patch produces no anchors so callers never invent a location.
    static func validAnchorCoordinates(from patch: String?) -> Set<GitHubDiffCoordinate> {
        guard let patch, !patch.isEmpty else { return [] }
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        var coordinates = Set<GitHubDiffCoordinate>()
        var index = 0
        var foundHunk = false

        while index < lines.count {
            // `split(omittingEmptySubsequences: false)` retains the harmless
            // final element produced by a newline-terminated patch.
            if index == lines.count - 1, lines[index].isEmpty { break }
            guard let header = parseHunkHeader(lines[index]) else { return [] }
            foundHunk = true
            index += 1
            var oldLine = header.oldStart
            var newLine = header.newStart
            var oldRemaining = header.oldCount
            var newRemaining = header.newCount
            while oldRemaining > 0 || newRemaining > 0 {
                guard index < lines.count else { return [] }
                let line = lines[index]
                guard let marker = line.first else { return [] }
                switch marker {
                case " ":
                    guard oldRemaining > 0, newRemaining > 0 else { return [] }
                    coordinates.insert(.init(side: .left, line: oldLine))
                    coordinates.insert(.init(side: .right, line: newLine))
                    oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                case "-":
                    guard oldRemaining > 0 else { return [] }
                    coordinates.insert(.init(side: .left, line: oldLine))
                    oldLine += 1; oldRemaining -= 1
                case "+":
                    guard newRemaining > 0 else { return [] }
                    coordinates.insert(.init(side: .right, line: newLine))
                    newLine += 1; newRemaining -= 1
                default:
                    return []
                }
                index += 1
            }
            // A no-newline marker has no coordinate and follows a consumed line.
            if index < lines.count, lines[index].hasPrefix("\\ No newline at end of file") { index += 1 }
        }
        return foundHunk ? coordinates : []
    }

    private static func parseHunkHeader(_ line: Substring) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard line.hasPrefix("@@ "), let closing = line.range(of: " @@", options: .backwards) else { return nil }
        let fields = line[..<closing.lowerBound].split(separator: " ")
        guard fields.count == 3,
              let old = parseHunkRange(fields[1], prefix: "-"),
              let new = parseHunkRange(fields[2], prefix: "+")
        else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func parseHunkRange(_ value: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard value.first == prefix else { return nil }
        let numbers = value.dropFirst().split(separator: ",", maxSplits: 1).map(String.init)
        guard let start = Int(numbers[0]), start >= 0 else { return nil }
        let count = numbers.count == 2 ? Int(numbers[1]) : 1
        guard let count, count >= 0, start > 0 || count == 0 else { return nil }
        return (start, count)
    }

    /// Reads GitHub's authoritative per-viewer state from the PullRequest.files
    /// connection. REST changed-file responses do not expose this state.
    private func allChangedFileViewedStates(
        for identity: PullRequestIdentity
    ) async throws -> [String: GitHubChangedFileViewedState] {
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct File: Decodable { let path: String; let viewerViewedState: String }
        struct Response: Decodable {
            struct Data: Decodable {
                struct Repository: Decodable {
                    struct PullRequest: Decodable {
                        struct Files: Decodable { let nodes: [File]; let pageInfo: PageInfo }
                        let files: Files
                    }
                    let pullRequest: PullRequest?
                }
                let repository: Repository?
            }
            let data: Data
        }
        var states: [String: GitHubChangedFileViewedState] = [:]
        var after: String?
        while true {
            let response: Response = try await graphqlJSON(
                query: Self.changedFileViewedStatesQuery,
                variables: [
                    "owner": identity.repository.owner,
                    "name": identity.repository.name,
                    "number": identity.number,
                    "after": after ?? NSNull()
                ],
                host: identity.repository.host
            )
            guard let files = response.data.repository?.pullRequest?.files else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned no changed-file viewed state")
            }
            for file in files.nodes {
                guard validFilePath(file.path), let state = GitHubChangedFileViewedState(rawValue: file.viewerViewedState.lowercased()) else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid changed-file viewed state")
                }
                guard states.updateValue(state, forKey: file.path) == nil else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned duplicate changed-file viewed state")
                }
            }
            guard files.pageInfo.hasNextPage else { return states }
            guard let cursor = files.pageInfo.endCursor else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned a changed-file viewed-state page without a cursor")
            }
            after = cursor
        }
    }

    /// Reads timeline data for the Activity section without mutating the Pull Request.
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] {
        struct Commit: Decodable {
            struct Author: Decodable {
                let login: String?
            }

            struct Message: Decodable {
                struct Timestamp: Decodable {
                    let date: Date
                }

                let message: String
                let author: Timestamp
            }

            let sha: String
            let htmlURL: URL?
            let author: Author?
            let commit: Message

            enum CodingKeys: String, CodingKey {
                case sha
                case htmlURL = "html_url"
                case author
                case commit
            }
        }

        struct Review: Decodable {
            struct User: Decodable {
                let login: String?
            }

            let id: Int
            let body: String?
            let submittedAt: Date?
            let htmlURL: URL?
            let user: User?

            enum CodingKeys: String, CodingKey {
                case id
                case body
                case submittedAt = "submitted_at"
                case htmlURL = "html_url"
                case user
            }
        }

        struct IssueComment: Decodable {
            struct User: Decodable {
                let login: String?
            }

            let id: Int
            let body: String
            let createdAt: Date
            let htmlURL: URL?
            let user: User?

            enum CodingKeys: String, CodingKey {
                case id
                case body
                case createdAt = "created_at"
                case htmlURL = "html_url"
                case user
            }
        }

        let pullRequestPath = "repos/\(identity.repository.owner)/\(identity.repository.name)/pulls/\(identity.number)"
        let issuePath = "repos/\(identity.repository.owner)/\(identity.repository.name)/issues/\(identity.number)"
        let loadedCommits: [Commit] = try await allRESTPages(
            endpoint: "\(pullRequestPath)/commits",
            host: identity.repository.host
        )
        let loadedReviews: [Review] = try await allRESTPages(
            endpoint: "\(pullRequestPath)/reviews",
            host: identity.repository.host
        )
        let loadedComments: [IssueComment] = try await allRESTPages(
            endpoint: "\(issuePath)/comments",
            host: identity.repository.host
        )
        let commits = loadedCommits.map {
            GitHubPullRequestActivity(
                id: "commit:\($0.sha)",
                kind: .commit,
                authorLogin: $0.author?.login,
                body: $0.commit.message,
                createdAt: $0.commit.author.date,
                url: $0.htmlURL
            )
        }
        let reviews = loadedReviews.compactMap { review -> GitHubPullRequestActivity? in
            guard let date = review.submittedAt else { return nil }
            return GitHubPullRequestActivity(
                id: "review:\(review.id)",
                kind: .review,
                authorLogin: review.user?.login,
                body: review.body,
                createdAt: date,
                url: review.htmlURL
            )
        }
        let comments = loadedComments.map {
            GitHubPullRequestActivity(
                id: "comment:\($0.id)",
                kind: .issueComment,
                authorLogin: $0.user?.login,
                body: $0.body,
                createdAt: $0.createdAt,
                url: $0.htmlURL
            )
        }
        return chronologicalActivity(commits + reviews + comments)
    }

    /// Reads merge and CI state for the Checks section. It has no administrative action.
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        try validate(identity)
        struct PullRequest: Decodable {
            let mergeable: Bool?
            let mergeableState: String?

            enum CodingKeys: String, CodingKey {
                case mergeable
                case mergeableState = "mergeable_state"
            }
        }

        struct CheckRuns: Decodable {
            struct Run: Decodable {
                let id: Int
                let name: String
                let status: String
                let conclusion: String?
                let detailsURL: URL?

                enum CodingKeys: String, CodingKey {
                    case id
                    case name
                    case status
                    case conclusion
                    case detailsURL = "details_url"
                }
            }

            let totalCount: Int
            let checkRuns: [Run]

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case checkRuns = "check_runs"
            }
        }

        struct ReviewDecisionResponse: Decodable {
            struct Data: Decodable {
                struct Repository: Decodable {
                    struct PullRequest: Decodable {
                        let reviewDecision: String?
                    }

                    let pullRequest: PullRequest
                }

                let repository: Repository
            }

            let data: Data
        }
        let pullRequestPath = "repos/\(identity.repository.owner)/\(identity.repository.name)/pulls/\(identity.number)"
        let loadedPullRequest: PullRequest = try await apiJSON(
            [pullRequestPath],
            host: identity.repository.host
        )
        let loadedDecision: ReviewDecisionResponse = try await graphqlJSON(
            query: Self.reviewDecisionQuery,
            variables: [
                "owner": identity.repository.owner,
                "name": identity.repository.name,
                "number": identity.number
            ],
            host: identity.repository.host
        )
        let metadata = try await pullRequestMetadata(identity)
        let checkRunsPath = "repos/\(identity.repository.owner)/\(identity.repository.name)/commits/\(metadata.headCommit)/check-runs"
        var runs: [CheckRuns.Run] = []
        var seenRunIDs = Set<Int>()
        var expectedCount: Int?
        var page = 1
        while true {
            let response: CheckRuns = try await apiJSON(
                ["\(checkRunsPath)?per_page=100&page=\(page)"],
                host: identity.repository.host
            )
            guard response.totalCount >= 0, response.checkRuns.count <= 100 else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid check-runs page")
            }
            if let expectedCount {
                guard response.totalCount == expectedCount else {
                    throw GitHubCLIProviderError.malformedResponse("GitHub returned inconsistent check-runs pagination")
                }
            } else {
                expectedCount = response.totalCount
            }

            let uniqueRuns = response.checkRuns.filter { seenRunIDs.insert($0.id).inserted }
            runs += uniqueRuns
            guard runs.count <= response.totalCount else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned inconsistent check-runs pagination")
            }
            guard runs.count < response.totalCount else { break }
            guard response.checkRuns.count == 100, page < (response.totalCount + 99) / 100 else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned a truncated check-runs page")
            }
            page += 1
        }
        return GitHubPullRequestChecks(
            mergeable: loadedPullRequest.mergeable.map { $0 ? "MERGEABLE" : "CONFLICTING" },
            mergeStateStatus: loadedPullRequest.mergeableState,
            reviewDecision: loadedDecision.data.repository.pullRequest.reviewDecision,
            checkRuns: runs.map {
                GitHubCheckRun(
                    id: String($0.id),
                    name: $0.name,
                    status: $0.status,
                    conclusion: $0.conclusion,
                    detailsURL: $0.detailsURL
                )
            }
        )
    }

    /// Loads all published review threads and their comments. A failed later page
    /// throws instead of returning a partial conversation cache.
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] {
        try validate(identity)
        struct Response: Decodable {
            struct Data: Decodable {
                struct Repository: Decodable {
                    struct PullRequest: Decodable {
                        struct Threads: Decodable {
                            struct Node: Decodable {
                                struct Comments: Decodable {
                                    struct Node: Decodable {
                                        struct Author: Decodable {
                                            let login: String?
                                        }

                                        let id: String
                                        let databaseID: Int?
                                        let body: String
                                        let createdAt: Date
                                        let updatedAt: Date?
                                        let url: URL?
                                        let author: Author?
                                    }

                                    let nodes: [Node]
                                    let pageInfo: PageInfo

                                    struct PageInfo: Decodable {
                                        let hasNextPage: Bool
                                        let endCursor: String?
                                    }
                                }

                                let id: String
                                let path: String?
                                let line: Int?
                                let startLine: Int?
                                let diffSide: String?
                                let startDiffSide: String?
                                let isResolved: Bool
                                let isOutdated: Bool
                                let viewerCanResolve: Bool
                                let viewerCanUnresolve: Bool
                                let comments: Comments
                            }

                            struct PageInfo: Decodable {
                                let hasNextPage: Bool
                                let endCursor: String?
                            }

                            let nodes: [Node]
                            let pageInfo: PageInfo
                        }

                        let reviewThreads: Threads
                    }

                    let pullRequest: PullRequest
                }

                let repository: Repository
            }

            let data: Data
        }

        typealias Comment = Response.Data.Repository.PullRequest.Threads.Node.Comments.Node
        typealias CommentPageInfo = Response.Data.Repository.PullRequest.Threads.Node.Comments.PageInfo
        struct CommentPageResponse: Decodable {
            struct Data: Decodable {
                struct Node: Decodable {
                    let comments: Comments

                    struct Comments: Decodable {
                        let nodes: [Comment]
                        let pageInfo: CommentPageInfo
                    }
                }

                let node: Node?
            }

            let data: Data
        }

        func publishedComment(_ comment: Comment) -> GitHubPublishedComment {
            GitHubPublishedComment(
                id: comment.id,
                databaseID: comment.databaseID,
                authorLogin: comment.author?.login,
                body: comment.body,
                createdAt: comment.createdAt,
                updatedAt: comment.updatedAt,
                url: comment.url
            )
        }

        var conversations: [GitHubReviewConversation] = []
        var threadIDs = Set<String>()
        var after: String?
        while true {
            let response: Response = try await graphqlJSON(
                query: Self.publishedReviewConversationsQuery,
                variables: [
                    "owner": identity.repository.owner,
                    "name": identity.repository.name,
                    "number": identity.number,
                    "after": after ?? NSNull()
                ],
                host: identity.repository.host
            )
            let threads = response.data.repository.pullRequest.reviewThreads
            for thread in threads.nodes where threadIDs.insert(thread.id).inserted {
                var comments = thread.comments.nodes.map(publishedComment)
                var commentIDs = Set(comments.map(\.id))
                var pageInfo = thread.comments.pageInfo
                while pageInfo.hasNextPage {
                    guard let endCursor = pageInfo.endCursor else {
                        throw GitHubCLIProviderError.malformedResponse("GitHub returned a review comment page without a cursor")
                    }
                    let commentResponse: CommentPageResponse = try await graphqlJSON(
                        query: Self.publishedReviewThreadCommentsQuery,
                        variables: ["id": thread.id, "after": endCursor],
                        host: identity.repository.host
                    )
                    guard let commentPage = commentResponse.data.node?.comments else {
                        throw GitHubCLIProviderError.malformedResponse("GitHub returned an invalid review thread comment page")
                    }
                    comments += commentPage.nodes.map(publishedComment).filter { commentIDs.insert($0.id).inserted }
                    pageInfo = commentPage.pageInfo
                }
                conversations.append(GitHubReviewConversation(
                    id: thread.id,
                    anchor: .init(
                        path: thread.path,
                        line: thread.line,
                        startLine: thread.startLine,
                        side: thread.diffSide,
                        startSide: thread.startDiffSide
                    ),
                    isResolved: thread.isResolved,
                    isOutdated: thread.isOutdated,
                    comments: comments,
                    permissions: .init(
                        canReply: !comments.isEmpty,
                        canResolve: thread.viewerCanResolve,
                        canUnresolve: thread.viewerCanUnresolve
                    )
                ))
            }
            guard threads.pageInfo.hasNextPage else { return conversations }
            guard let endCursor = threads.pageInfo.endCursor else {
                throw GitHubCLIProviderError.malformedResponse("GitHub returned a review thread page without a cursor")
            }
            after = endCursor
        }
    }

    /// Reads GitHub's object content at the exact revision commit; it never reads
    /// a local checkout, index, or working tree.
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data {
        guard valid(repository), validFilePath(path), validCommit(commit) else {
            throw GitHubCLIProviderError.validation(
                "A valid repository, file path, and commit are required"
            )
        }
        struct Response: Decodable { let content: String; let encoding: String }
        let encodedPath = path.split(separator: "/").map { Self.apiPathSegment(String($0)) }.joined(separator: "/")
        let response: Response = try await apiJSON([
            "repos/\(Self.apiPathSegment(repository.owner))/\(Self.apiPathSegment(repository.name))/contents/\(encodedPath)",
            "--method", "GET",
            "-f", "ref=\(commit)"
        ], host: repository.host)
        guard response.encoding == "base64", let data = Data(base64Encoded: response.content.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubCLIProviderError.malformedResponse("GitHub returned unsupported file content")
        }
        return data
    }

    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {
        guard validFilePath(path),
              validNodeID(pullRequestNodeID),
              Self.canonicalHost(host) != nil
        else {
            throw GitHubCLIProviderError.validation("Viewed-file input is invalid")
        }
        let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
        let query = """
        mutation SetViewed($pullRequestId: ID!, $path: String!) {
          \(mutation)(input: { pullRequestId: $pullRequestId, path: $path }) {
            clientMutationId
          }
        }
        """
        _ = try await graphql(mutation: query, variables: ["pullRequestId": pullRequestNodeID, "path": path], host: host)
    }

    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {
        guard valid(identity), commentID > 0, !body.isEmpty else {
            throw GitHubCLIProviderError.validation("Reply input is invalid")
        }
        _ = try await apiJSON(
            ["repos/\(Self.apiPathSegment(identity.repository.owner))/\(Self.apiPathSegment(identity.repository.name))/pulls/comments/\(commentID)/replies", "--method", "POST"],
            host: identity.repository.host,
            standardInput: try JSONSerialization.data(withJSONObject: ["body": body])
        ) as EmptyResponse
    }

    func setResolved(threadID: String, resolved: Bool, host: String) async throws {
        guard validNodeID(threadID), Self.canonicalHost(host) != nil else {
            throw GitHubCLIProviderError.validation("Review-thread input is invalid")
        }
        let mutation = resolved ? "resolveReviewThread" : "unresolveReviewThread"
        let query = """
        mutation SetResolved($threadId: ID!) {
          \(mutation)(input: { threadId: $threadId }) {
            thread { id }
          }
        }
        """
        _ = try await graphql(mutation: query, variables: ["threadId": threadID], host: host)
    }

    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {
        guard valid(identity), valid(revision) else {
            throw GitHubCLIProviderError.validation(
                "A valid pull request and review revision are required"
            )
        }
        guard pendingReview.inlineDrafts.allSatisfy({ !$0.requiresRemap && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GitHubCLIProviderError.validation("Inline drafts must be mapped and non-empty before submission")
        }
        guard let disposition = pendingReview.disposition else {
            throw GitHubCLIProviderError.validation("Select a Review Disposition before submission")
        }
        var payload: [String: Any] = ["event": githubDisposition(disposition), "commit_id": revision.headCommit]
        if !pendingReview.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["body"] = pendingReview.summary }
        if !pendingReview.inlineDrafts.isEmpty {
            payload["comments"] = pendingReview.inlineDrafts.map { ["path": $0.anchor.path, "line": $0.anchor.line, "side": $0.anchor.side.rawValue, "body": $0.body] }
        }
        _ = try await apiJSON(
            ["\(pullRequestEndpoint(identity))/reviews", "--method", "POST"],
            host: identity.repository.host,
            standardInput: try JSONSerialization.data(withJSONObject: payload)
        ) as EmptyResponse
    }

}
