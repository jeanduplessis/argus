import Combine
import Foundation
import Testing
@testable import Argus
@Suite
@MainActor
struct ReviewWorkModeModelTests {
    private let identity = PullRequestIdentity(
        repository: .init(host: "github.com", owner: "argus", name: "app"),
        number: 42
    )
    @Test
    func completeRefreshLoadsOneImmutableRevision() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.loadState == .loaded)
        #expect(model.tab(tab.id)?.revision == .init(baseCommit: "base", headCommit: "head"))
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Source.swift"])
    }
    @Test
    func completeRefreshUsesAuthoritativeRemoteViewedState() async {
        let provider = ReviewProviderFake(identity: identity, changedFiles: [
            .init(path: "Viewed.swift", viewedState: .viewed),
            .init(path: "Unviewed.swift", viewedState: .unviewed)
        ])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)

        await model.refreshTab(tabID: tab.id)

        #expect(model.tab(tab.id)?.changedFiles.map(\.viewedState) == [.viewed, .unviewed])
    }
    @Test
    func completeRefreshPreservesPendingViewedIntentOverRemoteState() async {
        let provider = ReviewProviderFake(identity: identity, viewedFailure: .network("offline"), changedFiles: [
            .init(path: "Source.swift", viewedState: .unviewed)
        ])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        await model.refreshTab(tabID: tab.id)
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await waitForError(in: model)

        await model.refreshTab(tabID: tab.id)

        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .pendingViewed)
    }

    @Test
    func restoredFailedViewedIntentOverlaysMatchingCacheWithoutAutoPublishing() async throws {
        let sessionStore = try temporarySessionStore()
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let restored = ReviewTabState(
            pullRequest: identity,
            revision: revision,
            pendingViewedIntents: [.init(revision: revision, path: "Source.swift", viewed: true)]
        )
        try await sessionStore.writeRemoteCache(.init(
            pullRequest: identity,
            revision: revision,
            changedFiles: [.init(path: "Source.swift")],
            conversations: [], activity: [],
            checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now
        ))
        let provider = ReviewProviderFake(identity: identity, failure: .network("offline"))
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: provider,
            restoreSession: { .init(tabs: [restored]) }
        )

        await model.restore()
        #expect(await provider.providerWriteCount() == 0)
        await model.refreshTab(tabID: restored.id)

        #expect(model.tab(restored.id)?.changedFiles.first?.viewedState == .pendingViewed)
        #expect(model.tab(restored.id)?.pendingViewedIntents.count == 1)
        #expect(await provider.providerWriteCount() == 0)
    }

    @Test
    func mismatchedViewedIntentDoesNotOverlayOrPublishUntilExplicitlyReplaced() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let current = ReviewRevision(baseCommit: "base", headCommit: "current")
        model.mutateTab(tab.id) {
            $0.revision = current
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.pendingViewedIntents = [.init(
                revision: .init(baseCommit: "base", headCommit: "old"), path: "Source.swift", viewed: true
            )]
            $0.overlayPendingViewedIntents()
            $0.loadState = .loaded
        }

        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .unviewed)
        #expect(model.tab(tab.id)?.pendingViewedIntents.count == 1)
        #expect(await provider.providerWriteCount() == 0)
    }
    @Test
    func unrelatedInboxAndTabRefreshesCompose() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        async let inbox: Void = model.refreshInbox()
        async let refresh: Void = model.refreshTab(tabID: tab.id)
        _ = await (inbox, refresh)
        #expect(model.store.session.pullRequests.contains { $0.identity == identity })
        #expect(model.tab(tab.id)?.loadState == .loaded)
    }
    @Test
    func providerFailureUsesMatchingCacheAsStaleContentAndFailsWithoutCache() async throws {
        let sessionStore = try temporarySessionStore()
        let cached = ReviewRemoteCache(
            pullRequest: identity,
            revision: .init(baseCommit: "base", headCommit: "cached"),
            changedFiles: [.init(path: "Cached.swift")],
            conversations: [],
            activity: [],
            checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
            savedAt: .now
        )
        try await sessionStore.writeRemoteCache(cached)
        let failing = ReviewProviderFake(identity: identity, failure: .network("offline"))
        let cachedModel = ReviewWorkModeModel(sessionStore: sessionStore, provider: failing)
        let cachedTab = cachedModel.store.openTab(for: identity)
        cachedModel.mutateTab(cachedTab.id) { $0.revision = cached.revision }
        await cachedModel.refreshTab(tabID: cachedTab.id)
        #expect(cachedModel.tab(cachedTab.id)?.loadState == .stale)
        #expect(cachedModel.tab(cachedTab.id)?.changedFiles.map(\.path) == ["Cached.swift"])
        #expect(!cachedModel.isProviderWriteEligible(in: cachedTab.id))
        cachedModel.setViewed(true, path: "Cached.swift", in: cachedTab.id)
        await cachedModel.sendReply(conversationID: "missing", in: cachedTab.id)
        await cachedModel.setResolved(true, conversationID: "missing", in: cachedTab.id)
        await cachedModel.submitReview(tabID: cachedTab.id)
        #expect(await failing.metadataCalls() == 0)
        #expect(await failing.providerWriteCount() == 0)
        let emptyModel = ReviewWorkModeModel(sessionStore: try temporarySessionStore(), provider: failing)
        let emptyTab = emptyModel.store.openTab(for: identity)
        await emptyModel.refreshTab(tabID: emptyTab.id)
        #expect(emptyModel.tab(emptyTab.id)?.loadState == .failed)
    }
    @Test
    func failedWithoutCacheBlocksEveryProviderMutationAndRetainsAuthoredState() async throws {
        let provider = ReviewProviderFake(identity: identity, failure: .network("offline"))
        let model = ReviewWorkModeModel(sessionStore: try temporarySessionStore(), provider: provider)
        let tab = model.store.openTab(for: identity)
        await model.refreshTab(tabID: tab.id)
        model.mutateTab(tab.id) {
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: "Keep reply")]
            $0.pendingReview = .init(revision: nil, summary: "Keep review", disposition: .comment)
        }
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await model.setResolved(true, conversationID: Self.conversation.id, in: tab.id)
        await model.submitReview(tabID: tab.id)
        #expect(model.tab(tab.id)?.loadState == .failed)
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .unviewed)
        #expect(model.tab(tab.id)?.replyDrafts.first?.body == "Keep reply")
        #expect(model.tab(tab.id)?.pendingReview.summary == "Keep review")
        #expect(model.tab(tab.id)?.conversations.first?.isResolved == false)
        #expect(await provider.metadataCalls() == 0)
        #expect(await provider.providerWriteCount() == 0)
    }
    @Test
    func providerFailureDoesNotReplaceAuthoredRevisionWithMismatchedCache() async throws {
        let sessionStore = try temporarySessionStore()
        try await sessionStore.writeRemoteCache(
            .init(
                pullRequest: identity,
                revision: .init(baseCommit: "base", headCommit: "cached"),
                changedFiles: [.init(path: "Cached.swift")],
                conversations: [],
                activity: [],
                checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
                savedAt: .now
            ))
        let authoredRevision = ReviewRevision(baseCommit: "base", headCommit: "authored")
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: ReviewProviderFake(identity: identity, failure: .network("offline")))
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = authoredRevision
            $0.pendingReview = .init(revision: authoredRevision, summary: "Keep this")
        }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.revision == authoredRevision)
        #expect(model.tab(tab.id)?.pendingReview.revision == authoredRevision)
        #expect(model.tab(tab.id)?.changedFiles.isEmpty == true)
        #expect(model.tab(tab.id)?.loadState == .failed)
    }
    @Test
    func completeReadFailureRejectsCacheThatDiffersFromCurrentMetadataRevision() async throws {
        let sessionStore = try temporarySessionStore()
        try await sessionStore.writeRemoteCache(
            .init(
                pullRequest: identity,
                revision: .init(baseCommit: "base", headCommit: "cached"),
                changedFiles: [.init(path: "Cached.swift")],
                conversations: [],
                activity: [],
                checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
                savedAt: .now
            ))
        let provider = ReviewProviderFake(
            identity: identity,
            completeReadFailure: .network("offline"))
        let model = ReviewWorkModeModel(sessionStore: sessionStore, provider: provider)
        let tab = model.store.openTab(for: identity)
        await model.refreshTab(tabID: tab.id)
        #expect(await provider.metadataCalls() == 1)
        #expect(model.tab(tab.id)?.revision == nil)
        #expect(model.tab(tab.id)?.changedFiles.isEmpty == true)
        #expect(model.tab(tab.id)?.loadState == .failed)
        #expect(!model.isProviderWriteEligible(in: tab.id))
    }
    @Test
    func revisionChangeIsAnnouncedUntilExplicitUpdate() async {
        let provider = ReviewProviderFake(identity: identity, headCommit: "new")
        let old = ReviewRevision(baseCommit: "base", headCommit: "old")
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) { $0.revision = old }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.revision == old)
        #expect(model.tab(tab.id)?.announcedHeadCommit == "new")
        #expect(model.tab(tab.id)?.announcedRevision == .init(baseCommit: "base", headCommit: "new"))
    }
    @Test
    func baseOnlyRevisionChangeIsAnnouncedUntilExplicitUpdate() async {
        let provider = ReviewProviderFake(identity: identity, baseCommit: "new-base")
        let old = ReviewRevision(baseCommit: "old-base", headCommit: "head")
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = old
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.revision == old)
        #expect(model.tab(tab.id)?.announcedRevision == .init(baseCommit: "new-base", headCommit: "head"))
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Source.swift"])
        #expect(model.tab(tab.id)?.loadState == .loaded)
    }

    @Test
    func completeReadFinalRevisionMismatchPreservesLoadedRevisionAndDoesNotCacheMixedPayload() async throws {
        let sessionStore = try temporarySessionStore()
        let barrier = CompleteReadBarrier()
        let provider = FinalRevisionRaceProvider(identity: identity, barrier: barrier)
        let model = ReviewWorkModeModel(sessionStore: sessionStore, provider: provider)
        let tab = model.store.openTab(for: identity)
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        model.mutateTab(tab.id) {
            $0.revision = revisionA
            $0.changedFiles = [.init(path: "Existing.swift")]
            $0.loadState = .loaded
        }

        let refresh = Task { await model.refreshTab(tabID: tab.id) }
        await barrier.waitUntilBlocked()
        await provider.advance(to: "b")
        await barrier.release()
        await refresh.value

        #expect(model.tab(tab.id)?.revision == revisionA)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Existing.swift"])
        #expect(model.tab(tab.id)?.announcedRevision == .init(baseCommit: "base", headCommit: "b"))
        #expect(model.tab(tab.id)?.loadState == .loaded)
        #expect(try await sessionStore.readRemoteCache(for: identity) == nil)
        model.setViewed(true, path: "Existing.swift", in: tab.id)
        #expect(await provider.providerWriteCount() == 0)
    }

    @Test
    func explicitRevisionUpdateFinalMismatchPreservesLoadedRevisionAndDoesNotCacheMixedPayload() async throws {
        let sessionStore = try temporarySessionStore()
        let barrier = CompleteReadBarrier()
        let provider = FinalRevisionRaceProvider(identity: identity, barrier: barrier)
        let model = ReviewWorkModeModel(sessionStore: sessionStore, provider: provider)
        let tab = model.store.openTab(for: identity)
        let oldRevision = ReviewRevision(baseCommit: "base", headCommit: "old")
        model.mutateTab(tab.id) {
            $0.revision = oldRevision
            $0.changedFiles = [.init(path: "Existing.swift")]
            $0.loadState = .loaded
            _ = $0.announceNewRevision(.init(baseCommit: "base", headCommit: "a"))
        }

        let update = Task { await model.updateToAnnouncedRevision(tabID: tab.id) }
        await barrier.waitUntilBlocked()
        await provider.advance(to: "b")
        await barrier.release()
        await update.value

        #expect(model.tab(tab.id)?.revision == oldRevision)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Existing.swift"])
        #expect(model.tab(tab.id)?.announcedRevision == .init(baseCommit: "base", headCommit: "b"))
        #expect(model.tab(tab.id)?.loadState == .loaded)
        #expect(try await sessionStore.readRemoteCache(for: identity) == nil)
        model.setViewed(true, path: "Existing.swift", in: tab.id)
        #expect(await provider.providerWriteCount() == 0)
    }

    @Test
    func finalMetadataFailureTreatsCompleteReadAsStaleAndBlocksProviderWrites() async {
        let barrier = CompleteReadBarrier()
        let provider = FinalRevisionRaceProvider(identity: identity, barrier: barrier)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        model.mutateTab(tab.id) {
            $0.revision = revisionA
            $0.changedFiles = [.init(path: "Existing.swift")]
            $0.loadState = .loaded
        }

        let refresh = Task { await model.refreshTab(tabID: tab.id) }
        await barrier.waitUntilBlocked()
        await provider.failFinalMetadata()
        await barrier.release()
        await refresh.value

        #expect(model.tab(tab.id)?.revision == revisionA)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Existing.swift"])
        #expect(model.tab(tab.id)?.loadState == .stale)
        model.setViewed(true, path: "Existing.swift", in: tab.id)
        #expect(await provider.providerWriteCount() == 0)
    }
    @Test
    func forwardsDirectStoreCloseSelectAndViewedMutations() {
        let model = ReviewWorkModeModel(provider: ReviewProviderFake(identity: identity))
        var emissions = 0
        let cancellable = model.objectWillChange.sink { emissions += 1 }
        defer { cancellable.cancel() }
        let first = model.store.openTab(for: identity)
        let second = model.store.openTab(for: .init(repository: identity.repository, number: 43))
        let afterOpen = emissions
        model.store.selectRelativeTab(-1)
        #expect(emissions > afterOpen)
        let afterSelect = emissions
        model.store.mutateTabForTesting(first.id) { $0.changedFiles = [.init(path: "Source.swift")] }
        model.store.setViewed(true, path: "Source.swift", in: first.id)
        #expect(emissions > afterSelect)
        let afterViewed = emissions
        model.store.closeTab(id: second.id)
        #expect(emissions > afterViewed)
    }
    @Test
    func reopenedAuthoredRevisionIsNotReboundByProviderLoad() async {
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        let provider = ReviewProviderFake(identity: identity, headCommit: "b")
        let model = ReviewWorkModeModel(provider: provider)
        let original = model.store.openTab(for: identity)
        model.mutateTab(original.id) {
            $0.pendingReview = .init(revision: revisionA, summary: "Keep review for A")
        }
        model.store.closeTab(id: original.id)
        let reopened = model.store.openTab(for: identity)
        await model.refreshTab(tabID: reopened.id)
        #expect(model.tab(reopened.id)?.revision == revisionA)
        #expect(model.tab(reopened.id)?.announcedHeadCommit == "b")
    }
    @Test
    func restoredOldRevisionHydratesFromMatchingCacheWhileAnnouncingNewHead() async throws {
        let sessionStore = try temporarySessionStore()
        let revision = ReviewRevision(baseCommit: "base", headCommit: "old")
        try await sessionStore.writeRemoteCache(
            .init(
                pullRequest: identity,
                revision: revision,
                changedFiles: [.init(path: "Cached.swift")],
                conversations: [],
                activity: [],
                checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
                savedAt: .now
            ))
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore, provider: ReviewProviderFake(identity: identity, headCommit: "new"))
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) { $0.revision = revision }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.revision == revision)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Cached.swift"])
        #expect(model.tab(tab.id)?.announcedHeadCommit == "new")
        #expect(model.tab(tab.id)?.loadState == .loaded)
    }
    @Test
    func restoredUnboundPendingReviewRemainsBlockedUntilExplicitRevisionAdoptionAndRemap() async {
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let restoredTab = ReviewTabState(
            pullRequest: identity,
            pendingReview: .init(
                revision: nil,
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "Keep")],
                disposition: .comment
            )
        )
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(
            provider: provider,
            restoreSession: { .init(tabs: [restoredTab]) }
        )
        await model.restore()
        await model.refreshTab(tabID: restoredTab.id)
        #expect(model.tab(restoredTab.id)?.revision == revision)
        #expect(model.tab(restoredTab.id)?.pendingReview.revision == nil)
        #expect(model.tab(restoredTab.id)?.pendingReview.inlineDrafts.allSatisfy { $0.requiresRemap } == true)
        #expect(!model.isProviderWriteEligible(in: restoredTab.id))
        await model.submitReview(tabID: restoredTab.id)
        #expect(await provider.submittedReviews() == 0)
        #expect(model.adoptLoadedRevisionForPendingReview(in: restoredTab.id))
        model.mutateTab(restoredTab.id) { $0.pendingReview.inlineDrafts[0].requiresRemap = false }
        await model.submitReview(tabID: restoredTab.id)
        #expect(await provider.submittedReviews() == 1)
    }

    @Test
    func invalidInlineAnchorIsRejectedLocallyAndNeverCallsProvider() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        await model.refreshTab(tabID: tab.id)

        model.addInlineDraft(path: "Source.swift", line: 99, side: .right, body: "No anchor", in: tab.id)
        #expect(model.tab(tab.id)?.pendingReview.inlineDrafts.isEmpty == true)
        #expect(await provider.submittedReviews() == 0)
    }
    @Test
    func restoredLoadedTabKeepsMatchingFailureCacheStaleUntilACompleteProviderReadSucceeds() async throws {
        let sessionStore = try temporarySessionStore()
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let restoredTab = ReviewTabState(
            pullRequest: identity,
            revision: revision,
            replyDrafts: [.init(conversationID: "conversation", body: "Keep reply")],
            pendingReview: .init(revision: revision, summary: "Summary", disposition: .comment),
            loadState: .loaded
        )
        let provider = ReviewProviderFake(identity: identity, failure: .network("offline"))
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: provider,
            restoreSession: { .init(tabs: [restoredTab]) }
        )
        await model.restore()
        #expect(model.tab(restoredTab.id)?.loadState == .stale)
        #expect(!model.isProviderWriteEligible(in: restoredTab.id))
        model.setViewed(true, path: "Source.swift", in: restoredTab.id)
        await model.sendReply(conversationID: "conversation", in: restoredTab.id)
        await model.setResolved(true, conversationID: "conversation", in: restoredTab.id)
        await model.submitReview(tabID: restoredTab.id)
        #expect(await provider.providerWriteCount() == 0)
        try await sessionStore.writeRemoteCache(
            .init(
                pullRequest: identity,
                revision: revision,
                changedFiles: [.init(path: "Source.swift")],
                conversations: [
                    .init(
                        id: "conversation",
                        path: "Source.swift",
                        line: 1,
                        isResolved: false,
                        isOutdated: false,
                        comments: [.init(id: "comment", databaseID: 1, author: "author", body: "Published", createdAt: .now)],
                        permissions: .init(canReply: true, canResolve: true, canUnresolve: true)
                    )
                ],
                activity: [],
                checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
                savedAt: .now
            ))
        await model.refreshTab(tabID: restoredTab.id)
        #expect(model.tab(restoredTab.id)?.loadState == .stale)
        #expect(!model.isProviderWriteEligible(in: restoredTab.id))
        model.setViewed(true, path: "Source.swift", in: restoredTab.id)
        await model.sendReply(conversationID: "conversation", in: restoredTab.id)
        await model.setResolved(true, conversationID: "conversation", in: restoredTab.id)
        await model.submitReview(tabID: restoredTab.id)
        #expect(await provider.metadataCalls() == 0)
        #expect(await provider.providerWriteCount() == 0)
        provider.clearFailure()
        await model.refreshTab(tabID: restoredTab.id)
        #expect(model.tab(restoredTab.id)?.loadState == .loaded)
        #expect(model.isProviderWriteEligible(in: restoredTab.id))
        model.setViewed(true, path: "Source.swift", in: restoredTab.id)
        await waitForViewedState(.viewed, tabID: restoredTab.id, in: model)
        model.mutateTab(restoredTab.id) { $0.conversations = [Self.conversation] }
        await model.setResolved(true, conversationID: "conversation", in: restoredTab.id)
        // Resolution refreshes the tab, so rehydrate the persisted reply draft
        // before testing its independent provider-write path.
        model.mutateTab(restoredTab.id) {
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: "conversation", body: "Keep reply")]
        }
        await model.sendReply(conversationID: "conversation", in: restoredTab.id)
        await model.submitReview(tabID: restoredTab.id)
        #expect(await provider.providerWriteCount() == 3)
    }
    @Test
    func failedNewerOpenRestoresUsableStateAndSupersededRefreshCannotOverwriteIt() async {
        let gate = SuspensionGate()
        let provider = SupersededRefreshProvider(identity: identity, firstMetadataGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        async let olderRefresh: Void = model.refreshTab(tabID: tab.id)
        await gate.waitUntilSuspended()
        await model.open(identity: identity)
        #expect(model.tab(tab.id)?.loadState == .loaded)
        await gate.resume()
        await olderRefresh
        #expect(model.tab(tab.id)?.loadState == .loaded)
        #expect(model.errorMessage == "newer metadata failed")
    }
    @Test
    func viewedWriteAcknowledgesSuccessAndRetainsPendingStateOnFailure() async {
        let successful = ReviewWorkModeModel(provider: ReviewProviderFake(identity: identity))
        let successTab = successful.store.openTab(for: identity)
        successful.mutateTab(successTab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        successful.setViewed(true, path: "Source.swift", in: successTab.id)
        await waitForViewedState(.viewed, tabID: successTab.id, in: successful)
        #expect(successful.tab(successTab.id)?.changedFiles.first?.viewedState == .viewed)
        let failing = ReviewWorkModeModel(provider: ReviewProviderFake(identity: identity, failure: .network("offline")))
        let failureTab = failing.store.openTab(for: identity)
        failing.mutateTab(failureTab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        failing.setViewed(true, path: "Source.swift", in: failureTab.id)
        await waitForError(in: failing)
        #expect(failing.tab(failureTab.id)?.changedFiles.first?.viewedState == .pendingViewed)
    }
    @Test
    func viewedWriteRetainsIntentAndAnnouncesHeadWhenMetadataRevisionChanged() async {
        let model = ReviewWorkModeModel(provider: ReviewProviderFake(identity: identity, headCommit: "new"))
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "old")
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await waitForAnnouncedHead("new", tabID: tab.id, in: model)
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .pendingViewed)
        #expect(model.tab(tab.id)?.announcedHeadCommit == "new")
    }

    @Test
    func revisionMismatchCleansSynchronizationBeforeAnUpdatedRevisionRetriesViewedWrite() async {
        let provider = RevisionChangingViewedProvider(identity: identity, heads: ["new"])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = prepareViewedTab(in: model, revision: .init(baseCommit: "base", headCommit: "old"))
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await waitForAnnouncedHead("new", tabID: tab.id, in: model)
        await waitForNoViewedSynchronization(in: model)

        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .pendingViewed)
        #expect(model.viewedSynchronizationOperationCountForTesting == 1)
        #expect(await provider.viewedWriteCount() == 0)

        await model.updateToAnnouncedRevision(tabID: tab.id)
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await waitForViewedState(.viewed, tabID: tab.id, in: model)
        await waitForNoViewedSynchronization(in: model)

        #expect(await provider.viewedWriteCount() == 1)
        #expect(model.viewedSynchronizationOperationCountForTesting == 0)
    }

    @Test
    func repeatedRevisionMismatchesDoNotAccumulateViewedSynchronization() async {
        let provider = RevisionChangingViewedProvider(identity: identity, heads: ["new-1", "new-2", "new-3"])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = prepareViewedTab(in: model, revision: .init(baseCommit: "base", headCommit: "old"))

        for (index, viewed) in [true, false, true].enumerated() {
            model.setViewed(viewed, path: "Source.swift", in: tab.id)
            await waitForAnnouncedHead("new-\(index + 1)", tabID: tab.id, in: model)
            await waitForNoViewedSynchronization(in: model)
            #expect(model.viewedSynchronizationOperationCountForTesting == 1)
            await model.updateToAnnouncedRevision(tabID: tab.id)
            await provider.advanceRevision()
        }

        #expect(await provider.viewedWriteCount() == 0)
        #expect(model.viewedSynchronizationOperationCountForTesting == 1)
    }
    @Test
    func delayedViewedThenNewerUnviewedWritesInIntentOrder() async {
        let provider = SerializedViewedProvider(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedViewedTab(in: model)
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await provider.waitUntilWriteSuspended(at: 0)
        model.setViewed(false, path: "Source.swift", in: tab.id)
        await provider.resumeWrite(at: 0)
        await provider.waitUntilWriteSuspended(at: 1)
        await provider.resumeWrite(at: 1)
        await waitForViewedState(.unviewed, tabID: tab.id, in: model)
        #expect(await provider.viewedOperations() == [true, false])
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .unviewed)
    }
    @Test
    func delayedUnviewedThenNewerViewedWritesInIntentOrder() async {
        let provider = SerializedViewedProvider(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedViewedTab(in: model)
        model.mutateTab(tab.id) { $0.changedFiles[0].viewedState = .viewed }
        model.setViewed(false, path: "Source.swift", in: tab.id)
        await provider.waitUntilWriteSuspended(at: 0)
        model.setViewed(true, path: "Source.swift", in: tab.id)
        await provider.resumeWrite(at: 0)
        await provider.waitUntilWriteSuspended(at: 1)
        await provider.resumeWrite(at: 1)
        await waitForViewedState(.viewed, tabID: tab.id, in: model)
        #expect(await provider.viewedOperations() == [false, true])
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .viewed)
    }

    @Test
    func failedViewedWriteContinuesWithNewerUnviewedIntent() async {
        let provider = SerializedViewedProvider(identity: identity, failingWrites: [true])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedViewedTab(in: model)

        model.setViewed(true, path: "Source.swift", in: tab.id)
        await provider.waitUntilWriteSuspended(at: 0)
        model.setViewed(false, path: "Source.swift", in: tab.id)
        await provider.resumeWrite(at: 0)
        await provider.waitUntilWriteSuspended(at: 1)
        await provider.resumeWrite(at: 1)
        await waitForViewedState(.unviewed, tabID: tab.id, in: model)
        await waitForNoViewedSynchronization(in: model)

        #expect(await provider.viewedOperations() == [true, false])
        #expect(model.errorMessage == nil)
        #expect(model.viewedSynchronizationOperationCountForTesting == 0)
        #expect(model.viewedSynchronizationTaskCountForTesting == 0)
    }

    @Test
    func failedNewerUnviewedIntentRemainsPendingWithoutSynchronizationTask() async {
        let provider = SerializedViewedProvider(identity: identity, failingWrites: [true, true])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedViewedTab(in: model)

        model.setViewed(true, path: "Source.swift", in: tab.id)
        await provider.waitUntilWriteSuspended(at: 0)
        model.setViewed(false, path: "Source.swift", in: tab.id)
        await provider.resumeWrite(at: 0)
        await provider.waitUntilWriteSuspended(at: 1)
        await provider.resumeWrite(at: 1)
        await waitForError(in: model)
        await waitForNoViewedSynchronizationTask(in: model)

        #expect(await provider.viewedOperations() == [true, false])
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .pendingUnviewed)
        #expect(model.errorMessage == "Viewed write 2 failed")
        #expect(model.viewedSynchronizationOperationCountForTesting == 1)
        #expect(model.viewedSynchronizationTaskCountForTesting == 0)
    }
    @Test
    func lifecycleFlushDoesNotDeadlockAfterScheduledSaveFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        try Data().write(to: root)
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let model = ReviewWorkModeModel(sessionStore: store, provider: ReviewProviderFake(identity: identity))
        await store.scheduleSave(.init(), after: .zero)
        model.flushSynchronously()
        await Task.yield()
        #expect(model.errorMessage?.contains("Could not save Review Session State") == true)
    }

    @Test
    func delayedScheduledSaveCannotOverwriteNewerLifecycleFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SuspensionGate()
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let coordinator = ReviewSessionCoordinator(
            sessionStore: store,
            restoreSession: { .init() },
            beforeScheduleSave: { await gate.wait() }
        )

        coordinator.scheduleSave(.init(rightSidebarWidth: 200))
        await gate.waitUntilSuspended()
        var lifecycleFailure: String?
        coordinator.flushSynchronously(.init(rightSidebarWidth: 400)) { lifecycleFailure = $0 }
        #expect(lifecycleFailure == nil)
        await gate.resume()
        try await Task.sleep(for: .milliseconds(400))

        #expect(try await store.restore().rightSidebarWidth == 400)
    }

    @Test
    func delayedScheduledSaveCannotOverwriteNewerAsyncFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SuspensionGate()
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let coordinator = ReviewSessionCoordinator(
            sessionStore: store,
            restoreSession: { .init() },
            beforeScheduleSave: { await gate.wait() }
        )

        coordinator.scheduleSave(.init(rightSidebarWidth: 200))
        await gate.waitUntilSuspended()
        try await coordinator.flush(.init(rightSidebarWidth: 400))
        await gate.resume()
        try await Task.sleep(for: .milliseconds(400))

        #expect(try await store.restore().rightSidebarWidth == 400)
    }

    @Test
    func normalCoordinatorSaveOrderingPersistsTheLatestSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let coordinator = ReviewSessionCoordinator(sessionStore: store, restoreSession: { .init() })

        coordinator.scheduleSave(.init(rightSidebarWidth: 200))
        try await coordinator.flush(.init(rightSidebarWidth: 400))

        #expect(try await store.restore().rightSidebarWidth == 400)
    }

    @Test
    func corruptRestoreBlocksCoordinatorAsyncAndLifecycleFlushesWithoutOverwritingSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let original = Data("not json".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: sessionURL)
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let coordinator = ReviewSessionCoordinator(sessionStore: store, restoreSession: { try await store.restore() })

        if case .failed = await coordinator.restoreSnapshot() {} else { Issue.record("Expected corrupt restore to fail") }
        coordinator.scheduleSave(.init())
        try await Task.sleep(for: .milliseconds(400))
        await #expect(throws: ReviewSessionStore.StoreError.automaticWritesBlocked) {
            try await coordinator.flush(.init())
        }
        var lifecycleFailure: String?
        coordinator.flushSynchronously(.init()) { lifecycleFailure = $0 }
        await Task.yield()

        #expect(lifecycleFailure != nil)
        #expect(try Data(contentsOf: sessionURL) == original)
        let backupURL = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("session.corrupt-") })
        #expect(try Data(contentsOf: backupURL) == original)
    }

    @Test
    func unsupportedRestoreBlocksCoordinatorAsyncAndLifecycleFlushesWithoutOverwritingSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let original = Data(#"{"schemaVersion":999}"#.utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: sessionURL)
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let coordinator = ReviewSessionCoordinator(sessionStore: store, restoreSession: { try await store.restore() })

        if case .failed = await coordinator.restoreSnapshot() {} else { Issue.record("Expected unsupported restore to fail") }
        coordinator.scheduleSave(.init())
        try await Task.sleep(for: .milliseconds(400))
        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(999)) {
            try await coordinator.flush(.init())
        }
        var lifecycleFailure: String?
        coordinator.flushSynchronously(.init()) { lifecycleFailure = $0 }
        await Task.yield()

        #expect(lifecycleFailure != nil)
        #expect(try Data(contentsOf: sessionURL) == original)
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!directoryContents.contains { $0.hasPrefix("session.corrupt-") })
    }
    @Test
    func lateRestoreDoesNotReplaceLiveAuthoredMutation() async {
        let gate = SuspensionGate()
        let restoredTab = ReviewTabState(pullRequest: identity)
        let model = ReviewWorkModeModel(
            provider: ReviewProviderFake(identity: identity),
            restoreSession: {
                await gate.wait()
                return .init(tabs: [restoredTab])
            }
        )
        async let restoring: Void = model.restore()
        await gate.waitUntilSuspended()
        let live = model.store.openTab(for: identity)
        model.mutateTab(live.id) { $0.pendingReview.summary = "Live edit" }
        await gate.resume()
        await restoring
        #expect(model.tab(live.id)?.pendingReview.summary == "Live edit")
    }
    @Test
    func failingIntakeDoesNotDiscardSuspendedRestoreAndLifecycleFlushPersistsIt() async throws {
        let sessionStore = try temporarySessionStore()
        let gate = SuspensionGate()
        let restoredTab = ReviewTabState(
            pullRequest: identity,
            pendingReview: .init(revision: nil, summary: "Restored draft", disposition: .comment)
        )
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: ReviewProviderFake(identity: identity, failure: .network("offline")),
            restoreSession: {
                await gate.wait()
                return .init(tabs: [restoredTab])
            }
        )

        async let restoring: Void = model.restore()
        await gate.waitUntilSuspended()
        await model.open(identity: identity)
        await gate.resume()
        await restoring
        model.flushSynchronously()

        #expect(model.tab(restoredTab.id)?.pendingReview.summary == "Restored draft")
        #expect(try await sessionStore.restore().tabs.first?.pendingReview.summary == "Restored draft")
    }

    @Test
    func successfulIntakeWaitsForRestoreAndRetainsBothStates() async {
        let gate = SuspensionGate()
        let restoredIdentity = PullRequestIdentity(repository: identity.repository, number: 43)
        let restoredTab = ReviewTabState(
            pullRequest: restoredIdentity,
            pendingReview: .init(revision: nil, summary: "Restored draft", disposition: .comment)
        )
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(
            provider: provider,
            restoreSession: {
                await gate.wait()
                return .init(tabs: [restoredTab])
            }
        )

        async let restoring: Void = model.restore()
        await gate.waitUntilSuspended()
        async let intake: Void = model.open(identity: identity)
        await Task.yield()
        await gate.resume()
        await (restoring, intake)

        #expect(model.tab(restoredTab.id)?.pendingReview.summary == "Restored draft")
        #expect(model.store.session.tabs.contains { $0.pullRequest == identity })
        #expect(await provider.metadataCalls() == 2)
    }

    @Test(arguments: [0, 1, 2, 3])
    func partialOpenReadFailureStalesFormerlyLoadedTabAndBlocksAllProviderWrites(
        failingComponentIndex: Int
    ) async {
        let failingComponent: ReviewProviderFake.ReadComponent = switch failingComponentIndex {
        case 0: .changedFiles
        case 1: .activity
        case 2: .checks
        default: .conversations
        }
        let provider = ReviewProviderFake(identity: identity, failingReadComponent: failingComponent)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: "Keep reply")]
            $0.pendingReview = .init(revision: revision, summary: "Keep review", disposition: .comment)
            $0.loadState = .loaded
        }

        await model.open(identity: identity)
        #expect(model.tab(tab.id)?.loadState == .stale)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["Source.swift"])
        #expect(!model.isProviderWriteEligible(in: tab.id))

        model.setViewed(true, path: "Source.swift", in: tab.id)
        await model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await model.setResolved(true, conversationID: Self.conversation.id, in: tab.id)
        await model.submitReview(tabID: tab.id)

        #expect(await provider.metadataCalls() == 1)
        #expect(await provider.providerWriteCount() == 0)
    }
    @Test
    func reviewSubmissionReconcilesOnlySubmittedContentAndPreservesDraftAddedDuringSubmission() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, submitGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [
                .init(
                    path: "Source.swift",
                    validAnchorCoordinates: [
                        .init(side: .right, line: 1),
                        .init(side: .right, line: 2)
                    ]
                )
            ]
            $0.pendingReview = .init(
                revision: revision,
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "Draft A")],
                summary: "Submitted",
                disposition: .comment
            )
            $0.loadState = .loaded
        }
        async let first: Void = model.submitReview(tabID: tab.id)
        await gate.waitUntilSuspended()
        async let second: Void = model.submitReview(tabID: tab.id)
        model.mutateTab(tab.id) {
            $0.pendingReview.inlineDrafts[0].body = "Edited Draft A"
            $0.pendingReview.inlineDrafts.append(.init(anchor: .init(path: "Source.swift", line: 2, side: .right), body: "Draft B"))
            $0.pendingReview.summary = "Newer edit"
        }
        await gate.resume()
        _ = await (first, second)
        let submissionCount = await provider.submissionCount()
        #expect(submissionCount == 1)
        #expect(model.tab(tab.id)?.pendingReview.summary == "Newer edit")
        #expect(model.tab(tab.id)?.pendingReview.inlineDrafts.map(\.body) == ["Edited Draft A", "Draft B"])
    }
    @Test
    func confirmedSubmissionPublishesCapturedPendingReviewAndPreservesEditsMadeAfterConfirmation() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, submitGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let confirmed = PendingReview(
            revision: revision,
            inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "Confirmed draft")],
            summary: "Confirmed summary",
            disposition: .comment
        )
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [
                .init(path: "Source.swift", validAnchorCoordinates: [.init(side: .right, line: 1)])
            ]
            $0.pendingReview = confirmed
            $0.loadState = .loaded
        }

        model.mutateTab(tab.id) {
            $0.pendingReview.inlineDrafts[0].body = "Newer draft"
            $0.pendingReview.summary = "Newer summary"
            $0.pendingReview.disposition = .approve
        }
        async let submission: Void = model.submitReview(tabID: tab.id, pendingReview: confirmed)
        await gate.waitUntilSuspended()
        await gate.resume()
        await submission

        #expect(await provider.submittedPendingReviews() == [confirmed])
        #expect(model.tab(tab.id)?.pendingReview.inlineDrafts.map(\.body) == ["Newer draft"])
        #expect(model.tab(tab.id)?.pendingReview.summary == "Newer summary")
        #expect(model.tab(tab.id)?.pendingReview.disposition == .approve)
    }
    @Test
    func successfulSubmissionPreservesDispositionChangedWhileSubmissionWasInFlight() async {
        let gate = SuspensionGate()
        let model = ReviewWorkModeModel(provider: SuspendedReviewProvider(identity: identity, submitGate: gate))
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.pendingReview = .init(revision: revision, summary: "Submitted", disposition: .comment)
            $0.loadState = .loaded
        }
        async let submission: Void = model.submitReview(tabID: tab.id)
        await gate.waitUntilSuspended()
        model.mutateTab(tab.id) { $0.pendingReview.disposition = .approve }
        await gate.resume()
        await submission
        #expect(model.tab(tab.id)?.pendingReview.disposition == .approve)
    }
    @Test
    func successfulSubmissionPreservesDraftRemappedToNewRevisionWhileSuspended() async {
        let gate = SuspensionGate()
        let model = ReviewWorkModeModel(provider: SuspendedReviewProvider(identity: identity, submitGate: gate))
        let tab = model.store.openTab(for: identity)
        let oldRevision = ReviewRevision(baseCommit: "base", headCommit: "old")
        let newRevision = ReviewRevision(baseCommit: "base", headCommit: "new")
        model.mutateTab(tab.id) {
            $0.revision = oldRevision
            $0.changedFiles = [
                .init(path: "Source.swift", validAnchorCoordinates: [.init(side: .right, line: 1)])
            ]
            $0.pendingReview = .init(
                revision: oldRevision,
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "Draft")],
                disposition: .comment
            )
            $0.loadState = .loaded
        }
        async let submission: Void = model.submitReview(tabID: tab.id)
        await gate.waitUntilSuspended()
        model.mutateTab(tab.id) {
            $0.revision = newRevision
            $0.pendingReview.revision = newRevision
            $0.pendingReview.inlineDrafts[0].requiresRemap = true
        }
        await gate.resume()
        await submission
        #expect(model.tab(tab.id)?.pendingReview.revision == newRevision)
        #expect(model.tab(tab.id)?.pendingReview.inlineDrafts.first?.requiresRemap == true)
    }
    @Test
    func completeRefreshReplacesPriorViewedStateForStableAndRenamedPaths() async {
        let provider = ReviewProviderFake(
            identity: identity,
            changedFiles: [
                .init(
                    path: "New.swift", previousPath: "Old.swift", status: .renamed, additions: 1,
                    deletions: 0, isBinary: false),
                .init(
                    path: "Stable.swift", previousPath: nil, status: .modified, additions: 1,
                    deletions: 0, isBinary: false)
            ]
        )
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [
                .init(path: "Old.swift", viewedState: .viewed),
                .init(path: "Stable.swift", viewedState: .pendingViewed)
            ]
        }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.changedFiles.map(\.viewedState) == [.unviewed, .unviewed])
    }
    @Test
    func refreshDoesNotTransferViewedStateToAnUnrelatedPath() async {
        let provider = ReviewProviderFake(
            identity: identity,
            changedFiles: [.init(path: "Unrelated.swift", previousPath: nil, status: .modified, additions: 1, deletions: 0, isBinary: false)]
        )
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Old.swift", viewedState: .pendingViewed)]
        }
        await model.refreshTab(tabID: tab.id)
        #expect(model.tab(tab.id)?.changedFiles.first?.viewedState == .unviewed)
    }
    @Test
    func updateToAnnouncedRevisionKeepsRenamedDraftPathUntilExplicitRemap() async {
        let provider = ReviewProviderFake(
            identity: identity,
            headCommit: "new",
            changedFiles: [.init(path: "New.swift", previousPath: "Old.swift", status: .renamed, additions: 1, deletions: 0, isBinary: false)]
        )
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let old = ReviewRevision(baseCommit: "base", headCommit: "old")
        model.mutateTab(tab.id) {
            $0.revision = old
            $0.announcedHeadCommit = "new"
            $0.pendingReview = .init(
                revision: old,
                inlineDrafts: [
                    .init(anchor: .init(path: "Old.swift", line: 1, side: .right), body: "Map"),
                    .init(anchor: .init(path: "Other.swift", line: 2, side: .right), body: "Remap")
                ],
                disposition: .comment
            )
        }
        await model.updateToAnnouncedRevision(tabID: tab.id)
        let drafts = try! #require(model.tab(tab.id)?.pendingReview.inlineDrafts)
        #expect(model.tab(tab.id)?.revision == .init(baseCommit: "base", headCommit: "new"))
        #expect(drafts[0].anchor.path == "Old.swift" && drafts[0].requiresRemap)
        #expect(drafts[1].anchor.path == "Other.swift" && drafts[1].requiresRemap)
        await model.submitReview(tabID: tab.id)
        #expect(model.errorMessage?.contains("Inline drafts") == true)
        #expect(await provider.submittedReviews() == 0)
    }

    @Test
    func explicitRevisionUpdateCachesAndRestoresTheAdoptedRevisionOffline() async throws {
        let sessionStore = try temporarySessionStore()
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        let revisionB = ReviewRevision(baseCommit: "base", headCommit: "b")
        try await sessionStore.writeRemoteCache(.init(
            pullRequest: identity, revision: revisionA, changedFiles: [.init(path: "A.swift")],
            conversations: [], activity: [],
            checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now
        ))
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: ReviewProviderFake(identity: identity, headCommit: "b", changedFiles: [.init(path: "B.swift")])
        )
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = revisionA
            $0.announcedRevision = revisionB
            $0.announcedHeadCommit = revisionB.headCommit
        }

        await model.updateToAnnouncedRevision(tabID: tab.id)

        #expect(model.tab(tab.id)?.revision == revisionB)
        #expect(try await sessionStore.readRemoteCache(for: identity)?.revision == revisionB)
        try await sessionStore.flushScheduledSave(model.store.session)

        let restored = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: ReviewProviderFake(identity: identity, failure: .network("offline"))
        )
        await restored.restore()
        let restoredTab = try #require(restored.store.session.tabs.first)
        await restored.refreshTab(tabID: restoredTab.id)

        #expect(restored.tab(restoredTab.id)?.revision == revisionB)
        #expect(restored.tab(restoredTab.id)?.changedFiles.map(\.path) == ["B.swift"])
        #expect(restored.tab(restoredTab.id)?.loadState == .stale)
    }

    @Test
    func explicitRevisionUpdateWinsAgainstAnOlderDelayedRefreshCacheWrite() async throws {
        let gate = RemoteCacheWriteGate()
        let sessionStore = try temporarySessionStore(beforeOrderedRemoteCacheWrite: { cache, _, _ in
            if cache.revision.headCommit == "a" { await gate.wait() }
        })
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        let revisionB = ReviewRevision(baseCommit: "base", headCommit: "b")
        let provider = RevisionSequenceProvider(
            identity: identity,
            revisions: [revisionA, revisionA, revisionB, revisionB]
        )
        let model = ReviewWorkModeModel(sessionStore: sessionStore, provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = revisionA
        }

        async let ordinaryRefresh: Void = model.refreshTab(tabID: tab.id)
        await gate.waitUntilSuspended()
        model.mutateTab(tab.id) {
            $0.announcedRevision = revisionB
            $0.announcedHeadCommit = revisionB.headCommit
        }
        await model.updateToAnnouncedRevision(tabID: tab.id)

        #expect(model.tab(tab.id)?.revision == revisionB)
        #expect(try await sessionStore.readRemoteCache(for: identity)?.revision == revisionB)
        await gate.resume()
        await ordinaryRefresh

        #expect(try await sessionStore.readRemoteCache(for: identity)?.revision == revisionB)
    }

    @Test
    func cacheWriteFailureRetainsTheLoadedRevisionAndAuthoredState() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionStore = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache"),
            fileOperationFailure: .setTemporaryPermissions
        )
        let revisionA = ReviewRevision(baseCommit: "base", headCommit: "a")
        let revisionB = ReviewRevision(baseCommit: "base", headCommit: "b")
        let model = ReviewWorkModeModel(
            sessionStore: sessionStore,
            provider: ReviewProviderFake(identity: identity, headCommit: "b", changedFiles: [.init(path: "B.swift")])
        )
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = revisionA
            $0.announcedRevision = revisionB
            $0.announcedHeadCommit = revisionB.headCommit
            $0.pendingReview = .init(revision: revisionA, summary: "Keep draft", disposition: .comment)
        }

        await model.updateToAnnouncedRevision(tabID: tab.id)

        #expect(model.tab(tab.id)?.revision == revisionB)
        #expect(model.tab(tab.id)?.changedFiles.map(\.path) == ["B.swift"])
        #expect(model.tab(tab.id)?.pendingReview.summary == "Keep draft")
        #expect(model.errorMessage?.contains("Could not cache Pull Request data") == true)
    }
    @Test
    func selectingDifferentFileClearsConversationLineAnchor() {
        let model = ReviewWorkModeModel(provider: ReviewProviderFake(identity: identity))
        let tab = model.store.openTab(for: identity)
        model.selectFile("Source.swift", line: 12, in: tab.id)
        model.selectFile("Other.swift", in: tab.id)
        #expect(model.tab(tab.id)?.selectedFilePath == "Other.swift")
        #expect(model.tab(tab.id)?.selectedLine == nil)
    }
    @Test
    func replyRejectsDuplicatesAndPreservesNewerBody() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: "Submitted reply")]
        }
        async let first: Void = model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await gate.waitUntilSuspended()
        async let second: Void = model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        model.mutateTab(tab.id) { $0.replyDrafts[0].body = "Newer reply" }
        await gate.resume()
        _ = await (first, second)
        let replyCount = await provider.replyCount()
        #expect(replyCount == 1)
        #expect(model.tab(tab.id)?.replyDrafts.first?.body == "Newer reply")
    }

    @Test
    func successfulReplyNormalizesProviderBodyButClearsOnlyExactUnchangedDraft() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedReplyTab(in: model, body: "  Markdown reply\n\n")

        async let sending: Void = model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await gate.waitUntilSuspended()
        #expect(await provider.replyBodies() == ["Markdown reply"])
        await gate.resume()
        _ = await sending

        #expect(model.tab(tab.id)?.replyDrafts.isEmpty == true)
    }

    @Test
    func successfulReplyPreservesLeadingWhitespaceOrTrailingNewlineEditsMadeWhileSending() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = preparedReplyTab(in: model, body: "Markdown reply")

        async let sending: Void = model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await gate.waitUntilSuspended()
        model.mutateTab(tab.id) { $0.replyDrafts[0].body = "  Markdown reply\n" }
        await gate.resume()
        _ = await sending

        #expect(model.tab(tab.id)?.replyDrafts.first?.body == "  Markdown reply\n")
    }
    @Test
    func successfulReplyAfterTabCloseClearsMatchingClosedAuthoredState() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: "Send me")]
        }
        async let sending: Void = model.sendReply(conversationID: Self.conversation.id, in: tab.id)
        await gate.waitUntilSuspended()
        model.closeTab(tab.id)
        await gate.resume()
        _ = await sending
        #expect(model.store.session.closedAuthoredState[identity] == nil)
        #expect(model.store.openTab(for: identity).replyDrafts.isEmpty)
    }

    @Test
    func successfulReplyAfterClosePreservesAnEditedReopenedDraft() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let original = preparedReplyTab(in: model, body: "Markdown reply")

        async let sending: Void = model.sendReply(conversationID: Self.conversation.id, in: original.id)
        await gate.waitUntilSuspended()
        model.closeTab(original.id)
        let reopened = model.store.openTab(for: identity)
        model.mutateTab(reopened.id) { $0.replyDrafts[0].body = "    Markdown reply\n" }
        await gate.resume()
        _ = await sending

        #expect(model.tab(reopened.id)?.replyDrafts.first?.body == "    Markdown reply\n")
    }
    @Test
    func successfulReviewAfterTabCloseClearsMatchingClosedAuthoredState() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, submitGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.pendingReview = .init(revision: revision, summary: "Send", disposition: .comment)
            $0.loadState = .loaded
        }
        async let submitting: Void = model.submitReview(tabID: tab.id)
        await gate.waitUntilSuspended()
        model.closeTab(tab.id)
        await gate.resume()
        _ = await submitting
        #expect(model.store.session.closedAuthoredState[identity] == nil)
        #expect(model.store.openTab(for: identity).pendingReview.summary.isEmpty)
    }
    @Test
    func replyRemainsSubmittingAcrossCloseAndReopenAndRejectsDuplicateProviderCall() async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, replyGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let original = model.store.openTab(for: identity)
        model.mutateTab(original.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: "Send me")]
        }
        async let first: Void = model.sendReply(conversationID: Self.conversation.id, in: original.id)
        await gate.waitUntilSuspended()
        model.closeTab(original.id)
        let reopened = model.store.openTab(for: identity)
        model.mutateTab(reopened.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [Self.conversation]
        }
        #expect(model.isSendingReply(conversationID: Self.conversation.id, in: reopened.id))
        async let duplicate: Void = model.sendReply(conversationID: Self.conversation.id, in: reopened.id)
        await gate.resume()
        _ = await (first, duplicate)
        #expect(await provider.replyCount() == 1)
        #expect(model.tab(reopened.id)?.replyDrafts.isEmpty == true)
    }
    @Test(arguments: [ReviewDisposition.approve, .comment, .requestChanges])
    func pullRequestKeyedReviewSubmissionRemainsSubmittingAcrossCloseAndReopen(_ disposition: ReviewDisposition) async {
        let gate = SuspensionGate()
        let provider = SuspendedReviewProvider(identity: identity, submitGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let original = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(original.id) {
            $0.revision = revision
            $0.pendingReview = .init(revision: revision, disposition: disposition)
            $0.loadState = .loaded
        }
        async let first: Void = model.submitReview(tabID: original.id)
        await gate.waitUntilSuspended()
        model.closeTab(original.id)
        let reopened = model.store.openTab(for: identity)
        #expect(model.isSubmittingReview(in: reopened.id))
        async let duplicate: Void = model.submitReview(tabID: reopened.id)
        model.closeTab(reopened.id)
        await gate.resume()
        _ = await (first, duplicate)
        #expect(await provider.submissionCount() == 1)
        #expect(model.store.session.closedAuthoredState[identity] == nil)
        #expect(model.store.openTab(for: identity).pendingReview.disposition == nil)
    }
    @Test
    func diffInputReadsCorrectCommitAndPathForEachFileStatus() async throws {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        model.mutateTab(tab.id) { $0.revision = revision }
        try await assertDiffInputCalls(
            model: model, provider: provider, tabID: tab.id,
            file: .init(path: "Current.swift", status: .modified),
            expected: [("Current.swift", "base"), ("Current.swift", "head")])
        try await assertDiffInputCalls(
            model: model, provider: provider, tabID: tab.id,
            file: .init(path: "Added.swift", status: .added), expected: [("Added.swift", "head")])
        try await assertDiffInputCalls(
            model: model, provider: provider, tabID: tab.id,
            file: .init(path: "Deleted.swift", status: .deleted), expected: [("Deleted.swift", "base")])
        try await assertDiffInputCalls(
            model: model, provider: provider, tabID: tab.id,
            file: .init(path: "New.swift", previousPath: "Old.swift", status: .renamed),
            expected: [("Old.swift", "base"), ("New.swift", "head")])
    }
    @Test
    func diffInputRejectsBinaryNonUTF8AndOversizedContent() async {
        for content in [Data([0]), Data([0xFF]), Data(repeating: 65, count: 4_000_001)] {
            let provider = ReviewProviderFake(identity: identity, fileContent: content)
            let model = ReviewWorkModeModel(provider: provider)
            let tab = model.store.openTab(for: identity)
            model.mutateTab(tab.id) { $0.revision = .init(baseCommit: "base", headCommit: "head") }
            await #expect(throws: GitHubCLIProviderError.self) {
                try await model.diffInput(for: .init(path: "Source.swift"), in: try #require(model.tab(tab.id)))
            }
        }
    }
    @Test
    func diffInputCancelsWhenLiveTabRevisionChanges() async {
        let gate = SuspensionGate()
        let provider = ReviewProviderFake(identity: identity, contentGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Added.swift", status: .added)]
            $0.selectedFilePath = "Added.swift"
        }
        let input = Task { () -> Result<ArgusDiffInput, Error> in
            do {
                return .success(
                    try await model.diffInput(
                        for: .init(path: "Added.swift", status: .added),
                        in: try #require(model.tab(tab.id)))
                )
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()
        model.mutateTab(tab.id) { $0.revision = .init(baseCommit: "base", headCommit: "new") }
        await gate.resume()
        switch await input.value {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Expected stale diff request to cancel")
        }
    }
    @Test
    func diffInputCancelsWhenItsLiveTabCloses() async {
        let gate = SuspensionGate()
        let provider = ReviewProviderFake(identity: identity, contentGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Added.swift", status: .added)]
            $0.selectedFilePath = "Added.swift"
        }
        let input = Task { () -> Result<ArgusDiffInput, Error> in
            do {
                return .success(
                    try await model.diffInput(
                        for: .init(path: "Added.swift", status: .added),
                        in: try #require(model.tab(tab.id)))
                )
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()
        model.store.closeTab(id: tab.id)
        await gate.resume()
        switch await input.value {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Expected closed-tab diff request to cancel")
        }
    }
    @Test
    func diffInputCancelsWhenSelectedFileChangesWhileContentIsLoading() async {
        let gate = SuspensionGate()
        let provider = ReviewProviderFake(identity: identity, contentGate: gate)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [
                .init(path: "First.swift", status: .added),
                .init(path: "Second.swift", status: .added)
            ]
            $0.selectedFilePath = "First.swift"
        }
        let input = Task { () -> Result<ArgusDiffInput, Error> in
            do {
                return .success(
                    try await model.diffInput(
                        for: .init(path: "First.swift", status: .added),
                        in: try #require(model.tab(tab.id)))
                )
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()
        model.selectFile("Second.swift", line: nil, in: tab.id)
        await gate.resume()

        switch await input.value {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Expected superseded file diff request to cancel")
        }
    }
    @Test
    func resolveAndUnresolveRequireTheMatchingPermissionAndRefreshAfterSuccess() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [
                .init(id: "resolve", path: nil, line: nil, isResolved: false, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: true, canUnresolve: false)),
                .init(id: "unresolve", path: nil, line: nil, isResolved: true, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: false, canUnresolve: true)),
                .init(id: "denied", path: nil, line: nil, isResolved: false, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: false, canUnresolve: false))
            ]
        }
        await model.setResolved(true, conversationID: "resolve", in: tab.id)
        model.mutateTab(tab.id) {
            $0.conversations = [
                .init(id: "unresolve", path: nil, line: nil, isResolved: true, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: false, canUnresolve: true)),
                .init(id: "denied", path: nil, line: nil, isResolved: false, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: false, canUnresolve: false))
            ]
        }
        await model.setResolved(false, conversationID: "unresolve", in: tab.id)
        await model.setResolved(true, conversationID: "denied", in: tab.id)
        let operations = await provider.resolvedOperations()
        #expect(operations.count == 2)
        #expect(operations.map(\.threadID) == ["resolve", "unresolve"])
        #expect(operations.map(\.resolved) == [true, false])
        #expect(await provider.metadataCalls() >= 2)
    }
    @Test
    func resolutionFailureRetainsStateAndReportsProviderError() async {
        let provider = ReviewProviderFake(identity: identity, resolveFailure: .network("offline"))
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [.init(id: "thread", path: nil, line: nil, isResolved: false, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: true, canUnresolve: false))]
        }
        await model.setResolved(true, conversationID: "thread", in: tab.id)
        let operations = await provider.resolvedOperations()
        #expect(operations.count == 1)
        #expect(operations[0].threadID == "thread" && operations[0].resolved)
        #expect(model.tab(tab.id)?.conversations.first?.isResolved == false)
        #expect(model.errorMessage == "offline")
    }
    @Test
    func resolutionWritesDeduplicateSameAndOppositeIntentsWhileInFlight() async {
        let provider = SuspendedResolutionProvider(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        prepareResolvableConversation(in: model, tabID: tab.id)

        let first = Task { await model.setResolved(true, conversationID: "thread", in: tab.id) }
        await provider.waitUntilWriteSuspended(at: 0)
        #expect(model.isSettingResolution(conversationID: "thread", in: tab.id))
        async let duplicate: Void = model.setResolved(true, conversationID: "thread", in: tab.id)
        async let opposite: Void = model.setResolved(false, conversationID: "thread", in: tab.id)
        _ = await (duplicate, opposite)

        #expect(await provider.resolutionOperations() == [true])
        await provider.resumeWrite(at: 0)
        await first.value
        #expect(!model.isSettingResolution(conversationID: "thread", in: tab.id))
    }
    @Test
    func resolutionWriteCanRetryAfterSuccess() async {
        let provider = SuspendedResolutionProvider(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        prepareResolvableConversation(in: model, tabID: tab.id)

        let first = Task { await model.setResolved(true, conversationID: "thread", in: tab.id) }
        await provider.waitUntilWriteSuspended(at: 0)
        await provider.resumeWrite(at: 0)
        await first.value
        prepareResolvableConversation(in: model, tabID: tab.id)
        let retry = Task { await model.setResolved(true, conversationID: "thread", in: tab.id) }
        await provider.waitUntilWriteSuspended(at: 1)

        #expect(await provider.resolutionOperations() == [true, true])
        await provider.resumeWrite(at: 1)
        await retry.value
    }
    @Test
    func resolutionWriteCanRetryAfterFailure() async {
        let provider = SuspendedResolutionProvider(identity: identity, failingWrites: [true])
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        prepareResolvableConversation(in: model, tabID: tab.id)

        let first = Task { await model.setResolved(true, conversationID: "thread", in: tab.id) }
        await provider.waitUntilWriteSuspended(at: 0)
        await provider.resumeWrite(at: 0)
        await first.value
        #expect(!model.isSettingResolution(conversationID: "thread", in: tab.id))
        let retry = Task { await model.setResolved(true, conversationID: "thread", in: tab.id) }
        await provider.waitUntilWriteSuspended(at: 1)

        #expect(await provider.resolutionOperations() == [true, true])
        await provider.resumeWrite(at: 1)
        await retry.value
    }
    @Test
    func resolutionWriteRemainsDeduplicatedAfterClosingAndReopeningSamePullRequest() async {
        let provider = SuspendedResolutionProvider(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let original = model.store.openTab(for: identity)
        prepareResolvableConversation(in: model, tabID: original.id)

        let first = Task { await model.setResolved(true, conversationID: "thread", in: original.id) }
        await provider.waitUntilWriteSuspended(at: 0)
        model.store.closeTab(id: original.id)
        let reopened = model.store.openTab(for: identity)
        prepareResolvableConversation(in: model, tabID: reopened.id)
        await model.setResolved(false, conversationID: "thread", in: reopened.id)

        #expect(await provider.resolutionOperations() == [true])
        await provider.resumeWrite(at: 0)
        await first.value
    }
    @Test
    func submitRejectsPendingReviewUntilDispositionIsExplicitlySelected() async {
        let provider = ReviewProviderFake(identity: identity)
        let model = ReviewWorkModeModel(provider: provider)
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.pendingReview = .init(revision: $0.revision, summary: "Summary")
            $0.loadState = .loaded
        }
        await model.submitReview(tabID: tab.id)
        #expect(model.errorMessage?.contains("Review Disposition") == true)
        #expect(await provider.submittedReviews() == 0)
    }
    private func prepareResolvableConversation(in model: ReviewWorkModeModel, tabID: UUID) {
        model.mutateTab(tabID) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [
                .init(
                    id: "thread", path: nil, line: nil, isResolved: false, isOutdated: false, comments: [],
                    permissions: .init(canReply: false, canResolve: true, canUnresolve: true))
            ]
        }
    }
    private func temporarySessionStore(
        beforeOrderedRemoteCacheWrite: (@Sendable (ReviewRemoteCache, PullRequestIdentity, UInt64) async -> Void)? = nil
    ) throws -> ReviewSessionStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache"),
            beforeOrderedRemoteCacheWrite: beforeOrderedRemoteCacheWrite
        )
    }
    private func waitForViewedState(
        _ expected: ReviewViewedState,
        tabID: UUID,
        in model: ReviewWorkModeModel
    ) async {
        for _ in 0..<100 {
            if model.tab(tabID)?.changedFiles.first?.viewedState == expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForNoViewedSynchronization(in model: ReviewWorkModeModel) async {
        for _ in 0..<100 {
            if model.viewedSynchronizationOperationCountForTesting == 0 { return }
            await Task.yield()
        }
    }
    private func waitForNoViewedSynchronizationTask(in model: ReviewWorkModeModel) async {
        for _ in 0..<100 {
            if model.viewedSynchronizationTaskCountForTesting == 0 { return }
            await Task.yield()
        }
    }
    private func preparedViewedTab(in model: ReviewWorkModeModel) -> ReviewTabState {
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        return tab
    }

    private func preparedReplyTab(in model: ReviewWorkModeModel, body: String) -> ReviewTabState {
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = .init(baseCommit: "base", headCommit: "head")
            $0.loadState = .loaded
            $0.conversations = [Self.conversation]
            $0.replyDrafts = [.init(conversationID: Self.conversation.id, body: body)]
        }
        return tab
    }

    private func prepareViewedTab(in model: ReviewWorkModeModel, revision: ReviewRevision) -> ReviewTabState {
        let tab = model.store.openTab(for: identity)
        model.mutateTab(tab.id) {
            $0.revision = revision
            $0.changedFiles = [.init(path: "Source.swift")]
            $0.loadState = .loaded
        }
        return tab
    }
    private func assertDiffInputCalls(
        model: ReviewWorkModeModel,
        provider: ReviewProviderFake,
        tabID: UUID,
        file: ReviewChangedFile,
        expected: [(path: String, commit: String)]
    ) async throws {
        model.mutateTab(tabID) {
            $0.changedFiles = [file]
            $0.selectedFilePath = file.path
        }
        let previousCount = await provider.fileContentCalls().count
        _ = try await model.diffInput(for: file, in: try #require(model.tab(tabID)))
        let calls = Array((await provider.fileContentCalls()).dropFirst(previousCount))
        #expect(Set(calls.map { "\($0.path)@\($0.commit)" }) == Set(expected.map { "\($0.path)@\($0.commit)" }))
    }
    private func waitForError(in model: ReviewWorkModeModel) async {
        for _ in 0..<100 {
            if model.errorMessage != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    private func waitForAnnouncedHead(_ head: String, tabID: UUID, in model: ReviewWorkModeModel) async {
        for _ in 0..<100 {
            if model.tab(tabID)?.announcedHeadCommit == head { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    private static let conversation = ReviewConversation(
        id: "conversation",
        path: "Source.swift",
        line: 1,
        isResolved: false,
        isOutdated: false,
        comments: [.init(id: "comment", databaseID: 1, author: "author", body: "Published", createdAt: .now)],
        permissions: .init(canReply: true, canResolve: false, canUnresolve: false)
    )
}
private final class ReviewProviderFake: ReviewProviding, @unchecked Sendable {
    enum ReadComponent: CaseIterable {
        case changedFiles, activity, checks, conversations
    }

    let identity: PullRequestIdentity
    private var failure: GitHubCLIProviderError?
    let completeReadFailure: GitHubCLIProviderError?
    let failingReadComponent: ReadComponent?
    let headCommit: String
    let baseCommit: String
    let resolveFailure: GitHubCLIProviderError?
    let viewedFailure: GitHubCLIProviderError?
    let fileContent: Data
    let contentGate: SuspensionGate?
    let changedFiles: [GitHubChangedFile]
    private let recorder = ProviderCallRecorder()
    init(
        identity: PullRequestIdentity,
        failure: GitHubCLIProviderError? = nil,
        completeReadFailure: GitHubCLIProviderError? = nil,
        failingReadComponent: ReadComponent? = nil,
        baseCommit: String = "base",
        headCommit: String = "head",
        resolveFailure: GitHubCLIProviderError? = nil,
        viewedFailure: GitHubCLIProviderError? = nil,
        fileContent: Data = Data(),
        contentGate: SuspensionGate? = nil,
        changedFiles: [GitHubChangedFile] = [
            .init(
                path: "Source.swift", previousPath: nil, status: .modified, additions: 1, deletions: 0,
                isBinary: false, validAnchorCoordinates: [.init(side: .right, line: 1)]
            )
        ]
    ) {
        self.identity = identity
        self.failure = failure
        self.completeReadFailure = completeReadFailure
        self.failingReadComponent = failingReadComponent
        self.baseCommit = baseCommit
        self.headCommit = headCommit
        self.resolveFailure = resolveFailure
        self.viewedFailure = viewedFailure
        self.fileContent = fileContent
        self.contentGate = contentGate
        self.changedFiles = changedFiles
    }
    func resolvedOperations() async -> [(threadID: String, resolved: Bool)] { await recorder.resolutions }
    func metadataCalls() async -> Int { await recorder.metadataCount }
    func submittedReviews() async -> Int { await recorder.submissionCount }
    func fileContentCalls() async -> [(path: String, commit: String)] { await recorder.fileContentCalls }
    func providerWriteCount() async -> Int { await recorder.providerWriteCount }
    func clearFailure() { failure = nil }
    func authenticationStatus(host: String) async throws -> GitHubAccount {
        try failIfNeeded()
        return .init(login: "reviewer", host: host)
    }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        try failIfNeeded()
        await recorder.recordMetadata()
        return .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: baseCommit, headCommit: headCommit, url: URL(string: "https://github.com/argus/app/pull/42")!)
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] {
        try failIfNeeded()
        return [.init(pullRequest: try await pullRequestMetadata(identity), requestedByLogin: nil, latestActivity: nil)]
    }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] {
        try failIfNeeded()
        try failReadComponent(.changedFiles)
        if let completeReadFailure { throw completeReadFailure }
        return changedFiles
    }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] {
        try failIfNeeded()
        try failReadComponent(.activity)
        if let completeReadFailure { throw completeReadFailure }
        return []
    }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        try failIfNeeded()
        try failReadComponent(.checks)
        if let completeReadFailure { throw completeReadFailure }
        return .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: [])
    }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] {
        try failIfNeeded()
        try failReadComponent(.conversations)
        if let completeReadFailure { throw completeReadFailure }
        return []
    }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {
        await recorder.recordProviderWrite()
        if let viewedFailure { throw viewedFailure }
        try failIfNeeded()
    }
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {
        await recorder.recordProviderWrite()
        try failIfNeeded()
    }
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {
        await recorder.recordProviderWrite()
        await recorder.recordResolution(threadID, resolved)
        if let resolveFailure { throw resolveFailure }
        try failIfNeeded()
    }
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {
        await recorder.recordProviderWrite()
        await recorder.recordSubmission()
        try failIfNeeded()
    }
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data {
        try failIfNeeded()
        await recorder.recordFileContent(path: path, commit: commit)
        if let contentGate { await contentGate.wait() }
        return fileContent
    }
    private func failIfNeeded() throws {
        if let failure { throw failure }
    }
    private func failReadComponent(_ component: ReadComponent) throws {
        if failingReadComponent == component {
            throw GitHubCLIProviderError.network("\(component) read failed")
        }
    }
}
private actor ProviderCallRecorder {
    private(set) var resolutions: [(threadID: String, resolved: Bool)] = []
    private(set) var metadataCount = 0
    private(set) var submissionCount = 0
    private(set) var fileContentCalls: [(path: String, commit: String)] = []
    private(set) var providerWriteCount = 0
    func recordResolution(_ threadID: String, _ resolved: Bool) { resolutions.append((threadID, resolved)) }
    func recordMetadata() { metadataCount += 1 }
    func recordSubmission() { submissionCount += 1 }
    func recordFileContent(path: String, commit: String) { fileContentCalls.append((path, commit)) }
    func recordProviderWrite() { providerWriteCount += 1 }
}

private actor CompleteReadBarrier {
    private var arrivals = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        arrivals += 1
        if arrivals == 4 {
            observer?.resume()
            observer = nil
        }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard arrivals < 4 else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class FinalRevisionRaceProvider: ReviewProviding, @unchecked Sendable {
    private let identity: PullRequestIdentity
    private let barrier: CompleteReadBarrier
    private let state = FinalRevisionRaceState()

    init(identity: PullRequestIdentity, barrier: CompleteReadBarrier) {
        self.identity = identity
        self.barrier = barrier
    }

    func advance(to head: String) async { await state.advance(to: head) }
    func failFinalMetadata() async { await state.failFinalMetadata() }
    func providerWriteCount() async -> Int { await state.providerWriteCount }

    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        let result = try await state.metadata(identity: identity)
        return .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: "base", headCommit: result, url: URL(string: "https://github.com/argus/app/pull/42")!)
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] {
        await barrier.wait()
        return [.init(path: "Payload-\(revision.headCommit).swift", validAnchorCoordinates: [.init(side: .right, line: 1)])]
    }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] {
        await barrier.wait()
        return []
    }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        await barrier.wait()
        return .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: [])
    }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] {
        await barrier.wait()
        return []
    }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws { await state.recordProviderWrite() }
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws { await state.recordProviderWrite() }
    func setResolved(threadID: String, resolved: Bool, host: String) async throws { await state.recordProviderWrite() }
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws { await state.recordProviderWrite() }
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}

private actor FinalRevisionRaceState {
    private var head = "a"
    private var metadataCalls = 0
    private var failsFinalMetadata = false
    private(set) var providerWriteCount = 0

    func advance(to head: String) { self.head = head }
    func failFinalMetadata() { failsFinalMetadata = true }
    func metadata(identity: PullRequestIdentity) throws -> String {
        metadataCalls += 1
        if metadataCalls > 1, failsFinalMetadata {
            throw GitHubCLIProviderError.network("final metadata failed")
        }
        return head
    }
    func recordProviderWrite() { providerWriteCount += 1 }
}

private actor RemoteCacheWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        suspended = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false
    private var observer: CheckedContinuation<Void, Never>?
    func wait() async {
        suspended = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
private final class InboxHostProvider: ReviewProviding, @unchecked Sendable {
    private let firstAuthenticationGate: SuspensionGate?
    private let recorder = InboxHostRecorder()

    init(firstAuthenticationGate: SuspensionGate? = nil) {
        self.firstAuthenticationGate = firstAuthenticationGate
    }

    func authenticationHosts() async -> [String] { await recorder.hosts }

    func authenticationStatus(host: String) async throws -> GitHubAccount {
        let call = await recorder.record(host: host)
        if call == 1, let firstAuthenticationGate { await firstAuthenticationGate.wait() }
        return .init(login: "reviewer", host: host)
    }

    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] {
        let identity = PullRequestIdentity(
            repository: .init(host: account.host, owner: "argus", name: "app"),
            number: 42
        )
        let pullRequest = GitHubPullRequest(
            identity: identity,
            nodeID: "node",
            title: "Review",
            state: "open",
            authorLogin: "author",
            baseCommit: "base",
            headCommit: "head",
            url: URL(string: "https://\(account.host)/argus/app/pull/42")!
        )
        return [.init(pullRequest: pullRequest, requestedByLogin: nil, latestActivity: nil)]
    }

    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest { fatalError() }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] { [] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: [])
    }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {}
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}

private actor InboxHostRecorder {
    private(set) var hosts: [String] = []

    func record(host: String) -> Int {
        hosts.append(host)
        return hosts.count
    }
}
private final class SuspendedReviewProvider: ReviewProviding, @unchecked Sendable {
    let identity: PullRequestIdentity
    let submitGate: SuspensionGate
    let replyGate: SuspensionGate?
    private let count = SubmissionCounter()
    private let submittedPendingReviewsRecorder = PendingReviewRecorder()
    private let replies = SubmissionCounter()
    private let replyBodiesRecorder = ReplyBodyRecorder()
    init(identity: PullRequestIdentity, submitGate: SuspensionGate = SuspensionGate(), replyGate: SuspensionGate? = nil) {
        self.identity = identity
        self.submitGate = submitGate
        self.replyGate = replyGate
    }
    func submissionCount() async -> Int { await count.value }
    func submittedPendingReviews() async -> [PendingReview] { await submittedPendingReviewsRecorder.pendingReviews }
    func replyCount() async -> Int { await replies.value }
    func replyBodies() async -> [String] { await replyBodiesRecorder.bodies }
    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest { .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: "base", headCommit: "head", url: URL(string: "https://github.com/argus/app/pull/42")!) }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] { [] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks { .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: []) }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {}
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {
        await replies.increment()
        await replyBodiesRecorder.record(body)
        if let replyGate { await replyGate.wait() }
    }
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {
        await count.increment()
        await submittedPendingReviewsRecorder.record(pendingReview)
        await submitGate.wait()
    }
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}
private final class SuspendedResolutionProvider: ReviewProviding, @unchecked Sendable {
    let identity: PullRequestIdentity
    private let writes = ResolutionWriteRecorder()
    private let failingWrites: [Bool]

    init(identity: PullRequestIdentity, failingWrites: [Bool] = []) {
        self.identity = identity
        self.failingWrites = failingWrites
    }

    func waitUntilWriteSuspended(at index: Int) async { await writes.waitUntilSuspended(at: index) }
    func resumeWrite(at index: Int) async { await writes.resume(at: index) }
    func resolutionOperations() async -> [Bool] { await writes.operations }
    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: "base", headCommit: "head", url: URL(string: "https://github.com/argus/app/pull/42")!)
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] { [] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks { .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: []) }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {}
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {
        let writeIndex = await writes.recordAndWait(resolved)
        if failingWrites.indices.contains(writeIndex), failingWrites[writeIndex] {
            throw GitHubCLIProviderError.network("Resolution write \(writeIndex + 1) failed")
        }
    }
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}
private actor ReplyBodyRecorder {
    private(set) var bodies: [String] = []
    func record(_ body: String) { bodies.append(body) }
}
private actor SubmissionCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
private actor PendingReviewRecorder {
    private(set) var pendingReviews: [PendingReview] = []
    func record(_ pendingReview: PendingReview) { pendingReviews.append(pendingReview) }
}
private final class SerializedViewedProvider: ReviewProviding, @unchecked Sendable {
    private let identity: PullRequestIdentity
    private let writes = ViewedWriteRecorder()
    private let failingWrites: [Bool]
    init(identity: PullRequestIdentity, failingWrites: [Bool] = []) {
        self.identity = identity
        self.failingWrites = failingWrites
    }
    func waitUntilWriteSuspended(at index: Int) async { await writes.waitUntilSuspended(at: index) }
    func resumeWrite(at index: Int) async { await writes.resume(at: index) }
    func viewedOperations() async -> [Bool] { await writes.operations }
    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: "base", headCommit: "head", url: URL(string: "https://github.com/argus/app/pull/42")!)
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] { [] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks { .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: []) }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {
        let writeIndex = await writes.recordAndWait(viewed)
        if failingWrites.indices.contains(writeIndex), failingWrites[writeIndex] {
            throw GitHubCLIProviderError.network("Viewed write \(writeIndex + 1) failed")
        }
    }
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}
private final class SupersededRefreshProvider: ReviewProviding, @unchecked Sendable {
    private let identity: PullRequestIdentity
    private let firstMetadataGate: SuspensionGate
    private let metadataCalls = MetadataCallCounter()
    init(identity: PullRequestIdentity, firstMetadataGate: SuspensionGate) {
        self.identity = identity
        self.firstMetadataGate = firstMetadataGate
    }
    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        if await metadataCalls.next() == 1 {
            await firstMetadataGate.wait()
            return metadata()
        }
        throw GitHubCLIProviderError.network("newer metadata failed")
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws
        -> [GitHubChangedFile]
    { [] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: [])
    }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {}
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
    private func metadata() -> GitHubPullRequest {
        .init(
            identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author",
            baseCommit: "base", headCommit: "head", url: URL(string: "https://github.com/argus/app/pull/42")!
        )
    }
}

private final class RevisionSequenceProvider: ReviewProviding, @unchecked Sendable {
    private let identity: PullRequestIdentity
    private let revisions: [ReviewRevision]
    private let recorder = MetadataCallCounter()

    init(identity: PullRequestIdentity, revisions: [ReviewRevision]) {
        self.identity = identity
        self.revisions = revisions
    }

    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }

    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        let call = await recorder.next()
        let revision = revisions[min(call - 1, revisions.count - 1)]
        return .init(
            identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author",
            baseCommit: revision.baseCommit, headCommit: revision.headCommit,
            url: URL(string: "https://github.com/argus/app/pull/42")!
        )
    }

    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] {
        [.init(path: "\(revision.headCommit).swift", previousPath: nil, status: .modified, additions: 1, deletions: 0, isBinary: false)]
    }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks {
        .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: [])
    }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws {}
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}

private actor MetadataCallCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
private actor ViewedWriteRecorder {
    private(set) var operations: [Bool] = []
    private var gates: [SuspensionGate] = []
    func recordAndWait(_ viewed: Bool) async -> Int {
        let gate = SuspensionGate()
        operations.append(viewed)
        gates.append(gate)
        await gate.wait()
        return operations.count - 1
    }
    func waitUntilSuspended(at index: Int) async {
        while gates.indices.contains(index) == false { await Task.yield() }
        await gates[index].waitUntilSuspended()
    }
    func resume(at index: Int) async {
        guard gates.indices.contains(index) else { return }
        await gates[index].resume()
    }
}
private actor ResolutionWriteRecorder {
    private(set) var operations: [Bool] = []
    private var gates: [SuspensionGate] = []

    func recordAndWait(_ resolved: Bool) async -> Int {
        let gate = SuspensionGate()
        operations.append(resolved)
        gates.append(gate)
        let index = gates.count - 1
        await gate.wait()
        return index
    }
    func waitUntilSuspended(at index: Int) async {
        while gates.indices.contains(index) == false { await Task.yield() }
        await gates[index].waitUntilSuspended()
    }
    func resume(at index: Int) async {
        guard gates.indices.contains(index) else { return }
        await gates[index].resume()
    }
}

private final class RevisionChangingViewedProvider: ReviewProviding, @unchecked Sendable {
    private let identity: PullRequestIdentity
    private let heads: [String]
    private let recorder = RevisionChangingViewedRecorder()

    init(identity: PullRequestIdentity, heads: [String]) {
        self.identity = identity
        self.heads = heads
    }

    func advanceRevision() async { await recorder.advanceRevision() }
    func viewedWriteCount() async -> Int { await recorder.viewedWriteCount }
    func authenticationStatus(host: String) async throws -> GitHubAccount { .init(login: "reviewer", host: host) }
    func pullRequestMetadata(_ identity: PullRequestIdentity) async throws -> GitHubPullRequest {
        let index = await recorder.revisionIndex
        let head = heads[min(index, heads.count - 1)]
        return .init(identity: identity, nodeID: "node", title: "Review", state: "open", authorLogin: "author", baseCommit: "base", headCommit: head, url: URL(string: "https://github.com/argus/app/pull/42")!)
    }
    func reviewInbox(for account: GitHubAccount) async throws -> [GitHubReviewInboxItem] { [] }
    func allChangedFiles(for identity: PullRequestIdentity, at revision: ReviewRevision, pageSize: Int) async throws -> [GitHubChangedFile] { [.init(path: "Source.swift", previousPath: nil, status: .modified, additions: 1, deletions: 0, isBinary: false)] }
    func pullRequestActivity(_ identity: PullRequestIdentity) async throws -> [GitHubPullRequestActivity] { [] }
    func pullRequestChecks(_ identity: PullRequestIdentity) async throws -> GitHubPullRequestChecks { .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checkRuns: []) }
    func publishedReviewConversations(_ identity: PullRequestIdentity) async throws -> [GitHubReviewConversation] { [] }
    func setViewed(path: String, pullRequestNodeID: String, viewed: Bool, host: String) async throws { await recorder.recordViewedWrite() }
    func reply(to commentID: Int, body: String, in identity: PullRequestIdentity) async throws {}
    func setResolved(threadID: String, resolved: Bool, host: String) async throws {}
    func submitReview(identity: PullRequestIdentity, revision: ReviewRevision, pendingReview: PendingReview) async throws {}
    func fileContent(path: String, at commit: String, in repository: RepositoryIdentity) async throws -> Data { Data() }
}

private actor RevisionChangingViewedRecorder {
    private(set) var revisionIndex = 0
    private(set) var viewedWriteCount = 0
    func advanceRevision() { revisionIndex += 1 }
    func recordViewedWrite() { viewedWriteCount += 1 }
}
