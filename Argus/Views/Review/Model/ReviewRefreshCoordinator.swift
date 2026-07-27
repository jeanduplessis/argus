import Foundation

@MainActor
final class ReviewRefreshCoordinator {
    private struct InboxOwner: Hashable {
        let host: String
        let account: String
    }

    private var inboxGeneration = 0
    private var activeInboxOwner: InboxOwner?
    private var tabGenerations: [PullRequestIdentity: UInt64] = [:]
    private var activeRefreshes = 0

    func nextInboxGeneration() -> Int {
        inboxGeneration += 1
        activeInboxOwner = nil
        return inboxGeneration
    }

    func acceptsInbox(host: String, account: String, generation: Int, selectedHost: String) -> Bool {
        let owner = InboxOwner(host: host, account: account)
        guard generation == inboxGeneration, host == selectedHost, !host.isEmpty, !account.isEmpty else {
            return false
        }
        activeInboxOwner = owner
        return activeInboxOwner == owner
    }

    func nextTabGeneration(for identity: PullRequestIdentity) -> UInt64 {
        let generation = (tabGenerations[identity] ?? 0) + 1
        tabGenerations[identity] = generation
        return generation
    }

    func currentTabGeneration(for identity: PullRequestIdentity) -> UInt64 {
        tabGenerations[identity] ?? 0
    }

    func isCurrentInboxGeneration(_ generation: Int) -> Bool {
        generation == inboxGeneration
    }

    func beginRefresh() -> Bool {
        activeRefreshes += 1
        return true
    }

    func endRefresh() -> Bool {
        activeRefreshes = max(activeRefreshes - 1, 0)
        return activeRefreshes > 0
    }
}

enum ReviewRemoteCachePolicy {
    static func hydrating(_ tab: inout ReviewTabState, from cache: ReviewRemoteCache, loadState: ReviewLoadState) {
        tab.revision = cache.revision
        if tab.pendingReviewRequiresExplicitRevisionAdoption {
            tab.preserveUnboundPendingReviewForRemap()
        } else {
            tab.pendingReview.revision = tab.pendingReview.revision ?? cache.revision
        }
        tab.changedFiles = cache.changedFiles
        tab.conversations = cache.conversations
        tab.activity = cache.activity
        tab.checks = cache.checks
        tab.selectedFilePath =
            cache.changedFiles.contains(where: { $0.path == tab.selectedFilePath })
            ? tab.selectedFilePath : cache.changedFiles.first?.path
        tab.lastSuccessfulRefresh = cache.savedAt
        tab.loadState = loadState
    }

    static func canApply(
        _ cache: ReviewRemoteCache,
        to tab: ReviewTabState,
        expectedRevision: ReviewRevision? = nil
    ) -> Bool {
        if let expectedRevision { return cache.revision == expectedRevision }
        let revision = tab.revision ?? tab.pendingReview.revision
        guard let revision else { return false }
        return cache.revision == revision
            && (tab.pendingReview.revision == nil || tab.pendingReview.revision == cache.revision)
    }

    static func usableLoadStateBeforeOpen(_ tab: ReviewTabState) -> ReviewLoadState {
        switch tab.loadState {
        case .loaded, .stale:
            tab.loadState
        case .refreshing:
            tab.changedFiles.isEmpty ? .failed : .loaded
        case .initialLoading, .failed, .blocked:
            .failed
        }
    }
}
