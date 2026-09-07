import Foundation
import Testing

@testable import Argus

extension GitStatusPresentationTests {
    @Test
    func emptyComparisonRetainsTheRecordedParentAndExactCommitContext() async throws {
        let repo = try stackedRepository(prefix: "argus-base-empty-context")
        defer { repo.remove() }
        try TestGit.run(["switch", "-c", "empty-child", Self.parentBranch], in: repo.url)
        try TestGit.run(["config", "branch.empty-child.base", Self.parentBranch], in: repo.url)
        let head = try TestGit.run(["rev-parse", "HEAD"], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        let section = try #require(summary.sections.last)
        let context = try #require(section.comparisonContext)

        #expect(section.files.isEmpty)
        #expect(section.totalCount == 0)
        #expect(section.state == .available)
        #expect(context.rootPath == repo.url.resolvingSymlinksInPath().path)
        #expect(context.branchName == "empty-child")
        #expect(context.headCommitID == head)
        #expect(context.recordedParentBranch == Self.parentBranch)
        #expect(context.baseBranchName == Self.parentBranch)
        #expect(context.resolvedRef == "refs/heads/\(Self.parentBranch)")
        #expect(context.baseCommitID == head)
        #expect(context.mergeBaseCommitID == head)
        #expect(summary.sections.dropLast().allSatisfy { $0.comparisonContext == nil })
        let applyingStats = summary.applying(stagedStats: [:], unstagedStats: [:])
        #expect(applyingStats.sections == summary.sections)
    }

    @Test(arguments: ["configuration", "graphite", "gh-stack"])
    func missingValidParentRetainsContextAndActionableWorkingChanges(source: String) async throws {
        let repo = try stackedRepository(prefix: "argus-base-missing-parent-context")
        defer { repo.remove() }
        switch source {
        case "configuration":
            try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        case "graphite":
            try writeBranchMetadata(
                repo: repo, branch: Self.childBranch, payload: #"{"parentBranchName":"\#(Self.parentBranch)"}"#)
        default:
            let data = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "stacks": [["trunk": ["branch": Self.parentBranch], "branches": [["branch": Self.childBranch]]]]
            ])
            try data.write(to: repo.url.appendingPathComponent(".git/gh-stack"))
        }
        try TestGit.run(["branch", "-D", Self.parentBranch], in: repo.url)
        try "working\n".write(to: repo.url.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let head = try TestGit.run(["rev-parse", "HEAD"], in: repo.url)
        let request = GitStatusRequest(
            rootPath: repo.url.path,
            presentation: GitStatusPresentation(showBaseBranchChanges: true, configuredBaseBranch: "main"))
        let service = GitStatusService()

        let summary = try loadedPresentationSummary(await service.status(request: request))
        let section = try #require(summary.sections.last)
        let context = try #require(section.comparisonContext)
        #expect(section.title == "Against \(Self.parentBranch)")
        #expect(!section.state.isAvailable)
        #expect(section.files.isEmpty)
        #expect(context.recordedParentBranch == Self.parentBranch)
        #expect(context.baseBranchName == Self.parentBranch)
        #expect(context.resolvedRef == nil)
        #expect(context.baseCommitID == nil)
        #expect(context.mergeBaseCommitID == nil)
        #expect(context.headCommitID == head)
        #expect(!summary.hasNoSectionContent)
        #expect(summary.unstagedCount == 1)
        #expect(summary.untrackedCount == 1)
        #expect(summary.sections.dropLast().allSatisfy { $0.state.isAvailable })

        let staged = try loadedPresentationSummary(
            await service.performFileOperation(.stage, request: request, path: "base.txt"))
        #expect(staged.stagedCount == 1)
        #expect(staged.unstagedCount == 0)
        #expect(staged.sections.last?.comparisonContext == context)
        #expect(!staged.againstBaseState.isAvailable)
    }

    @Test
    func cappedAgainstBaseRowsRetainSectionContextWhenWorkingChangesUseTheEntireLimit() async throws {
        let repo = try stackedRepository(prefix: "argus-base-capped-context")
        defer { repo.remove() }
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        for index in 0..<GitStatusSummary.displayFileLimit {
            try "new\n".write(
                to: repo.url.appendingPathComponent("untracked-\(index).txt"), atomically: true, encoding: .utf8)
        }

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        let section = try #require(summary.sections.last)
        let context = try #require(section.comparisonContext)
        #expect(summary.isFileDisplayCapped)
        #expect(section.files.isEmpty)
        #expect(section.totalCount == 1)
        #expect(section.state == .available)
        #expect(context.recordedParentBranch == Self.parentBranch)
        #expect(context.resolvedRef == "refs/heads/\(Self.parentBranch)")
        #expect(context.baseCommitID == (try TestGit.run(["rev-parse", Self.parentBranch], in: repo.url)))
        #expect(context.headCommitID == (try TestGit.run(["rev-parse", "HEAD"], in: repo.url)))
        #expect(summary.applying(stagedStats: [:], unstagedStats: [:]).sections.last == section)
    }

    @Test
    func missingMergeBaseRetainsResolvedParentTipAndChildHead() async throws {
        let repo = try stackedRepository(prefix: "argus-base-unrelated-context")
        defer { repo.remove() }
        let childHead = try TestGit.run(["rev-parse", "HEAD"], in: repo.url)
        try TestGit.run(["checkout", "--orphan", "unrelated-parent"], in: repo.url)
        try TestGit.run(["rm", "-rf", "."], in: repo.url)
        try "unrelated\n".write(to: repo.url.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try TestGit.run(["add", "other.txt"], in: repo.url)
        try TestGit.run(["commit", "-m", "unrelated history"], in: repo.url)
        let parentHead = try TestGit.run(["rev-parse", "HEAD"], in: repo.url)
        try TestGit.run(["switch", Self.childBranch], in: repo.url)
        try TestGit.run(["config", "branch.\(Self.childBranch).base", "unrelated-parent"], in: repo.url)

        let summary = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        let context = try #require(summary.sections.last?.comparisonContext)
        #expect(!summary.againstBaseState.isAvailable)
        #expect(context.recordedParentBranch == "unrelated-parent")
        #expect(context.resolvedRef == "refs/heads/unrelated-parent")
        #expect(context.baseCommitID == parentHead)
        #expect(context.headCommitID == childHead)
        #expect(context.mergeBaseCommitID == nil)
    }

    @Test
    func committedComparisonUsesTheCapturedPorcelainHeadRatherThanALaterCommit() throws {
        let repo = try stackedRepository(prefix: "argus-base-frozen-head")
        defer { repo.remove() }
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        let raw = GitStatusPorcelainParser.parseUncapped(
            try TestGit.run(["status", "--porcelain=v2", "--branch", "-z"], in: repo.url))
        let capturedHead = try #require(raw.headCommitID)
        try "later\n".write(to: repo.url.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
        try TestGit.run(["add", "later.txt"], in: repo.url)
        try TestGit.run(["commit", "-m", "later child commit"], in: repo.url)

        let result = buildAgainstBase(
            rootPath: repo.url.path,
            presentation: GitStatusPresentation(showBaseBranchChanges: true, configuredBaseBranch: "main"),
            currentBranch: raw.branchName, headCommitID: capturedHead)

        #expect(result.state == .available)
        #expect(result.files.map(\.path) == ["child.txt"])
        #expect(result.files.first?.additions == 1)
        #expect(result.files.first?.deletions == 0)
        #expect(result.context?.headCommitID == capturedHead)
        #expect(result.context?.headCommitID != (try TestGit.run(["rev-parse", "HEAD"], in: repo.url)))
    }

    @Test
    func squashMergeRequiresHistoryRepairAsWellAsLocalParentCorrection() async throws {
        let repo = try stackedRepository(prefix: "argus-base-squash-merge")
        defer { repo.remove() }
        let parentHead = try TestGit.run(["rev-parse", Self.parentBranch], in: repo.url)
        let childHead = try TestGit.run(["rev-parse", "HEAD"], in: repo.url)
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        try TestGit.run(["switch", "main"], in: repo.url)
        try TestGit.run(["merge", "--squash", Self.parentBranch], in: repo.url)
        try TestGit.run(["commit", "-m", "squash parent"], in: repo.url)
        let mainHead = try TestGit.run(["rev-parse", "main"], in: repo.url)
        try TestGit.run(["switch", Self.childBranch], in: repo.url)

        let original = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        #expect(original.sections.last?.title == "Against \(Self.parentBranch)")
        #expect(original.againstBaseFiles.map(\.path) == ["child.txt"])
        #expect(original.sections.last?.comparisonContext?.baseCommitID == parentHead)
        #expect(original.sections.last?.comparisonContext?.headCommitID == childHead)
        let againstMain = try TestGit.run(["diff", "main...HEAD", "--name-only"], in: repo.url)
        #expect(againstMain.components(separatedBy: "\n") == ["child.txt", "parent.txt"])
        #expect(try TestGit.run(["merge-base", Self.parentBranch, "main"], in: repo.url) != parentHead)

        try TestGit.run(["config", "branch.\(Self.childBranch).base", "main"], in: repo.url)
        let metadataOnly = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        #expect(metadataOnly.againstBaseFiles.map(\.path) == ["child.txt", "parent.txt"])
        try TestGit.run(["config", "branch.\(Self.childBranch).base", Self.parentBranch], in: repo.url)
        try TestGit.run(["rebase", "--onto", "main", Self.parentBranch, Self.childBranch], in: repo.url)
        let historyOnly = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        #expect(historyOnly.againstBaseFiles.map(\.path) == ["child.txt", "parent.txt"])
        #expect(historyOnly.sections.last?.comparisonContext?.recordedParentBranch == Self.parentBranch)

        try TestGit.run(["config", "branch.\(Self.childBranch).base", "main"], in: repo.url)
        let corrected = try await stackedSummary(repo: repo, configuredBaseBranch: "main")
        let context = try #require(corrected.sections.last?.comparisonContext)
        #expect(corrected.sections.last?.title == "Against main")
        #expect(corrected.againstBaseFiles.map(\.path) == ["child.txt"])
        #expect(corrected.isClean)
        #expect(context.baseCommitID == mainHead)
        #expect(context.mergeBaseCommitID == mainHead)
        #expect(context.recordedParentBranch == "main")
        #expect(context.headCommitID != childHead)
        #expect(try TestGit.run(["rev-parse", Self.parentBranch], in: repo.url) == parentHead)
    }
}
