import Foundation
import Testing

@testable import Argus

@Suite
struct GitHubCLIProviderTests {
    @Test
    func parsesGitHubAndEnterprisePullRequestURLs() {
        let publicURL = URL(string: "https://GitHub.com/octo/repository/pull/42")!
        let enterpriseURL = URL(string: "https://github.example.test/acme/tool/pull/7")!

        #expect(
            GitHubCLIProvider.parsePullRequestURL(publicURL) == PullRequestIdentity(
                repository: .init(host: "github.com", owner: "octo", name: "repository"),
                number: 42
            )
        )
        #expect(
            GitHubCLIProvider.parsePullRequestURL(enterpriseURL) == PullRequestIdentity(
                repository: .init(host: "github.example.test", owner: "acme", name: "tool"),
                number: 7
            )
        )
        #expect(GitHubCLIProvider.parsePullRequestURL(URL(string: "https://github.com/octo/repository/issues/42")!) == nil)
        #expect(GitHubCLIProvider.parsePullRequestURL(URL(string: "https://github.com:443/octo/repository/pull/42")!) == nil)
        #expect(GitHubCLIProvider.parsePullRequestURL(URL(string: "https://github.com/octo/../repository/pull/42")!) == nil)
    }

    @Test
    func authenticationUsesNoninteractiveArguments() async throws {
        let runner = FakeCommandRunner(results: [.success(json: #"{"login":"octocat"}"#)])
        let provider = GitHubCLIProvider(runner: runner)

        let account = try await provider.authenticationStatus()

        #expect(account == GitHubAccount(login: "octocat", host: "github.com"))
        let request = await runner.requests.single()
        #expect(["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].contains(request.executableURL.path))
        #expect(request.arguments == ["api", "--hostname", "github.com", "user"])
        #expect(request.environment["GH_PROMPT_DISABLED"] == "1")
        #expect(request.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(request.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(request.environment["SSH_AUTH_SOCK"] == nil)
    }

    @Test
    func loadsExactCommitContentWithoutLocalCommands() async throws {
        let runner = FakeCommandRunner(results: [.success(json: #"{"content":"aGVsbG8K","encoding":"base64"}"#)])
        let provider = GitHubCLIProvider(runner: runner)
        let repository = RepositoryIdentity(host: "github.com", owner: "octo", name: "repository")

        let content = try await provider.fileContent(path: "Sources/File name.swift", at: "deadbeef", in: repository)

        #expect(String(decoding: content, as: UTF8.self) == "hello\n")
        let request = await runner.requests.single()
        #expect(request.arguments.contains("repos/octo/repository/contents/Sources/File%20name.swift"))
        #expect(request.arguments.contains("--method"))
        #expect(request.arguments.contains("GET"))
        #expect(request.arguments.contains("ref=deadbeef"))
        #expect(!request.arguments.contains("git"))
    }

    @Test
    func rejectsUnsafeCommitBeforeRunningGitHubCLI() async {
        let runner = FakeCommandRunner(results: [])
        let provider = GitHubCLIProvider(runner: runner)
        let repository = RepositoryIdentity(host: "github.com", owner: "octo", name: "repository")

        await #expect(throws: GitHubCLIProviderError.validation("A valid repository, file path, and commit are required")) {
            try await provider.fileContent(path: "Sources/File.swift", at: "base/main", in: repository)
        }
        let requests = await runner.requests.all()
        #expect(requests.isEmpty)
    }

    @Test
    func exposesChangedFilePaginationAndMetadata() async throws {
        let files = (0..<2).map { #"{"filename":"file\#($0).swift","status":"modified","additions":1,"deletions":2}"# }.joined(separator: ",")
        let runner = FakeCommandRunner(results: [.success(json: "[\(files)]")])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let page = try await provider.changedFiles(
            for: identity,
            at: ReviewRevision(baseCommit: "base", headCommit: "head"),
            page: 3,
            pageSize: 2
        )

        #expect(page.values.map(\.path) == ["file0.swift", "file1.swift"])
        #expect(page.nextPage == 4)
        let request = await runner.requests.single()
        #expect(request.arguments.contains("repos/octo/repository/pulls/42/files?per_page=2&page=3"))
    }

    @Test
    func preservesSupportedGitHubChangedFileStatuses() async throws {
        let runner = FakeCommandRunner(results: [
            .success(json: #"[{"filename":"added.swift","status":"added","additions":1,"deletions":0},{"filename":"modified.swift","status":"modified","additions":1,"deletions":0},{"filename":"removed.swift","status":"removed","additions":0,"deletions":1},{"filename":"renamed.swift","status":"renamed","additions":0,"deletions":0},{"filename":"copied.swift","status":"copied","additions":1,"deletions":0},{"filename":"changed.swift","status":"changed","additions":1,"deletions":1}]"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let page = try await provider.changedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"), pageSize: 10)

        #expect(page.values.map(\.status) == [.added, .modified, .removed, .renamed, .copied, .changed])
    }

    @Test
    func derivesExactReviewCoordinatesFromCompleteUnifiedPatchHunks() {
        let patch = """
        @@ -2,3 +2,4 @@
         context
        -removed
        +added
        +second
         trailing
        @@ -10 +11 @@
        -old
        +new
        """

        let coordinates = GitHubCLIProvider.validAnchorCoordinates(from: patch)

        #expect(coordinates == [
            .init(side: .left, line: 2), .init(side: .right, line: 2),
            .init(side: .left, line: 3), .init(side: .right, line: 3),
            .init(side: .right, line: 4), .init(side: .left, line: 4), .init(side: .right, line: 5),
            .init(side: .left, line: 10), .init(side: .right, line: 11)
        ])
        #expect(!coordinates.contains(.init(side: .right, line: 100)))
    }

    @Test
    func omitsAnchorsForMissingOrTruncatedPatches() {
        #expect(GitHubCLIProvider.validAnchorCoordinates(from: nil).isEmpty)
        #expect(GitHubCLIProvider.validAnchorCoordinates(from: "@@ -1,2 +1,2 @@\n context").isEmpty)
        #expect(GitHubCLIProvider.validAnchorCoordinates(from: "patch omitted by GitHub").isEmpty)
    }

    @Test
    func rejectsUnknownChangedFileStatusOnFirstPageBeforeReadingViewedState() async {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: #"[{"filename":"one.swift","status":"unknown","additions":1,"deletions":0}]"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned an unsupported changed-file status")) {
            try await provider.allChangedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"), pageSize: 1)
        }

        let requests = await runner.requests.all()
        #expect(requests.count == 3)
        #expect(!requests.contains { $0.arguments.contains("graphql") })
    }

    @Test
    func rejectsUnknownChangedFileStatusOnLaterPageWithoutReturningPartialFiles() async {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: #"[{"filename":"one.swift","status":"modified","additions":1,"deletions":0}]"#),
            .success(json: #"[{"filename":"two.swift","status":"unknown","additions":1,"deletions":0}]"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned an unsupported changed-file status")) {
            try await provider.allChangedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"), pageSize: 1)
        }

        let requests = await runner.requests.all()
        #expect(requests.count == 4)
        #expect(!requests.contains { $0.arguments.contains("graphql") })
        #expect(requests.filter { $0.arguments.last?.contains("/files?") == true }.count == 2)
    }

    @Test
    func aggregatesChangedFilePagesAndRejectsPartialResults() async throws {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.example.test/octo/repository/pull/42"}"#),
            .success(json: #"[{"filename":"one.swift","status":"modified","additions":1,"deletions":0}]"#),
            .success(json: #"[{"filename":"two.swift","status":"added","additions":2,"deletions":0}]"#),
            .success(json: "[]"),
            .success(json: #"{"data":{"repository":{"pullRequest":{"files":{"nodes":[{"path":"one.swift","viewerViewedState":"VIEWED"},{"path":"two.swift","viewerViewedState":"UNVIEWED"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.example.test/octo/repository/pull/42"}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.example.test", owner: "octo", name: "repository"), number: 42)

        let files = try await provider.allChangedFiles(
            for: identity,
            at: .init(baseCommit: "base", headCommit: "head"),
            pageSize: 1
        )

        #expect(files.map(\.path) == ["one.swift", "two.swift"])
        let requests = await runner.requests.all()
        let changedFileRequests = requests
            .filter { $0.arguments.last?.contains("/files?") == true }
            .map { $0.arguments.last }
        #expect(changedFileRequests == [
            "repos/octo/repository/pulls/42/files?per_page=1&page=1",
            "repos/octo/repository/pulls/42/files?per_page=1&page=2",
            "repos/octo/repository/pulls/42/files?per_page=1&page=3"
        ])
        #expect(requests.allSatisfy { $0.arguments.contains("github.example.test") })
    }

    @Test
    func readsViewedStateFromFullyPaginatedPullRequestFilesConnection() async throws {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: #"[{"filename":"one.swift","status":"modified","additions":1,"deletions":0},{"filename":"two.swift","status":"modified","additions":1,"deletions":0}]"#),
            .success(json: "[]"),
            .success(json: #"{"data":{"repository":{"pullRequest":{"files":{"nodes":[{"path":"one.swift","viewerViewedState":"VIEWED"}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}}"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"files":{"nodes":[{"path":"two.swift","viewerViewedState":"UNVIEWED"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let files = try await provider.allChangedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"), pageSize: 2)

        #expect(files.map(\.viewedState) == [.viewed, .unviewed])
        let requests = await runner.requests.all()
        let secondPayload = try JSONSerialization.jsonObject(with: #require(requests[5].standardInput)) as! [String: Any]
        #expect((secondPayload["variables"] as? [String: Any])?["after"] as? String == "next")
        #expect((secondPayload["query"] as? String)?.contains("viewerViewedState") == true)
    }

    @Test
    func rejectsViewedStateWhenItDoesNotExactlyCorrespondToChangedFiles() async {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: #"[{"filename":"one.swift","status":"modified","additions":1,"deletions":0}]"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"files":{"nodes":[{"path":"other.swift","viewerViewedState":"VIEWED"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned incomplete changed-file viewed state")) {
            try await provider.allChangedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"), pageSize: 2)
        }
    }

    @Test
    func rejectsChangedFilesWhenRevisionMovesDuringPagination() async {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: "[]"),
            .success(json: #"{"data":{"repository":{"pullRequest":{"files":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR","title":"Title","state":"open","base":{"sha":"base"},"head":{"sha":"moved"},"html_url":"https://github.com/octo/repository/pull/42"}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.validation("Pull Request revision changed while loading files")) {
            try await provider.allChangedFiles(for: identity, at: .init(baseCommit: "base", headCommit: "head"))
        }
    }

    @Test
    func discoversIndividualAndTeamReviewInboxForExactAccountAndHost() async throws {
        let json = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[{"id":"PR_1","number":42,"title":"Individual request","state":"OPEN","isDraft":false,"url":"https://github.example.test/octo/repository/pull/42","updatedAt":"2026-07-26T12:00:00Z","author":{"login":"author"},"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[{"__typename":"User","login":"octocat"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}},{"id":"PR_2","number":43,"title":"Team request","state":"OPEN","isDraft":false,"url":"https://github.example.test/octo/repository/pull/43","updatedAt":"2026-07-26T12:01:00Z","author":{"login":"author"},"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[{"__typename":"Team","slug":"platform"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        let runner = FakeCommandRunner(results: [.success(json: json)])
        let provider = GitHubCLIProvider(runner: runner)

        let inbox = try await provider.reviewInbox(for: .init(login: "octocat", host: "github.example.test"))

        #expect(inbox.count == 2)
        #expect(inbox[0].pullRequest.identity.repository == .init(host: "github.example.test", owner: "octo", name: "repository"))
        #expect(inbox.map(\.requestedByLogin) == ["octocat", "platform"])
        let request = await runner.requests.single()
        #expect(request.arguments == ["api", "--hostname", "github.example.test", "graphql", "--method", "POST", "--input", "-"])
        let payload = try JSONSerialization.jsonObject(with: #require(request.standardInput)) as! [String: Any]
        let query = try #require(payload["query"] as? String)
        #expect(query.contains("search(query: \"is:pr is:open review-requested:@me\""))
        #expect(query.contains("requestedReviewers(first: 100)"))
        #expect(!query.contains("viewer {\n        reviewRequests"))
    }

    @Test
    func paginatesReviewInboxWithCursors() async throws {
        let firstPage = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[{"id":"PR_1","number":1,"title":"First","state":"OPEN","isDraft":false,"url":"https://github.com/octo/repository/pull/1","updatedAt":"2026-07-26T10:00:00Z","author":null,"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}"#
        let secondPage = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[{"id":"PR_2","number":2,"title":"Second","state":"OPEN","isDraft":false,"url":"https://github.com/octo/repository/pull/2","updatedAt":"2026-07-26T11:00:00Z","author":null,"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        let runner = FakeCommandRunner(results: [.success(json: firstPage), .success(json: secondPage)])
        let provider = GitHubCLIProvider(runner: runner)

        let inbox = try await provider.reviewInbox(for: .init(login: "octocat", host: "github.com"))

        #expect(inbox.map(\.pullRequest.identity.number) == [1, 2])
        let requests = await runner.requests.all()
        let secondPayload = try JSONSerialization.jsonObject(with: #require(requests[1].standardInput)) as! [String: Any]
        #expect((secondPayload["variables"] as? [String: Any])?["after"] as? String == "cursor-1")
    }

    @Test
    func rejectsReviewInboxWhenALaterPageFails() async {
        let firstPage = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: firstPage),
            .failure(stderr: "network unavailable")
        ]))

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.reviewInbox(for: .init(login: "octocat", host: "github.com"))
        }
    }

    @Test
    func rejectsReviewInboxWithMissingSearchCursor() async {
        let page = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: page)]))

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned a review inbox page without a cursor")) {
            try await provider.reviewInbox(for: .init(login: "octocat", host: "github.com"))
        }
    }

    @Test
    func paginatesRequestedReviewersAndRejectsAmbiguousTeams() async throws {
        let search = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[{"id":"PR_1","number":1,"title":"Review","state":"OPEN","isDraft":false,"url":"https://github.com/octo/repository/pull/1","updatedAt":"2026-07-26T10:00:00Z","author":null,"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[{"__typename":"Team","slug":"first-team"}],"pageInfo":{"hasNextPage":true,"endCursor":"reviewers-1"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        let reviewers = #"{"data":{"node":{"requestedReviewers":{"nodes":[{"__typename":"Team","slug":"second-team"},{"__typename":"Team","slug":"first-team"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let runner = FakeCommandRunner(results: [.success(json: search), .success(json: reviewers)])
        let provider = GitHubCLIProvider(runner: runner)

        let inbox = try await provider.reviewInbox(for: .init(login: "octocat", host: "github.com"))

        #expect(inbox[0].requestedByLogin == nil)
        let requests = await runner.requests.all()
        let payload = try JSONSerialization.jsonObject(with: #require(requests[1].standardInput)) as! [String: Any]
        #expect((payload["variables"] as? [String: Any])?["id"] as? String == "PR_1")
        #expect((payload["variables"] as? [String: Any])?["after"] as? String == "reviewers-1")
    }

    @Test
    func rejectsReviewInboxWithMissingRequestedReviewerCursor() async {
        let page = #"{"data":{"viewer":{"login":"octocat"},"search":{"nodes":[{"id":"PR_1","number":1,"title":"Review","state":"OPEN","isDraft":false,"url":"https://github.com/octo/repository/pull/1","updatedAt":"2026-07-26T10:00:00Z","author":null,"baseRefOid":"base","headRefOid":"head","repository":{"nameWithOwner":"octo/repository"},"requestedReviewers":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: page)]))

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned a requested reviewer page without a cursor")) {
            try await provider.reviewInbox(for: .init(login: "octocat", host: "github.com"))
        }
    }

    @Test
    func readsPublishedConversationsWithAnchorsAndPermissions() async throws {
        let json = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread","path":"Sources/App.swift","line":8,"startLine":7,"diffSide":"RIGHT","startDiffSide":"RIGHT","isResolved":false,"isOutdated":false,"viewerCanResolve":true,"viewerCanUnresolve":false,"comments":{"nodes":[{"id":"comment","databaseId":12,"body":"Please change","createdAt":"2026-07-26T12:00:00Z","updatedAt":null,"url":"https://github.com/comment","author":{"login":"reviewer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: json)]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let conversations = try await provider.publishedReviewConversations(identity)

        #expect(conversations[0].anchor.path == "Sources/App.swift")
        #expect(conversations[0].anchor.line == 8)
        #expect(conversations[0].comments[0].body == "Please change")
        #expect(conversations[0].permissions.canResolve)
        #expect(!conversations[0].permissions.canUnresolve)
    }

    @Test
    func rejectsReviewThreadsWithMissingNextPageCursor() async {
        let json = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: json)]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned a review thread page without a cursor")) {
            try await provider.publishedReviewConversations(identity)
        }
    }

    @Test
    func loadsCommentsBeyondTheFirstHundred() async throws {
        let firstHundred = "[" + (0..<100).map {
            #"{"id":"comment-\#($0)","databaseId":\#($0),"body":"First","createdAt":"2026-07-26T12:00:00Z","updatedAt":null,"url":null,"author":null}"#
        }.joined(separator: ",") + "]"
        let firstPage = """
        {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread","path":null,"line":null,"startLine":null,"diffSide":null,"startDiffSide":null,"isResolved":false,"isOutdated":false,"viewerCanResolve":false,"viewerCanUnresolve":false,"comments":{"nodes":\(firstHundred),"pageInfo":{"hasNextPage":true,"endCursor":"comments-1"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
        """
        let nextPage = #"{"data":{"node":{"comments":{"nodes":[{"id":"comment-101","databaseId":113,"body":"Later","createdAt":"2026-07-26T12:01:00Z","updatedAt":null,"url":null,"author":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let runner = FakeCommandRunner(results: [.success(json: firstPage), .success(json: nextPage)])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let conversations = try await provider.publishedReviewConversations(identity)

        #expect(conversations[0].comments.count == 101)
        #expect(Array(conversations[0].comments.map(\.id).suffix(2)) == ["comment-99", "comment-101"])
        let requests = await runner.requests.all()
        let payload = try JSONSerialization.jsonObject(with: #require(requests[1].standardInput)) as! [String: Any]
        #expect((payload["variables"] as? [String: Any])?["after"] as? String == "comments-1")
        #expect(requests.allSatisfy { $0.arguments.contains("github.com") })
    }

    @Test
    func rejectsConversationsWhenALaterCommentPageFails() async {
        let firstPage = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread","path":null,"line":null,"startLine":null,"diffSide":null,"startDiffSide":null,"isResolved":false,"isOutdated":false,"viewerCanResolve":false,"viewerCanUnresolve":false,"comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"comments-1"}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: firstPage), .failure(stderr: "network unavailable")
        ]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.publishedReviewConversations(identity)
        }
    }

    @Test
    func mergesAllThreadPagesWithoutDuplicateConversations() async throws {
        let firstPage = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"first","path":"One.swift","line":1,"startLine":null,"diffSide":"RIGHT","startDiffSide":null,"isResolved":false,"isOutdated":false,"viewerCanResolve":true,"viewerCanUnresolve":false,"comments":{"nodes":[{"id":"one","databaseId":1,"body":"One","createdAt":"2026-07-26T12:00:00Z","updatedAt":null,"url":null,"author":null}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":true,"endCursor":"threads-1"}}}}}}"#
        let secondPage = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"first","path":"One.swift","line":1,"startLine":null,"diffSide":"RIGHT","startDiffSide":null,"isResolved":false,"isOutdated":false,"viewerCanResolve":true,"viewerCanUnresolve":false,"comments":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}},{"id":"second","path":"Two.swift","line":2,"startLine":null,"diffSide":"LEFT","startDiffSide":null,"isResolved":true,"isOutdated":true,"viewerCanResolve":false,"viewerCanUnresolve":true,"comments":{"nodes":[{"id":"two","databaseId":2,"body":"Two","createdAt":"2026-07-26T12:01:00Z","updatedAt":null,"url":null,"author":{"login":"reviewer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: firstPage), .success(json: secondPage)]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let conversations = try await provider.publishedReviewConversations(identity)

        #expect(conversations.map(\.id) == ["first", "second"])
        #expect(conversations.map(\.anchor.path) == ["One.swift", "Two.swift"])
        #expect(conversations.map { $0.comments.map(\.id) } == [["one"], ["two"]])
        #expect(conversations[1].comments[0].authorLogin == "reviewer")
    }

    @Test
    func readsChronologicalPullRequestActivityWithExpectedRequests() async throws {
        let runner = FakeCommandRunner(results: [
            .success(json: #"[{"sha":"second","html_url":"https://github.example.test/octo/repository/commit/second","author":{"login":"author"},"commit":{"message":"Second commit","author":{"date":"2026-07-26T12:00:00Z"}}},{"sha":"first","html_url":"https://github.example.test/octo/repository/commit/first","author":{"login":"author"},"commit":{"message":"First commit","author":{"date":"2026-07-26T10:00:00Z"}}}]"#),
            .success(json: #"[{"id":17,"body":"Please revise","submitted_at":"2026-07-26T11:00:00Z","html_url":"https://github.example.test/octo/repository/pull/42#review-17","user":{"login":"reviewer"}},{"id":18,"body":"","submitted_at":null,"html_url":null,"user":{"login":"pending-reviewer"}}]"#),
            .success(json: #"[{"id":31,"body":"Follow-up","created_at":"2026-07-26T13:00:00Z","html_url":"https://github.example.test/octo/repository/issues/42#issuecomment-31","user":{"login":"commenter"}}]"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(
            repository: .init(host: "github.example.test", owner: "octo", name: "repository"),
            number: 42
        )

        let activity = try await provider.pullRequestActivity(identity)

        #expect(activity.map(\.id) == ["commit:first", "review:17", "commit:second", "comment:31"])
        #expect(activity.map(\.kind) == [.commit, .review, .commit, .issueComment])
        #expect(activity.map(\.authorLogin) == ["author", "reviewer", "author", "commenter"])
        #expect(activity.map(\.body) == ["First commit", "Please revise", "Second commit", "Follow-up"])

        let requests = await runner.requests.all()
        #expect(requests.map(\.arguments) == [
            ["api", "--hostname", "github.example.test", "repos/octo/repository/pulls/42/commits?per_page=100&page=1"],
            ["api", "--hostname", "github.example.test", "repos/octo/repository/pulls/42/reviews?per_page=100&page=1"],
            ["api", "--hostname", "github.example.test", "repos/octo/repository/issues/42/comments?per_page=100&page=1"]
        ])
    }

    @Test
    func paginatesEveryPullRequestActivityCollection() async throws {
        let commits = jsonArray(repeating: #"{"sha":"first","html_url":null,"author":null,"commit":{"message":"First","author":{"date":"2026-07-26T10:00:00Z"}}}"#, count: 100)
        let reviews = jsonArray(repeating: #"{"id":17,"body":"Review","submitted_at":"2026-07-26T11:00:00Z","html_url":null,"user":null}"#, count: 100)
        let comments = jsonArray(repeating: #"{"id":31,"body":"Comment","created_at":"2026-07-26T12:00:00Z","html_url":null,"user":null}"#, count: 100)
        let runner = FakeCommandRunner(results: [
            .success(json: commits),
            .success(json: #"[{"sha":"second","html_url":null,"author":null,"commit":{"message":"Second","author":{"date":"2026-07-26T13:00:00Z"}}}]"#),
            .success(json: reviews),
            .success(json: #"[{"id":18,"body":"Later review","submitted_at":"2026-07-26T14:00:00Z","html_url":null,"user":null}]"#),
            .success(json: comments),
            .success(json: #"[{"id":32,"body":"Later comment","created_at":"2026-07-26T15:00:00Z","html_url":null,"user":null}]"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let activity = try await provider.pullRequestActivity(identity)

        #expect(activity.map(\.id) == ["commit:first", "review:17", "comment:31", "commit:second", "review:18", "comment:32"])
        let endpoints = await runner.requests.all().map { $0.arguments.last }
        #expect(endpoints == [
            "repos/octo/repository/pulls/42/commits?per_page=100&page=1",
            "repos/octo/repository/pulls/42/commits?per_page=100&page=2",
            "repos/octo/repository/pulls/42/reviews?per_page=100&page=1",
            "repos/octo/repository/pulls/42/reviews?per_page=100&page=2",
            "repos/octo/repository/issues/42/comments?per_page=100&page=1",
            "repos/octo/repository/issues/42/comments?per_page=100&page=2"
        ])
    }

    @Test
    func rejectsActivityWhenCommitLaterPageFails() async {
        let commits = jsonArray(repeating: #"{"sha":"first","html_url":null,"author":null,"commit":{"message":"First","author":{"date":"2026-07-26T10:00:00Z"}}}"#, count: 100)
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [.success(json: commits), .failure(stderr: "network unavailable")]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.pullRequestActivity(identity)
        }
    }

    @Test
    func rejectsActivityWhenReviewLaterPageFails() async {
        let reviews = jsonArray(repeating: #"{"id":17,"body":"Review","submitted_at":"2026-07-26T11:00:00Z","html_url":null,"user":null}"#, count: 100)
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: "[]"), .success(json: reviews), .failure(stderr: "network unavailable")
        ]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.pullRequestActivity(identity)
        }
    }

    @Test
    func rejectsActivityWhenIssueCommentLaterPageFails() async {
        let comments = jsonArray(repeating: #"{"id":31,"body":"Comment","created_at":"2026-07-26T12:00:00Z","html_url":null,"user":null}"#, count: 100)
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: "[]"), .success(json: "[]"), .success(json: comments), .failure(stderr: "network unavailable")
        ]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.pullRequestActivity(identity)
        }
    }

    @Test
    func readsPullRequestChecksAndMapsCheckRunState() async throws {
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"mergeable":true,"mergeable_state":"clean"}"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED"}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR_42","title":"Review this","state":"open","user":{"login":"author"},"base":{"sha":"base"},"head":{"sha":"head"},"html_url":"https://github.example.test/octo/repository/pull/42"}"#),
            .success(json: #"{"total_count":2,"check_runs":[{"id":100,"name":"build","status":"completed","conclusion":"success","details_url":"https://github.example.test/octo/repository/runs/100"},{"id":101,"name":"lint","status":"in_progress","conclusion":null,"details_url":null}]}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(
            repository: .init(host: "github.example.test", owner: "octo", name: "repository"),
            number: 42
        )

        let checks = try await provider.pullRequestChecks(identity)

        #expect(checks.mergeable == "MERGEABLE")
        #expect(checks.mergeStateStatus == "clean")
        #expect(checks.reviewDecision == "APPROVED")
        #expect(checks.checkRuns.map(\.id) == ["100", "101"])
        #expect(checks.checkRuns.map(\.name) == ["build", "lint"])
        #expect(checks.checkRuns.map(\.status) == ["completed", "in_progress"])
        #expect(checks.checkRuns.map(\.conclusion) == ["success", nil])

        let requests = await runner.requests.all()
        #expect(requests.map(\.arguments) == [
            ["api", "--hostname", "github.example.test", "repos/octo/repository/pulls/42"],
            ["api", "--hostname", "github.example.test", "graphql", "--method", "POST", "--input", "-"],
            ["api", "--hostname", "github.example.test", "user"],
            ["api", "--hostname", "github.example.test", "repos/octo/repository/pulls/42"],
            ["api", "--hostname", "github.example.test", "repos/octo/repository/commits/head/check-runs?per_page=100&page=1"]
        ])
        let graphQLPayload = try JSONSerialization.jsonObject(with: requests[1].standardInput!) as! [String: Any]
        let variables = graphQLPayload["variables"] as! [String: Any]
        #expect(variables["owner"] as? String == "octo")
        #expect(variables["name"] as? String == "repository")
        #expect(variables["number"] as? Int == 42)
    }

    @Test
    func readsEveryCheckRunsPageInProviderOrderWithoutDuplicates() async throws {
        let firstPage = "[" + (1...100).map {
            #"{"id":\#($0),"name":"passing-\#($0)","status":"completed","conclusion":"success","details_url":null}"#
        }.joined(separator: ",") + "]"
        let runner = FakeCommandRunner(results: [
            .success(json: #"{"mergeable":true,"mergeable_state":"clean"}"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED"}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR_42","title":"Review this","state":"open","base":{"sha":"base"},"head":{"sha":"exact-head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: "{\"total_count\":101,\"check_runs\":\(firstPage)}"),
            .success(json: #"{"total_count":101,"check_runs":[{"id":1,"name":"passing","status":"completed","conclusion":"success","details_url":null},{"id":101,"name":"failing","status":"completed","conclusion":"failure","details_url":null}]}"#)
        ])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        let checks = try await provider.pullRequestChecks(identity)

        #expect(checks.checkRuns.count == 101)
        #expect(checks.checkRuns.map(\.id) == (1...101).map(String.init))
        #expect(checks.checkRuns.last?.conclusion == "failure")
        let endpoints = await runner.requests.all().compactMap { $0.arguments.last?.contains("/check-runs?") == true ? $0.arguments.last : nil }
        #expect(endpoints == [
            "repos/octo/repository/commits/exact-head/check-runs?per_page=100&page=1",
            "repos/octo/repository/commits/exact-head/check-runs?per_page=100&page=2"
        ])
    }

    @Test
    func rejectsCheckRunsWhenALaterPageFails() async {
        let firstPage = jsonArray(repeating: #"{"id":1,"name":"check","status":"completed","conclusion":"success","details_url":null}"#, count: 100)
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: #"{"mergeable":true,"mergeable_state":"clean"}"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"reviewDecision":null}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR_42","title":"Review this","state":"open","base":{"sha":"base"},"head":{"sha":"exact-head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: "{\"total_count\":101,\"check_runs\":\(firstPage)}"),
            .failure(stderr: "network unavailable")
        ]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.network("network unavailable")) {
            try await provider.pullRequestChecks(identity)
        }
    }

    @Test
    func rejectsTruncatedCheckRunsPagination() async {
        let provider = GitHubCLIProvider(runner: FakeCommandRunner(results: [
            .success(json: #"{"mergeable":true,"mergeable_state":"clean"}"#),
            .success(json: #"{"data":{"repository":{"pullRequest":{"reviewDecision":null}}}}"#),
            .success(json: #"{"login":"octocat"}"#),
            .success(json: #"{"node_id":"PR_42","title":"Review this","state":"open","base":{"sha":"base"},"head":{"sha":"exact-head"},"html_url":"https://github.com/octo/repository/pull/42"}"#),
            .success(json: #"{"total_count":101,"check_runs":[{"id":1,"name":"check","status":"completed","conclusion":"success","details_url":null}]}"#)
        ]))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        await #expect(throws: GitHubCLIProviderError.malformedResponse("GitHub returned a truncated check-runs page")) {
            try await provider.pullRequestChecks(identity)
        }
    }

    @Test
    func mapsDistinctProviderFailures() async {
        let unauthenticated = GitHubCLIProvider(
            runner: FakeCommandRunner(results: [.failure(stderr: "not logged in to github.com")])
        )
        await #expect(throws: GitHubCLIProviderError.unauthenticated(host: "github.com")) {
            try await unauthenticated.authenticationStatus()
        }

        let rateLimited = GitHubCLIProvider(
            runner: FakeCommandRunner(results: [.failure(stderr: "API rate limit exceeded")])
        )
        await #expect(throws: GitHubCLIProviderError.rateLimited("API rate limit exceeded")) {
            try await rateLimited.authenticationStatus()
        }
    }

    @Test
    func redactsSensitiveAndLocalConfigurationDiagnostics() async {
        let provider = GitHubCLIProvider(
            runner: FakeCommandRunner(
                results: [.failure(stderr: "Authorization: Bearer secret-token at /Users/person/.config/gh/hosts.yml")]
            )
        )

        await #expect(throws: GitHubCLIProviderError.commandFailed("Authorization: [redacted]")) {
            try await provider.authenticationStatus()
        }
    }

    @Test
    func explicitMutationsUseJSONStdinAndNeverShellText() async throws {
        let runner = FakeCommandRunner(
            results: [.success(json: "{}"), .success(json: "{}"), .success(json: "{}")]
        )
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        try await provider.setViewed(path: "a.swift", pullRequestNodeID: "PR_node", viewed: true, host: "github.com")
        try await provider.reply(to: 12, body: "looks good", in: identity)
        try await provider.submitReview(
            identity: identity,
            revision: .init(baseCommit: "base", headCommit: "head"),
            pendingReview: .init(
                revision: .init(baseCommit: "base", headCommit: "head"),
                inlineDrafts: [
                    .init(anchor: .init(path: "a.swift", line: 2, side: .right), body: "inline")
                ],
                summary: "ship it",
                disposition: .approve
            )
        )

        let requests = await runner.requests.all()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.arguments.first == "api" && !$0.arguments.contains("sh") })
        #expect(requests[1].arguments.suffix(2) == ["--input", "-"])
        #expect(String(decoding: requests[1].standardInput!, as: UTF8.self).contains("looks good"))
        #expect(String(decoding: requests[2].standardInput!, as: UTF8.self).contains("APPROVE"))
        #expect(String(decoding: requests[2].standardInput!, as: UTF8.self).contains("inline"))
    }

    @Test
    func usesInjectedExecutableWithoutPATHLookup() async throws {
        let runner = FakeCommandRunner(results: [.success(json: #"{"login":"octocat"}"#)])
        let executable = URL(fileURLWithPath: "/trusted/test/gh")
        let provider = GitHubCLIProvider(runner: runner, executableURL: executable)

        _ = try await provider.authenticationStatus()

        let request = await runner.requests.single()
        #expect(request.executableURL == executable)
        #expect(request.arguments.first == "api")
    }

    @Test
    func resolvesAndUnresolvesThreadsWithTheirRequestedMutation() async throws {
        let runner = FakeCommandRunner(results: [.success(json: "{}"), .success(json: "{}")])
        let provider = GitHubCLIProvider(runner: runner)

        try await provider.setResolved(threadID: "thread", resolved: true, host: "github.com")
        try await provider.setResolved(threadID: "thread", resolved: false, host: "github.com")

        let requests = await runner.requests.all()
        let payloads = try requests.map { request in
            try JSONSerialization.jsonObject(with: #require(request.standardInput)) as! [String: Any]
        }
        #expect((payloads[0]["query"] as? String)?.contains("resolveReviewThread") == true)
        #expect((payloads[1]["query"] as? String)?.contains("unresolveReviewThread") == true)
        #expect(requests.allSatisfy { $0.arguments == ["api", "--hostname", "github.com", "graphql", "--method", "POST", "--input", "-"] })
    }

    @Test
    func encodesAbsentPaginationCursorAsJSONNull() async throws {
        let json = #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        let runner = FakeCommandRunner(results: [.success(json: json)])
        let provider = GitHubCLIProvider(runner: runner)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "octo", name: "repository"), number: 42)

        _ = try await provider.publishedReviewConversations(identity)

        let request = await runner.requests.single()
        let payload = try JSONSerialization.jsonObject(with: request.standardInput!) as! [String: Any]
        let variables = payload["variables"] as! [String: Any]
        #expect(variables["after"] is NSNull)
    }
}

private actor FakeCommandRunner: CommandRunning {
    enum PlannedResult: Sendable {
        case success(json: String)
        case failure(stderr: String)
    }

    private var plannedResults: [PlannedResult]
    private(set) var requests: [CommandRequest] = []

    init(results: [PlannedResult]) {
        plannedResults = results
    }

    func run(_ request: CommandRequest) throws -> CommandResult {
        requests.append(request)
        guard !plannedResults.isEmpty else { throw CommandRunnerError.launchFailed("No planned result") }
        switch plannedResults.removeFirst() {
        case .success(let json): return CommandResult(standardOutput: Data(json.utf8), standardError: Data(), terminationStatus: 0)
        case .failure(let stderr): throw CommandRunnerError.nonZeroExit(CommandResult(standardOutput: Data(), standardError: Data(stderr.utf8), terminationStatus: 1))
        }
    }
}

private extension Array where Element == CommandRequest {
    func single() -> CommandRequest {
        precondition(count == 1)
        return self[0]
    }

    func all() -> [CommandRequest] { self }
}

private func jsonArray(repeating value: String, count: Int) -> String {
    "[" + Array(repeating: value, count: count).joined(separator: ",") + "]"
}
