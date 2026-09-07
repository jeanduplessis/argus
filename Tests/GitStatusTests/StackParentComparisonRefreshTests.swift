import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct StackParentComparisonRefreshTests {
    @Test(.timeLimit(.minutes(1)))
    func metadataEditSupersedesAnAlreadyRunningComparison() async {
        let service = SuspendedMetadataRefreshService()
        let model = GitStatusViewModel(service: service)
        let owner = GitStatusSnapshotOwner(workspaceId: UUID(), request: GitStatusRequest(rootPath: "/tmp/worktree"))
        let original = Task { await model.refresh(owner: owner) }
        await service.waitForRequests(1)
        let repaired = Task {
            await model.refreshAfterLocalMetadataChange(workspaceId: owner.workspaceId, rootPath: owner.rootPath)
        }
        await service.waitForRequests(2)
        let current = GitStatusLoadState.loaded(summary(base: "main"))
        await service.complete(1, with: current)
        await repaired.value
        await service.complete(0, with: .loaded(summary(base: "merged-parent")))
        await original.value
        #expect(model.state == current)
        #expect(model.ownsSnapshot(owner))
        #expect(!model.isRefreshing)
    }

    @Test
    func metadataEditDoesNotClaimAnotherWorkspaceOrRoot() async {
        let state = GitStatusLoadState.loaded(summary(base: "parent"))
        let service = FakeStatusService(result: state)
        let model = GitStatusViewModel(service: service)
        let owner = GitStatusSnapshotOwner(workspaceId: UUID(), request: GitStatusRequest(rootPath: "/tmp/worktree"))
        await model.refresh(owner: owner)
        await model.refreshAfterLocalMetadataChange(workspaceId: UUID(), rootPath: owner.rootPath)
        await model.refreshAfterLocalMetadataChange(workspaceId: owner.workspaceId, rootPath: "/tmp/other")
        #expect(service.requestedRoots == [owner.rootPath])
        #expect(model.ownsSnapshot(owner))
        #expect(model.state == state)
    }

    private func summary(base: String) -> GitStatusSummary {
        GitStatusSummary(
            rootPath: "/tmp/worktree", branchName: "child", upstreamName: nil,
            aheadCount: 0, behindCount: 0,
            sections: [
                GitChangeSection(
                    kind: .againstBase, title: "Against \(base)", totalCount: 0, files: [], state: .available)
            ]
        )
    }
}

private actor SuspendedMetadataRefreshService: GitStatusProviding {
    private var nextRequest = 0
    private var requests: [Int: CheckedContinuation<GitStatusLoadState, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func status(rootPath: String) async -> GitStatusLoadState {
        let index = nextRequest
        nextRequest += 1
        return await withCheckedContinuation { continuation in
            requests[index] = continuation
            let ready = waiters.filter { $0.0 <= nextRequest }
            waiters.removeAll { $0.0 <= nextRequest }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        guard nextRequest < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int, with result: GitStatusLoadState) {
        requests.removeValue(forKey: index)?.resume(returning: result)
    }

    func initializeRepository(rootPath: String) async -> GitStatusLoadState { .idle }

    func performFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, path: String
    ) async -> GitStatusLoadState { .idle }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation, rootPath: String, paths: [String]
    ) async -> GitStatusLoadState { .idle }
}
