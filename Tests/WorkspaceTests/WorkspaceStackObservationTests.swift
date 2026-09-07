import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackObservationTests {
    @Test
    func initialReadIsReplacedByPostWatchInventoryWithoutAnotherEvent() async throws {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        fixture.start()
        await waitForStackState { fixture.reader.requests.count == 1 }
        let changed = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: [WorkspaceStackWorktree(path: "/checkout", branch: "changed-before-watch")],
            parents: ["changed-before-watch": "main", "dependent": "changed-before-watch"]
        )
        let refresh = StackRefreshRequest {
            try await fixture.observation.refreshAndWait()
            #expect(fixture.results == [changed])
            #expect(fixture.refreshing.last == false)
        }
        await waitForStackState { refresh.hasStarted }
        #expect(fixture.watcher.startedPaths.isEmpty)
        await fixture.complete(0, with: fixture.snapshot)
        await waitForStackState { fixture.reader.requests.count == 2 }
        #expect(fixture.watcher.startedPaths == [fixture.snapshot.gitCommonDirectory])
        #expect(fixture.results.isEmpty)
        #expect(refresh.result == nil)
        #expect(fixture.refreshing.allSatisfy { $0 })
        await fixture.complete(1, with: changed)
        try await refresh.waitForCompletion()
        #expect(fixture.results == [changed])
        #expect(fixture.refreshing.last == false)
        #expect(fixture.reader.requests.count == 2)
        #expect(fixture.scheduler.operation == nil)
    }

    @Test
    func watchesAbsentMetadataAndFiltersIndexNoise() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        #expect(fixture.watcher.startedPaths == [fixture.snapshot.gitCommonDirectory])
        let common = fixture.snapshot.gitCommonDirectory
        fixture.watcher.emit([
            common + "/index", common + "/index.lock", common + "/worktrees/feature/index",
            common + "/objects/ab/cdef", common + "/gh-stack.lock", common + "-other/HEAD"
        ])
        #expect(fixture.scheduler.delays.isEmpty)
        let relevant = [
            "gh-stack", "HEAD", "refs/heads/feature", "packed-refs", "logs/HEAD", "worktrees",
            "worktrees/feature", "worktrees/feature/gitdir", "worktrees/feature/commondir",
            "worktrees/feature/HEAD", "worktrees/feature/gh-stack"
        ]
        for path in relevant { fixture.watcher.emit([common + "/" + path]) }
        #expect(fixture.scheduler.delays == Array(repeating: 0.3, count: relevant.count))
        await fixture.scheduler.runScheduled()
        await waitForStackState { fixture.reader.requests.count == 3 }
        await fixture.complete(2, with: fixture.snapshot)
        #expect(fixture.results.count == 2)
    }

    @Test(arguments: [false, true])
    func eventsAndExplicitRequestsCoalesceDuringAnInFlightLoad(_ olderReadFails: Bool) async throws {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        fixture.observation.refresh()
        await waitForStackState { fixture.reader.requests.count == 3 }
        let refreshes = (0..<2).map { _ in
            StackRefreshRequest { try await fixture.observation.refreshAndWait() }
        }
        await waitForStackState { refreshes.allSatisfy(\.hasStarted) }
        for _ in 0..<4 {
            fixture.watcher.emit([fixture.snapshot.gitCommonDirectory + "/gh-stack"])
            fixture.observation.refresh()
        }
        #expect(fixture.reader.requests.count == 3)
        let obsolete = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Superseded result"]
        )
        fixture.reader.complete(
            2, with: olderReadFails ? .failure(StackObservationError.unavailable) : .success(obsolete))
        await waitForStackState { fixture.reader.requests.count == 4 }
        #expect(fixture.results == [fixture.snapshot])
        #expect(refreshes.allSatisfy { $0.result == nil })
        #expect(fixture.refreshing.last == true)
        await fixture.complete(3, with: fixture.snapshot)
        for refresh in refreshes { try await refresh.waitForCompletion() }
        await fixture.scheduler.runScheduled()
        #expect(fixture.reader.requests.count == 4)
        #expect(fixture.results == [fixture.snapshot, fixture.snapshot])
        #expect(fixture.refreshing.last == false)
    }

    @Test(arguments: [0, 1])
    func cancellingOneAwaiterPreservesSharedFreshRead(_ cancelledIndex: Int) async throws {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        let first = StackRefreshRequest { try await fixture.observation.refreshAndWait() }
        await waitForStackState { fixture.reader.requests.count == 3 }
        let second = StackRefreshRequest { try await fixture.observation.refreshAndWait() }
        await waitForStackState { second.hasStarted }
        let refreshes = [first, second]
        refreshes[cancelledIndex].cancel()
        await #expect(throws: CancellationError.self) {
            try await refreshes[cancelledIndex].waitForCompletion()
        }
        let remaining = refreshes[1 - cancelledIndex]
        #expect(remaining.result == nil)
        #expect(!fixture.reader.completed.contains(2))
        await fixture.complete(2, with: fixture.snapshot)
        await waitForStackState { fixture.reader.requests.count == 4 }
        #expect(remaining.result == nil)
        await fixture.complete(3, with: fixture.snapshot)
        try await remaining.waitForCompletion()
        #expect(fixture.reader.requests.count == 4)
        #expect(fixture.results == [fixture.snapshot, fixture.snapshot])
        #expect(fixture.refreshing.last == false)
    }

    @Test
    func cancellationBeforeAwaitedRefreshDoesNotScheduleRead() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        let refresh = StackRefreshRequest { try await fixture.observation.refreshAndWait() }
        refresh.cancel()
        await #expect(throws: CancellationError.self) { try await refresh.waitForCompletion() }
        #expect(fixture.reader.requests.count == 2)
        #expect(fixture.refreshing.last == false)
    }

    @Test(arguments: [false, true])
    func awaitedRefreshRejectsInactiveObservation(_ previouslyStarted: Bool) async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        if previouslyStarted {
            await fixture.startAndLoad()
            fixture.observation.stop()
        }
        let refresh = StackRefreshRequest { try await fixture.observation.refreshAndWait() }
        await #expect(throws: CancellationError.self) { try await refresh.waitForCompletion() }
        #expect(fixture.reader.requests.count == (previouslyStarted ? 2 : 0))
    }

    @Test
    func restartDiscardsLateLoadsAndCancelledScheduledCallbacks() async {
        let fixture = StackObservationFixture()
        defer { fixture.stop() }
        await fixture.startAndLoad()
        fixture.watcher.emit([fixture.snapshot.gitCommonDirectory + "/gh-stack"])
        let staleOperation = fixture.scheduler.operation
        let staleEvents = fixture.watcher.onEvents
        fixture.observation.refresh()
        await waitForStackState { fixture.reader.requests.count == 3 }
        fixture.observation.stop()
        fixture.start()
        await waitForStackState { fixture.reader.requests.count == 4 }
        let current = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees, parents: fixture.snapshot.parents,
            diagnostics: ["Current diagnostic"]
        )
        await fixture.complete(3, with: current)
        await waitForStackState { fixture.reader.requests.count == 5 }
        #expect(fixture.results == [fixture.snapshot])
        await fixture.complete(4, with: current)
        await fixture.complete(2, with: fixture.snapshot)
        await staleOperation?()
        staleEvents?([fixture.snapshot.gitCommonDirectory + "/HEAD"])
        #expect(fixture.results == [fixture.snapshot, current])
        #expect(fixture.reader.requests.count == 5)
        #expect(fixture.scheduler.operation == nil)
        #expect(fixture.watcher.stopCount == 1)
    }
}
