import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackMaintenanceTests {
    @Test(arguments: ["missing", "head", "branch", "duplicate", "path", "unresolved"])
    func cleanupCandidateRejectsChangedOrAmbiguousStackBindings(_ change: String) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let head = String(repeating: "a", count: 40)
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: fixture.child, project: fixture.project, branchName: "feature/child", headCommitID: head))
        let valid = WorkspaceStackWorktree(
            path: candidate.target.worktreePath, branch: candidate.branchName, headCommitID: head)
        let validSnapshot = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory, worktrees: [valid], parents: [:])
        #expect(candidate.matchesStackSnapshot(validSnapshot))
        let changed = WorkspaceStackWorktree(
            path: change == "path" ? fixture.ordinary.currentDirectory : valid.path,
            branch: change == "branch" ? "feature/other" : valid.branch,
            headCommitID: change == "unresolved" ? nil : change == "head" ? String(repeating: "b", count: 40) : head)
        let snapshot = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: change == "duplicate" ? [changed, changed] : [changed], parents: [:])
        #expect(!candidate.matchesStackSnapshot(change == "missing" ? nil : snapshot))
    }

    @Test(arguments: [false, true])
    func cleanupRefreshWaitsForStackAndPullRequestResults(stackFinishesFirst: Bool) async throws {
        let fixture = try MergedCleanupRefreshFixture()
        defer { fixture.cleanup() }
        await fixture.prepare()
        await fixture.provider.suspend([.discover])
        let refresh = StackRefreshRequest {
            fixture.candidates = try await fixture.workspaces.manager.refreshMergedStackCandidates(
                in: [fixture.workspaces.child.id], projectID: fixture.workspaces.project.id,
                statusModel: fixture.model)
        }
        defer { refresh.cancel() }
        await waitForStackState { fixture.reader.requests.count == 3 }
        if stackFinishesFirst {
            fixture.reader.complete(2, with: .success(fixture.updatedSnapshot))
            await waitForStackState {
                fixture.workspaces.manager.workspaceStackSnapshots[fixture.workspaces.project.id]
                    == fixture.updatedSnapshot
            }
            #expect(refresh.result == nil)
            await fixture.provider.resumeAll()
        } else {
            await fixture.provider.resumeAll()
            await fixture.model.waitForIdle()
            #expect(fixture.model.evidence(for: fixture.target, at: .now)?.branch.headCommitObjectID == fixture.newHead)
            #expect(refresh.result == nil)
            fixture.reader.complete(2, with: .success(fixture.updatedSnapshot))
        }
        try await refresh.waitForCompletion()
        #expect(fixture.candidates.map(\.id) == [fixture.workspaces.child.id])
        #expect(fixture.candidates.first?.headCommitID == fixture.newHead)
    }

    @Test
    func mergedPrefixDisclosurePreservesTheOriginalProjection() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let group = try #require(fixture.manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        let order = fixture.orderedIds
        let presentation = WorkspaceStackMergedPresentation(
            group: group, verifiedMergedWorkspaceIDs: [fixture.parent.id], isExpanded: false
        )
        #expect(presentation.mergedWorkspaceIDs == [fixture.parent.id])
        #expect(presentation.hiddenWorkspaceIDs == [fixture.parent.id])
        #expect(group.rows.map(\.branch) == ["feature/parent", "feature/gap", "feature/child"])
        #expect(fixture.orderedIds == order)
        #expect(fixture.manager.workspaceShortcutDigit(for: fixture.parent.id) == 1)
        #expect(fixture.manager.workspaceShortcutDigit(for: fixture.child.id) == 2)
    }

    @Test
    func selectedAndRunningMembersRemainVisibleWithoutChangingThePrefix() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let group = try #require(fixture.manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        let presentation = WorkspaceStackMergedPresentation(
            group: group, verifiedMergedWorkspaceIDs: Set(group.workspaceIds),
            protectedWorkspaceIDs: [fixture.parent.id, fixture.child.id], isExpanded: false
        )
        #expect(presentation.mergedWorkspaceIDs == group.workspaceIds)
        #expect(presentation.hiddenWorkspaceIDs.isEmpty)
    }

    @Test
    func unknownOrUnmergedMemberEndsTheFoldedPrefix() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let group = try #require(fixture.manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        let presentation = WorkspaceStackMergedPresentation(
            group: group, verifiedMergedWorkspaceIDs: [fixture.child.id], isExpanded: false
        )
        #expect(presentation.mergedWorkspaceIDs.isEmpty)
        #expect(presentation.hiddenWorkspaceIDs.isEmpty)
    }

    @Test
    func evidenceLossOrExplicitExpansionRevealsMembers() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let group = try #require(fixture.manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        for (verified, expanded) in [(Set<UUID>(), false), (Set(group.workspaceIds), true)] {
            let presentation = WorkspaceStackMergedPresentation(
                group: group, verifiedMergedWorkspaceIDs: verified, isExpanded: expanded
            )
            #expect(presentation.hiddenWorkspaceIDs.isEmpty)
        }
    }

    @Test
    func closeBatchResolvesSelectionOnceUsingOriginalOrder() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let candidates = try [fixture.child, fixture.ordinary].map {
            try #require(
                MergedWorkspaceCloseCandidate(
                    workspace: $0, project: fixture.project, branchName: $0.branchName ?? "", headCommitID: "head"
                ))
        }
        fixture.manager.selectWorkspace(fixture.child.id)
        let revision = fixture.manager.workspaceRevealRevision
        #expect(fixture.manager.finishClosingMergedWorkspaces(candidates, validatingEvidence: { _ in true }))
        #expect(fixture.manager.selectedWorkspaceId == fixture.parent.id)
        #expect(fixture.manager.workspaceRevealRevision == revision + 1)
        #expect(fixture.manager.workspaceIds(for: fixture.project) == [fixture.parent.id])
    }

    @Test
    func staleEvidenceAndChangedPathsRejectTheWholeBatch() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let candidates = try [fixture.child, fixture.ordinary].map {
            try #require(
                MergedWorkspaceCloseCandidate(
                    workspace: $0, project: fixture.project, branchName: $0.branchName ?? "", headCommitID: "head"
                ))
        }
        let before = fixture.orderedIds
        #expect(!fixture.manager.finishClosingMergedWorkspaces(candidates) { $0.id != fixture.ordinary.id })
        #expect(fixture.orderedIds == before)
        fixture.ordinary.worktreePath = fixture.root.appendingPathComponent("changed").path
        #expect(!fixture.manager.finishClosingMergedWorkspaces(candidates, validatingEvidence: { _ in true }))
        #expect(Set(fixture.manager.workspaces.map(\.id)) == Set(before))
    }

    @Test
    func newlyRunningProcessPreventsClosure() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: fixture.child, project: fixture.project,
                branchName: "feature/child", headCommitID: "head"
            ))
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        terminal.surface.needsConfirmQuitOverride = true
        #expect(!fixture.manager.finishClosingMergedWorkspaces([candidate], validatingEvidence: { _ in true }))
        #expect(fixture.manager.workspaces.contains { $0 === fixture.child })
        #expect(fixture.child.panels[terminal.id] != nil)
    }

    @Test
    func replacementWorkspaceWithSameIDCannotBeClosedByAnOldRequest() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: fixture.child, project: fixture.project,
                branchName: "feature/child", headCommitID: "head"
            ))
        let replacement = Workspace(
            snapshot: WorkspaceSnapshot(
                id: fixture.child.id, projectId: fixture.project.id,
                branchName: fixture.child.branchName, workspaceType: .worktree,
                worktreePath: fixture.child.worktreePath, title: "Replacement", customTitle: nil,
                currentDirectory: fixture.child.currentDirectory, panelCount: 0
            ))
        fixture.manager.workspaces.removeAll { $0.id == replacement.id }
        fixture.manager.workspaces.append(replacement)
        #expect(!fixture.manager.finishClosingMergedWorkspaces([candidate], validatingEvidence: { _ in true }))
        #expect(fixture.manager.workspaces.contains { $0 === replacement })
    }

    @Test
    func closeOnlyRetainsDirtyFilesBranchAndRegisteredWorktree() async throws {
        let repository = try StackRepositoryFixture()
        let checkout = try repository.addWorktree(branch: "feature/retained")
        let dirtyFile = checkout.appendingPathComponent("uncommitted.txt")
        try Data("keep this work".utf8).write(to: dirtyFile)
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let project = Project(repositoryPath: repository.repository.path, mainBranch: "main")
        let workspace = Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: "feature/retained", workspaceType: .worktree,
                worktreePath: checkout.path, title: "Retained", customTitle: nil,
                currentDirectory: checkout.path, panelCount: 0
            ))
        fixture.manager.appendPlacement(workspace.id, to: nil)
        fixture.manager.projects.insert(project, at: 0)
        fixture.manager.workspaces.append(workspace)
        let originalHead = try TestGit.run(["rev-parse", "HEAD"], in: checkout)
        let originalRegistration = try TestGit.run(["worktree", "list", "--porcelain"], in: repository.repository)
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: workspace, project: project, branchName: "feature/retained", headCommitID: originalHead
            ))
        let inputs = try await WorktreePullRequestLocalInputProvider(worktreeService: fixture.manager.worktreeService)
            .readWorktree(target: candidate.target)
        let evidence = Self.closeEvidence(for: candidate, inputs: inputs)
        try await fixture.manager.closeMergedWorkspaces([candidate], evidence: { _ in evidence })
        #expect(try String(contentsOf: dirtyFile, encoding: .utf8) == "keep this work")
        #expect(try TestGit.run(["rev-parse", "feature/retained"], in: repository.repository) == originalHead)
        #expect(try TestGit.run(["worktree", "list", "--porcelain"], in: repository.repository) == originalRegistration)
        #expect(!fixture.manager.workspaces.contains { $0.id == workspace.id })
    }
}

@MainActor
private final class MergedCleanupRefreshFixture {
    static let initialHead = String(repeating: "a", count: 40)
    let newHead = String(repeating: "b", count: 40)
    let reader = ControlledWorkspaceStackReader()
    let workspaces: WorkspaceStackTestFixture
    let repository = RepositoryIdentity(
        provider: .github, host: "github.example", owner: "owner", repositoryName: "repo")
    let provider: PullRequestRuntimeProvider
    let inputs: PullRequestRuntimeInputs
    let model: WorkspacePullRequestStatusModel
    var candidates: [MergedWorkspaceCloseCandidate] = []

    var target: WorkspacePullRequestTarget {
        WorkspacePullRequestTarget(
            workspaceID: workspaces.child.id, projectID: workspaces.project.id,
            repositoryPath: workspaces.project.repositoryPath, worktreePath: workspaces.child.currentDirectory)
    }

    var updatedSnapshot: WorkspaceStackSnapshot { snapshot(childHead: newHead) }

    init() throws {
        workspaces = try WorkspaceStackTestFixture(reader: reader)
        let repositories = [workspaces.project.repositoryPath: repository]
        let branches: [String: PullRequestBranchContext] = Dictionary(
            uniqueKeysWithValues: workspaces.snapshot.worktrees.compactMap { worktree in
                guard let name = worktree.branch else { return nil }
                return (worktree.path, PullRequestRuntimeFixture.branch(name, head: Self.initialHead))
            })
        provider = PullRequestRuntimeProvider(repositories: repositories)
        inputs = PullRequestRuntimeInputs(branches: branches, repositories: repositories)
        model = WorkspacePullRequestStatusModel(
            provider: provider, localInputs: inputs, automaticallySchedules: false,
            hostBudgets: PullRequestStatusHostBudgetStore())
    }

    func prepare() async {
        workspaces.manager.startWorkspaceStackObservations()
        await waitForStackState { self.reader.requests.count == 1 }
        reader.complete(0, with: .success(snapshot(childHead: Self.initialHead)))
        await waitForStackState { self.reader.requests.count == 2 }
        reader.complete(1, with: .success(snapshot(childHead: Self.initialHead)))
        await waitForStackState {
            !self.workspaces.manager.refreshingWorkspaceStackProjectIds.contains(self.workspaces.project.id)
        }
        model.update(
            targets: workspaces.manager.pullRequestStatusTargets, selectedWorkspaceID: workspaces.child.id,
            isEnabled: true, isActive: true)
        await model.waitForIdle()
        await inputs.setBranch(
            PullRequestRuntimeFixture.branch("feature/child", head: newHead), path: target.worktreePath)
        let merged = PullRequestRuntimeFixture.status(
            branch: "feature/child", repository: repository, head: newHead, lifecycle: .merged)
        await provider.setDiscovery(.success(merged), branch: "feature/child")
    }

    func cleanup() {
        model.stop()
        workspaces.cleanup()
        reader.cancelAll()
    }

    private func snapshot(childHead: String) -> WorkspaceStackSnapshot {
        WorkspaceStackSnapshot(
            gitCommonDirectory: workspaces.snapshot.gitCommonDirectory,
            worktrees: workspaces.snapshot.worktrees.map {
                WorkspaceStackWorktree(
                    path: $0.path, branch: $0.branch,
                    headCommitID: $0.path == workspaces.child.currentDirectory ? childHead : Self.initialHead)
            },
            parents: workspaces.snapshot.parents)
    }
}
