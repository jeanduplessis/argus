import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspacePullRequestEvidenceTests {
    @Test
    func successfulPublicationCapturesValidatedContextWithoutExtraRequests() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        let repository = try #require(await fixture.provider.repositories[target.repositoryPath])
        let branch = PullRequestBranchContext(
            branchName: "feature-0", headCommitObjectID: String(repeating: "a", count: 40),
            upstreamRepository: repository, upstreamRemoteName: "origin", upstreamMergeReference: "refs/heads/feature-0"
        )
        await fixture.inputs.setBranch(branch, path: target.worktreePath)
        let status = PullRequestRuntimeFixture.status(
            branch: branch.branchName, repository: repository, lifecycle: .merged)
        await fixture.provider.setDiscovery(.success(status), branch: branch.branchName)

        await fixture.load()

        let evidence = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(evidence == fixture.model.evidence(for: target.workspaceID, at: fixture.clock.date))
        #expect(evidence.target == target)
        #expect(evidence.repository == repository)
        #expect(evidence.branch == branch)
        #expect(evidence.fetchRemotes == PullRequestRuntimeFixture.remotes(repository))
        #expect(evidence.status == status)
        #expect(evidence.validatedAt == fixture.clock.date)
        #expect(evidence.ownership.workspaceGeneration == fixture.model.entries[target.workspaceID]?.owner)
        #expect(evidence.ownership.projectGeneration == fixture.model.projects[target.projectID]?.owner)
        #expect(evidence.ownership.repositoryGeneration == fixture.model.projects[target.projectID]?.revision)
        #expect(evidence.ownership.observationGeneration == fixture.model.entries[target.workspaceID]?.observation)
        #expect(
            evidence.isExactHeadMerged(
                for: target, branchName: branch.branchName, headCommitID: branch.headCommitObjectID,
                at: fixture.clock.date))
        #expect(await fixture.provider.calls.map(\.method) == [.resolve, .discover, .batch])
    }

    @Test
    func pendingAutomaticRefreshDoesNotRestampTheLastSuccessfulEvidence() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let initial = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)

        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == previous)

        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.validatedAt == fixture.clock.date)
        #expect(refreshed.ownership.requestID != previous.ownership.requestID)
        #expect(refreshed.ownership.workspaceGeneration == previous.ownership.workspaceGeneration)
    }

    @Test
    func newerLocalHeadRetainsMergedAssociationButRequiresNewEvidenceAndRejectsMergedEligibility() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        let repository = try #require(await fixture.provider.repositories[target.repositoryPath])
        let merged = PullRequestRuntimeFixture.status(branch: "feature-0", repository: repository, lifecycle: .merged)
        await fixture.provider.setDiscovery(.success(merged), branch: "feature-0")
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let initial = await fixture.provider.calls.count
        let branch = PullRequestRuntimeFixture.branch("feature-0", head: String(repeating: "b", count: 40))
        await fixture.provider.suspend([.batch, .discover])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(initial + 1)
        await fixture.inputs.setBranch(branch, path: target.worktreePath)
        await fixture.provider.resume(initial)
        await fixture.provider.waitForCalls(initial + 2)

        #expect(fixture.model.state(for: target.workspaceID)?.status == merged)
        #expect(fixture.model.state(for: target.workspaceID)?.lastSuccess == previous.validatedAt)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        #expect(previous.validatedAt != fixture.clock.date)

        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.branch == branch)
        #expect(refreshed.status == merged)
        #expect(refreshed.ownership.observationGeneration != previous.ownership.observationGeneration)
        #expect(
            !refreshed.isExactHeadMerged(
                for: target, branchName: branch.branchName, headCommitID: branch.headCommitObjectID,
                at: fixture.clock.date))
        #expect(
            !refreshed.isExactHeadMerged(
                for: target, branchName: branch.branchName, headCommitID: merged.headCommitObjectID,
                at: fixture.clock.date))
    }

    @Test(arguments: [PullRequestStatusError.providerTimedOut, .invalidMetadata("Invalid status"), .ambiguous])
    func failedRefreshInvalidatesEvidenceWhileKeepingLastKnownStatus(error: PullRequestStatusError) async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        await fixture.provider.setRefresh(.failure(error), branch: "feature-0")
        fixture.clock.advance(60)
        await fixture.model.tick()

        #expect(fixture.model.state(for: target.workspaceID)?.status == previous.status)
        #expect(fixture.model.state(for: target.workspaceID)?.lastSuccess == previous.validatedAt)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        #expect(fixture.model.entries[target.workspaceID]?.evidence == nil)
    }

    @Test
    func evidenceExpiresAtTheExistingFreshnessBoundaryWithoutNetworking() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let calls = await fixture.provider.calls.count

        #expect(fixture.model.evidence(for: target, at: fixture.clock.date.addingTimeInterval(660)) == previous)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date.addingTimeInterval(660.1)) == nil)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date.addingTimeInterval(-1)) == nil)
        #expect(fixture.model.state(for: target.workspaceID)?.status == previous.status)
        #expect(await fixture.provider.calls.count == calls)
    }
}

extension WorkspacePullRequestEvidenceTests {
    @Test
    func foregroundRevalidationDoesNotCombineCachedStatusWithNewRepositoryGeneration() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let calls = await fixture.provider.calls.count
        fixture.update(selected: target.workspaceID, active: false)
        fixture.clock.advance(1)
        fixture.update(selected: target.workspaceID)
        await fixture.model.waitForIdle()

        #expect(fixture.model.state(for: target.workspaceID)?.status == previous.status)
        #expect(fixture.model.projects[target.projectID]?.revision != previous.ownership.repositoryGeneration)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        #expect(await fixture.provider.calls.count == calls)

        fixture.clock.advance(59)
        await fixture.model.tick()
        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.ownership.repositoryGeneration != previous.ownership.repositoryGeneration)
        #expect(refreshed.validatedAt == fixture.clock.date)
    }

    @Test
    func changedFetchRemotesImmediatelyRemoveEvidenceEvenWhenTheRepositoryStillMatches() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let calls = await fixture.provider.calls.count
        let remotes =
            previous.fetchRemotes + [
                GitFetchRemote(name: "extra", fetchURLs: ["https://github.example/extra/repo.git"])
            ]
        await fixture.inputs.setRemotes(remotes, path: target.repositoryPath)
        await fixture.provider.suspend([.resolve])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(calls + 1)

        #expect(fixture.model.state(for: target.workspaceID)?.status == previous.status)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)

        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.repository == previous.repository)
        #expect(Set(refreshed.fetchRemotes.map(\.name)) == Set(remotes.map(\.name)))
        #expect(refreshed.ownership.repositoryGeneration != previous.ownership.repositoryGeneration)
    }

    @Test(arguments: [false, true])
    func removedAndReaddedOwnershipRejectsLateEvidence(keepProject: Bool) async throws {
        let fixture = PullRequestRuntimeFixture(workspaceCount: keepProject ? 2 : 1)
        let target = fixture.targets[0]
        await fixture.load(selected: target.workspaceID)
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let calls = await fixture.provider.calls.count
        await fixture.provider.suspend([.batch])
        fixture.clock.advance(60)
        fixture.update(selected: target.workspaceID)
        await fixture.provider.waitForCalls(calls + 1)
        fixture.update(targets: Array(fixture.targets.dropFirst()))
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        fixture.update()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        let replacement = PullRequestRuntimeFixture.status(
            branch: "feature-0", repository: previous.repository, number: 99)
        await fixture.provider.setDiscovery(.success(replacement), branch: "feature-0")
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()

        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.status == replacement)
        #expect(refreshed.ownership.workspaceGeneration != previous.ownership.workspaceGeneration)
        #expect((refreshed.ownership.projectGeneration == previous.ownership.projectGeneration) == keepProject)
    }

    @Test
    func disableAndReenableCannotRestorePreviousEvidence() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        fixture.update(enabled: false)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        await fixture.provider.suspend([.resolve])
        fixture.update()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()

        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.ownership.workspaceGeneration != previous.ownership.workspaceGeneration)
        #expect(refreshed.ownership.projectGeneration != previous.ownership.projectGeneration)
    }

    @Test
    func getterRejectsWrongExpectedWorkspaceProjectAndPaths() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) != nil)
        let mismatches = [
            WorkspacePullRequestTarget(
                workspaceID: UUID(), projectID: target.projectID,
                repositoryPath: target.repositoryPath, worktreePath: target.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: target.workspaceID, projectID: UUID(),
                repositoryPath: target.repositoryPath, worktreePath: target.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: target.workspaceID, projectID: target.projectID,
                repositoryPath: "/other/project", worktreePath: target.worktreePath),
            WorkspacePullRequestTarget(
                workspaceID: target.workspaceID, projectID: target.projectID,
                repositoryPath: target.repositoryPath, worktreePath: "/other/worktree")
        ]
        for mismatch in mismatches {
            #expect(fixture.model.evidence(for: mismatch, at: fixture.clock.date) == nil)
        }
    }

    @Test(arguments: [false, true])
    func upstreamRefChangesInvalidateEvidenceEvenInsideTheSameRepository(changeRemote: Bool) async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        let repository = try #require(await fixture.provider.repositories[target.repositoryPath])
        let original = PullRequestBranchContext(
            branchName: "feature-0", headCommitObjectID: String(repeating: "a", count: 40),
            upstreamRepository: repository, upstreamRemoteName: "origin", upstreamMergeReference: "refs/heads/feature-0"
        )
        await fixture.inputs.setBranch(original, path: target.worktreePath)
        await fixture.load()
        let previous = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        let calls = await fixture.provider.calls.count
        let changed = PullRequestBranchContext(
            branchName: original.branchName, headCommitObjectID: original.headCommitObjectID,
            upstreamRepository: repository, upstreamRemoteName: changeRemote ? "alternate" : "origin",
            upstreamMergeReference: changeRemote ? original.upstreamMergeReference : "refs/heads/different")
        await fixture.inputs.setBranch(changed, path: target.worktreePath)
        await fixture.provider.suspend([.discover])
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.provider.waitForCalls(calls + 1)
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)
        #expect(await fixture.provider.calls.last?.previous == nil)

        await fixture.provider.resumeAll()
        await fixture.model.waitForIdle()
        let refreshed = try #require(fixture.model.evidence(for: target, at: fixture.clock.date))
        #expect(refreshed.branch == changed)
        #expect(refreshed.ownership.observationGeneration != previous.ownership.observationGeneration)
    }

    @Test
    func confirmedNoMatchAndLocalFailureRemoveEvidence() async throws {
        let fixture = PullRequestRuntimeFixture()
        let target = fixture.targets[0]
        await fixture.load()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) != nil)
        await fixture.provider.setDiscovery(.success(nil), branch: "feature-0")
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
        #expect(fixture.model.state(for: target.workspaceID)?.status == nil)

        let repository = try #require(await fixture.provider.repositories[target.repositoryPath])
        await fixture.provider.setDiscovery(
            .success(PullRequestRuntimeFixture.status(branch: "feature-0", repository: repository)), branch: "feature-0"
        )
        fixture.model.refresh(workspaceID: target.workspaceID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) != nil)
        await fixture.inputs.setUnavailable(.repositoryUnavailable("Detached HEAD"), path: target.worktreePath)
        fixture.model.refreshProject(projectID: target.projectID)
        await fixture.model.waitForIdle()
        #expect(fixture.model.evidence(for: target, at: fixture.clock.date) == nil)
    }
}
