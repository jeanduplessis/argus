import Foundation
import Testing

@testable import Argus

@Suite
struct StackComparisonAdvisoryTests {
    @Test(arguments: ["main", "parent"])
    func exactMergedParentTakesPrecedenceOverTheChildTarget(base: String) {
        let fixture = StackAdvisoryFixture()
        let result = StackComparisonAdvisoryResolver.resolve(
            target: fixture.child, comparison: fixture.comparison(), childEvidence: fixture.childEvidence(base: base),
            parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date)

        #expect(result?.kind == .parentMergedNeedsSync)
        #expect(result?.recordedParentBranch == "parent")
        #expect(result?.pullRequestBaseBranch == base)
        #expect(result?.mergedParentPullRequest == fixture.parentEvidence().status.identity)
    }

    @Test
    func childTargetMismatchDoesNotRequireAParentWorkspaceOrVisibleStackGroup() {
        let fixture = StackAdvisoryFixture()
        let result = StackComparisonAdvisoryResolver.resolve(
            target: fixture.child, comparison: fixture.comparison(), childEvidence: fixture.childEvidence(),
            at: fixture.date)

        #expect(result?.kind == .pullRequestTargetMismatch)
        #expect(result?.mergedParentPullRequest == nil)
        #expect(
            StackComparisonAdvisoryResolver.resolve(
                target: fixture.child, comparison: fixture.comparison(),
                childEvidence: fixture.childEvidence(base: "parent"), at: fixture.date) == nil)
    }

    @Test(arguments: [
        "repository", "project", "path", "branch", "localHead", "providerHead", "stale", "closed", "open"
    ])
    func unverifiableParentCannotTurnATargetMismatchIntoAMerge(problem: String) {
        let fixture = StackAdvisoryFixture()
        var evidence = fixture.parentEvidence()
        switch problem {
        case "repository":
            evidence = fixture.parentEvidence(
                repository: RepositoryIdentity(
                    provider: .github, host: "github.example", owner: "other", repositoryName: "repo"))
        case "project":
            evidence = fixture.parentEvidence(
                target: WorkspacePullRequestTarget(
                    workspaceID: fixture.parent.workspaceID, projectID: UUID(),
                    repositoryPath: fixture.parent.repositoryPath, worktreePath: fixture.parent.worktreePath))
        case "path":
            evidence = fixture.parentEvidence(
                target: WorkspacePullRequestTarget(
                    workspaceID: fixture.parent.workspaceID, projectID: fixture.parent.projectID,
                    repositoryPath: fixture.parent.repositoryPath, worktreePath: "/other/parent"))
        case "branch":
            evidence = fixture.parentEvidence(branch: "other-parent")
        case "localHead":
            evidence = fixture.parentEvidence(localHead: String(repeating: "d", count: 40))
        case "providerHead":
            evidence = fixture.parentEvidence(providerHead: String(repeating: "d", count: 40))
        case "stale":
            evidence = fixture.parentEvidence(at: fixture.date.addingTimeInterval(-661))
        case "closed":
            evidence = fixture.parentEvidence(lifecycle: .closed)
        default:
            evidence = fixture.parentEvidence(lifecycle: .open)
        }
        let result = StackComparisonAdvisoryResolver.resolve(
            target: fixture.child, comparison: fixture.comparison(), childEvidence: fixture.childEvidence(),
            parentTarget: fixture.parent, parentEvidence: evidence, at: fixture.date)

        #expect(result?.kind == .pullRequestTargetMismatch)
        #expect(result?.mergedParentPullRequest == nil)
    }

    @Test
    func changedParentTipAndDifferentResolvedReferenceCannotBeUsedAsMergedProof() {
        let fixture = StackAdvisoryFixture()
        for comparison in [
            fixture.comparison(parentHead: String(repeating: "e", count: 40)),
            fixture.comparison(resolvedRef: "refs/heads/main"),
            fixture.comparison(parentHead: nil, resolvedRef: nil)
        ] {
            let result = StackComparisonAdvisoryResolver.resolve(
                target: fixture.child, comparison: comparison, childEvidence: fixture.childEvidence(),
                parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date)
            #expect(result?.kind == .pullRequestTargetMismatch)
        }
    }

    @Test
    func parentEvidenceWithoutTheExpectedParentTargetIsNotMergedProof() {
        let fixture = StackAdvisoryFixture()
        let result = StackComparisonAdvisoryResolver.resolve(
            target: fixture.child, comparison: fixture.comparison(), childEvidence: fixture.childEvidence(),
            parentEvidence: fixture.parentEvidence(), at: fixture.date)
        #expect(result?.kind == .pullRequestTargetMismatch)
    }

    @Test
    func wrongExpectedChildOwnershipRejectsAllAdvisories() {
        let fixture = StackAdvisoryFixture()
        let targets = [
            WorkspacePullRequestTarget(
                workspaceID: UUID(), projectID: fixture.child.projectID,
                repositoryPath: fixture.child.repositoryPath, worktreePath: fixture.child.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: fixture.child.workspaceID, projectID: UUID(),
                repositoryPath: fixture.child.repositoryPath, worktreePath: fixture.child.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: fixture.child.workspaceID, projectID: fixture.child.projectID,
                repositoryPath: "/other/project", worktreePath: fixture.child.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: fixture.child.workspaceID, projectID: fixture.child.projectID,
                repositoryPath: fixture.child.repositoryPath, worktreePath: "/other/child")
        ]
        for target in targets {
            #expect(
                StackComparisonAdvisoryResolver.resolve(
                    target: target, comparison: fixture.comparison(), childEvidence: fixture.childEvidence(),
                    parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date) == nil)
        }
    }

    @Test
    func absentOrStaleChildEvidenceAndMismatchedLocalContextRejectAllAdvisories() {
        let fixture = StackAdvisoryFixture()
        for childEvidence in [nil, fixture.childEvidence(at: fixture.date.addingTimeInterval(-661))] {
            #expect(
                StackComparisonAdvisoryResolver.resolve(
                    target: fixture.child, comparison: fixture.comparison(), childEvidence: childEvidence,
                    parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date) == nil)
        }
        let contexts: [GitBaseComparisonContext?] = [
            nil,
            GitBaseComparisonContext(
                rootPath: "/other/child", branchName: "child", headCommitID: fixture.childHead,
                recordedParentBranch: "parent"),
            GitBaseComparisonContext(
                rootPath: fixture.child.worktreePath, branchName: "other", headCommitID: fixture.childHead,
                recordedParentBranch: "parent"),
            GitBaseComparisonContext(
                rootPath: fixture.child.worktreePath, branchName: "child",
                headCommitID: String(repeating: "f", count: 40), recordedParentBranch: "parent"),
            GitBaseComparisonContext(
                rootPath: fixture.child.worktreePath, branchName: "child", headCommitID: fixture.childHead),
            GitBaseComparisonContext(
                rootPath: fixture.child.worktreePath, branchName: "child", headCommitID: fixture.childHead,
                recordedParentBranch: "child")
        ]
        for context in contexts {
            #expect(
                StackComparisonAdvisoryResolver.resolve(
                    target: fixture.child, comparison: context, childEvidence: fixture.childEvidence(),
                    parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date) == nil)
        }
    }

    @Test(arguments: [false, true])
    func emptyOrUnavailableSectionsKeepTheSameVerifiedAdvisory(unavailable: Bool) {
        let fixture = StackAdvisoryFixture()
        let section = GitChangeSection(
            kind: .againstBase, title: "Against parent", totalCount: 0, files: [],
            state: unavailable ? .unavailable(message: "Comparison failed") : .available,
            comparisonContext: fixture.comparison())
        let result = StackComparisonAdvisoryResolver.resolve(
            target: fixture.child, comparison: section.comparisonContext, childEvidence: fixture.childEvidence(),
            parentTarget: fixture.parent, parentEvidence: fixture.parentEvidence(), at: fixture.date)
        #expect(result?.kind == .parentMergedNeedsSync)
    }

    @Test
    @MainActor
    func retainedMergedStatusAfterFailureOrDisableIsNotAdvisoryEvidence() async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: 2)
        let parent = fixture.targets[0]
        let child = fixture.targets[1]
        let repository = try #require(await fixture.provider.repositories[parent.repositoryPath])
        let merged = PullRequestRuntimeFixture.status(branch: "feature-0", repository: repository, lifecycle: .merged)
        await fixture.provider.setDiscovery(.success(merged), branch: "feature-0")
        await fixture.load(selected: parent.workspaceID)
        let comparison = GitBaseComparisonContext(
            rootPath: child.worktreePath, branchName: "feature-1", headCommitID: merged.headCommitObjectID,
            recordedParentBranch: "feature-0", baseBranchName: "feature-0", resolvedRef: "refs/heads/feature-0",
            baseCommitID: merged.headCommitObjectID, mergeBaseCommitID: merged.headCommitObjectID)
        func advisory() -> StackComparisonAdvisory? {
            StackComparisonAdvisoryResolver.resolve(
                target: child, comparison: comparison,
                childEvidence: fixture.model.evidence(for: child, at: fixture.clock.date),
                parentTarget: parent, parentEvidence: fixture.model.evidence(for: parent, at: fixture.clock.date),
                at: fixture.clock.date)
        }
        #expect(advisory()?.kind == .parentMergedNeedsSync)
        await fixture.provider.setRefresh(.failure(.invalidMetadata("Unverified result")), branch: "feature-0")
        fixture.clock.advance(60)
        await fixture.model.tick()
        #expect(fixture.model.state(for: parent.workspaceID)?.status == merged)
        #expect(advisory()?.kind == .pullRequestTargetMismatch)
        fixture.update(enabled: false)
        #expect(advisory() == nil)
    }
}

private struct StackAdvisoryFixture {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let repository = RepositoryIdentity(
        provider: .github, host: "github.example", owner: "owner", repositoryName: "repo")
    let childHead = String(repeating: "c", count: 40)
    let child: WorkspacePullRequestTarget
    let parent: WorkspacePullRequestTarget

    init() {
        let projectID = UUID()
        child = WorkspacePullRequestTarget(
            workspaceID: UUID(), projectID: projectID, repositoryPath: "/project", worktreePath: "/worktrees/child")
        parent = WorkspacePullRequestTarget(
            workspaceID: UUID(), projectID: projectID, repositoryPath: "/project", worktreePath: "/worktrees/parent")
    }

    func comparison(
        parentHead: String? = String(repeating: "a", count: 40), resolvedRef: String? = "refs/heads/parent"
    ) -> GitBaseComparisonContext {
        GitBaseComparisonContext(
            rootPath: child.worktreePath, branchName: "child", headCommitID: childHead,
            recordedParentBranch: "parent", baseBranchName: "parent", resolvedRef: resolvedRef,
            baseCommitID: parentHead, mergeBaseCommitID: parentHead)
    }

    func childEvidence(base: String = "main", at date: Date? = nil) -> WorkspacePullRequestEvidence {
        evidence(
            target: child, branch: PullRequestRuntimeFixture.branch("child", head: childHead),
            status: PullRequestRuntimeFixture.status(
                branch: "child", repository: repository, head: childHead, base: base),
            at: date ?? self.date)
    }

    func parentEvidence(
        target: WorkspacePullRequestTarget? = nil,
        branch: String = "parent",
        localHead: String = String(repeating: "a", count: 40),
        providerHead: String = String(repeating: "a", count: 40),
        repository: RepositoryIdentity? = nil,
        lifecycle: PullRequestLifecycle = .merged,
        at date: Date? = nil
    ) -> WorkspacePullRequestEvidence {
        evidence(
            target: target ?? parent, branch: PullRequestRuntimeFixture.branch(branch, head: localHead),
            status: PullRequestRuntimeFixture.status(
                branch: branch, repository: repository ?? self.repository, head: providerHead, lifecycle: lifecycle),
            at: date ?? self.date)
    }

    private func evidence(
        target: WorkspacePullRequestTarget, branch: PullRequestBranchContext, status: PullRequestStatus, at date: Date
    ) -> WorkspacePullRequestEvidence {
        WorkspacePullRequestEvidence(
            target: target, repository: status.identity.repository, branch: branch,
            fetchRemotes: PullRequestRuntimeFixture.remotes(status.identity.repository),
            ownership: WorkspacePullRequestEvidence.Ownership(
                workspaceGeneration: UUID(), projectGeneration: UUID(), repositoryGeneration: UUID(),
                observationGeneration: UUID(), requestID: UUID()),
            status: status, validatedAt: date)
    }
}
