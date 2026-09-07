import Foundation
import Testing

@testable import Argus

extension WorkspaceStackObservationTests {
    @Test
    func managerStartsExplicitlyAndDiscardsRemovedProjectResults() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        for projectId in [fixture.project.id, UUID()] {
            let refresh = StackRefreshRequest { try await fixture.manager.refreshWorkspaceStacksAndWait(in: projectId) }
            await #expect(throws: CancellationError.self) { try await refresh.waitForCompletion() }
        }
        #expect(reader.requests.isEmpty)
        fixture.manager.startWorkspaceStackObservations()
        await waitForStackState { reader.requests.count == 1 }
        #expect(reader.requests == [fixture.project.repositoryPath])
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds == [fixture.project.id])
        _ = try fixture.adoptGapWorkspace()
        #expect(fixture.manager.pendingWorkspaceStackReveal != nil)
        for workspace in fixture.manager.workspaces { workspace.worktreePath = nil }
        await fixture.manager.removeProject(fixture.project.id)
        #expect(fixture.manager.pendingWorkspaceStackReveal == nil)
        reader.complete(0, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(0) }
        #expect(fixture.manager.workspaceStackSnapshots[fixture.project.id] == nil)
        #expect(fixture.manager.workspaceStackErrors[fixture.project.id] == nil)
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds.isEmpty)
        #expect(fixture.manager.workspaceStackObservations[fixture.project.id] == nil)
        let addedProject = Project(
            repositoryPath: fixture.root.appendingPathComponent("added").path, mainBranch: "main")
        fixture.manager.projects.insert(addedProject, at: 0)
        await waitForStackState { reader.requests.count == 2 }
        #expect(reader.requests.last == addedProject.repositoryPath)
        #expect(fixture.manager.refreshingWorkspaceStackProjectIds == [addedProject.id])
    }

    @Test
    func restoredProjectIdentityRejectsOldCompletions() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        manager.startWorkspaceStackObservations()
        await waitForStackState { reader.requests.count == 1 }
        let replacedRefresh = StackRefreshRequest {
            try await manager.refreshWorkspaceStacksAndWait(in: fixture.project.id)
        }
        await waitForStackState { replacedRefresh.hasStarted }
        #expect(manager.restoreSession(from: manager.makeSessionSnapshot()))
        await #expect(throws: CancellationError.self) { try await replacedRefresh.waitForCompletion() }
        await waitForStackState { reader.requests.count == 2 }
        #expect(manager.projects.first !== fixture.project)
        let current = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Replacement Project"]
        )
        reader.complete(1, with: .success(current))
        await waitForStackState { reader.requests.count == 3 }
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == nil)
        reader.complete(2, with: .success(current))
        await waitForStackState { manager.workspaceStackSnapshots[fixture.project.id] == current }
        reader.complete(0, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(0) }
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == current)
    }

    @Test
    func stoppingManagerRejectsAwaitedRefreshAndLateResults() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        await reader.startAndLoad(fixture)
        let workspace = try #require(
            manager.adoptOrphanedWorktree(
                OrphanedWorktreeInfo(
                    path: fixture.root.appendingPathComponent("gap").path,
                    branchName: "feature/gap", projectId: fixture.project.id)
            ))
        await waitForStackState { reader.requests.count == 3 }
        #expect(manager.pendingWorkspaceStackReveal?.workspaceId == workspace.id)
        let stoppedRefresh = StackRefreshRequest {
            try await manager.refreshWorkspaceStacksAndWait(in: fixture.project.id)
        }
        await waitForStackState { stoppedRefresh.hasStarted }
        manager.stopWorkspaceStackObservations()
        await #expect(throws: CancellationError.self) { try await stoppedRefresh.waitForCompletion() }
        #expect(manager.pendingWorkspaceStackReveal == nil)
        reader.complete(2, with: .success(fixture.snapshot))
        await waitForStackState { reader.completed.contains(2) }
        manager.refreshWorkspaceStacks(in: fixture.project.id)
        #expect(manager.workspaceStackSnapshots.isEmpty)
        #expect(manager.workspaceStackErrors.isEmpty)
        #expect(manager.refreshingWorkspaceStackProjectIds.isEmpty)
        #expect(reader.requests.count == 3)
    }

    @Test
    func awaitedProjectRefreshRejectsObservationReplacedDuringPublication() async throws {
        let discovery = StackObservationFixture()
        let replacement = StackObservationFixture()
        let fixture = try WorkspaceStackTestFixture(reader: discovery.reader)
        defer {
            fixture.cleanup()
            discovery.stop()
            replacement.stop()
        }
        let manager = fixture.manager
        let project = fixture.project
        manager.isObservingWorkspaceStacks = true
        manager.workspaceStackObservations[project.id] = (project, discovery.observation)
        discovery.observation.start(
            onRefreshing: { _ in },
            onResult: { result in
                if case .success(let snapshot) = result { manager.workspaceStackSnapshots[project.id] = snapshot }
                manager.workspaceStackObservations[project.id] = (project, replacement.observation)
            }
        )
        await waitForStackState { discovery.reader.requests.count == 1 }
        let refresh = StackRefreshRequest { try await manager.refreshWorkspaceStacksAndWait(in: project.id) }
        await waitForStackState { refresh.hasStarted }
        await discovery.complete(0, with: discovery.snapshot)
        await waitForStackState { discovery.reader.requests.count == 2 }
        #expect(refresh.result == nil)
        await discovery.complete(1, with: discovery.snapshot)
        await #expect(throws: CancellationError.self) { try await refresh.waitForCompletion() }
        #expect(manager.workspaceStackSnapshots[project.id] == discovery.snapshot)
        #expect(manager.workspaceStackObservations[project.id]?.observation === replacement.observation)
    }

    @Test
    func refreshKeepsOrderDisclosureAndSelectionAndFallsBackOnIssues() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        let project = fixture.project
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: project.id))
        fixture.collapsedStackIds = [group.id]
        fixture.isExpanded = false
        fixture.child.customTitle = "Keep this title"
        let order = fixture.manualOrder
        let selection = manager.selectedWorkspaceId
        let revision = manager.workspaceRevealRevision
        await reader.startAndLoad(fixture)
        #expect(fixture.parent.branchName == "feature/parent")
        #expect(fixture.child.branchName == "feature/child")
        #expect(fixture.child.customTitle == "Keep this title")
        #expect(fixture.child.title == "stored-child")
        let refresh = StackRefreshRequest { try await manager.refreshWorkspaceStacksAndWait(in: project.id) }
        await waitForStackState { reader.requests.count == 3 }
        #expect(manager.stackGroup(for: fixture.child.id, in: project.id) == group)
        let unavailable = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: [:],
            conflicts: ["feature/parent": "Conflicting local tracking"]
        )
        reader.complete(2, with: .success(unavailable))
        try await refresh.waitForCompletion()
        #expect(manager.workspaceStackErrors[project.id] == unavailable.issue)
        #expect(manager.sidebarItems(for: project) == order.map { .workspace($0) })
        let failedRefresh = StackRefreshRequest { try await manager.refreshWorkspaceStacksAndWait(in: project.id) }
        await waitForStackState { reader.requests.count == 4 }
        reader.complete(3, with: .failure(StackObservationError.unavailable))
        await #expect(throws: StackObservationError.self) { try await failedRefresh.waitForCompletion() }
        #expect(manager.workspaceStackSnapshots[project.id] == nil)
        #expect(manager.workspaceStackErrors[project.id] == "Stack discovery unavailable")
        #expect(manager.sidebarItems(for: project) == order.map { .workspace($0) })
        manager.refreshWorkspaceStacks(in: project.id)
        await waitForStackState { reader.requests.count == 5 }
        reader.complete(4, with: .success(fixture.snapshot))
        await waitForStackState { manager.workspaceStackErrors[project.id] == nil }
        #expect(manager.stackGroup(for: fixture.child.id, in: project.id) == group)
        #expect(fixture.manualOrder == order)
        #expect(fixture.collapsedStackIds == [group.id])
        #expect(!fixture.isExpanded)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == revision)
    }

    @Test
    func awaitedProjectRefreshPublishesReadFailureBeforeReturning() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        let project = fixture.project
        await reader.startAndLoad(fixture)
        let failedRefresh = StackRefreshRequest {
            do {
                try await manager.refreshWorkspaceStacksAndWait(in: project.id)
            } catch {
                #expect(manager.workspaceStackSnapshots[project.id] == nil)
                #expect(manager.workspaceStackErrors[project.id] == "Stack discovery unavailable")
                throw error
            }
        }
        await waitForStackState { reader.requests.count == 3 }
        reader.complete(2, with: .failure(StackObservationError.unavailable))
        await #expect(throws: StackObservationError.self) { try await failedRefresh.waitForCompletion() }
    }

    @Test(arguments: [false, true])
    func unavailableInventoryCancelsPendingRevealBeforeRetry(_ metadataIssue: Bool) async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        await reader.startAndLoad(fixture)
        let manager = fixture.manager
        _ = try fixture.adoptGapWorkspace()
        await waitForStackState { reader.requests.count == 3 }
        let unavailable = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshotIncludingGap.worktrees, parents: [:],
            diagnostics: ["Unavailable local tracking"]
        )
        reader.complete(2, with: metadataIssue ? .success(unavailable) : .failure(StackObservationError.unavailable))
        await waitForStackState { manager.workspaceStackErrors[fixture.project.id] != nil }
        #expect(manager.pendingWorkspaceStackReveal == nil)
        let revision = manager.workspaceRevealRevision
        manager.refreshWorkspaceStacks(in: fixture.project.id)
        await waitForStackState { reader.requests.count == 4 }
        reader.complete(3, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { !manager.refreshingWorkspaceStackProjectIds.contains(fixture.project.id) }
        #expect(fixture.collapsedStackIds == [fixture.stackId])
        #expect(manager.workspaceRevealRevision == revision)
    }
}
