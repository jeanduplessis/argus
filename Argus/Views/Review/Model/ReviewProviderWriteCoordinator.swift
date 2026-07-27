import Foundation

@MainActor
struct ReviewWriteStateBridge {
    let providerWriteTab: (UUID) -> ReviewTabState?
    let recordViewedIntent: (UUID, Bool, String, ReviewRevision) -> Void
    let viewedIntent: (PullRequestIdentity, ReviewRevision, String) -> ReviewViewedIntent?
    let currentTabID: (PullRequestIdentity, ReviewRevision) -> UUID?
    let matchesTab: (UUID, PullRequestIdentity, ReviewRevision?) -> Bool
    let acknowledgeViewedIntent: (ReviewViewedIntent, PullRequestIdentity, ReviewRevision, String) -> Void
    let announceRevision: (ReviewRevision, UUID) -> Void
    let reconcileSentReply: (PullRequestIdentity, String, String) -> Void
    let reconcileSubmittedReview: (PullRequestIdentity, PendingReview) -> Void
    let recordReplyError: (UUID, String, String) -> Void
    let pendingViewedOperationCount: () -> Int
    let resolutionWriteStateDidChange: () -> Void
}

@MainActor
struct ReviewWriteEffects {
    let persist: () -> Void
    let refreshTab: (UUID) async -> Void
    let reportError: (String) -> Void
}

@MainActor
final class ReviewProviderWriteCoordinator {
    private struct ReplyOperationKey: Hashable {
        let pullRequest: PullRequestIdentity
        let conversationID: String
    }

    private struct ViewedOperationKey: Hashable {
        let pullRequest: PullRequestIdentity
        let revision: ReviewRevision
        let path: String
    }

    private struct ResolutionOperationKey: Hashable {
        let pullRequest: PullRequestIdentity
        let conversationID: String
    }

    private struct ReviewSubmissionOperation {
        let pullRequest: PullRequestIdentity
        let revision: ReviewRevision
        let pendingReview: PendingReview
    }

    private let provider: any ReviewProviding
    private let state: ReviewWriteStateBridge
    private let effects: ReviewWriteEffects

    private var reviewSubmissions = [PullRequestIdentity: ReviewSubmissionOperation]()
    private var sentReplies = [ReplyOperationKey: String]()
    private var viewedSyncTasks = [ViewedOperationKey: Task<Void, Never>]()
    private var resolutionWrites = Set<ResolutionOperationKey>()

    init(
        provider: any ReviewProviding,
        state: ReviewWriteStateBridge,
        effects: ReviewWriteEffects
    ) {
        self.provider = provider
        self.state = state
        self.effects = effects
    }

    var viewedSynchronizationOperationCount: Int {
        state.pendingViewedOperationCount() + viewedSyncTasks.keys.filter {
            state.viewedIntent($0.pullRequest, $0.revision, $0.path) == nil
        }.count
    }
    var viewedSynchronizationTaskCount: Int { viewedSyncTasks.count }

    func setViewed(_ viewed: Bool, path: String, in tabID: UUID) {
        guard let current = state.providerWriteTab(tabID), let revision = current.revision else { return }
        let operation = ViewedOperationKey(pullRequest: current.pullRequest, revision: revision, path: path)
        state.recordViewedIntent(tabID, viewed, path, revision)
        effects.persist()
        guard viewedSyncTasks[operation] == nil else { return }
        viewedSyncTasks[operation] = Task { [weak self] in
            await self?.synchronizeViewed(operation)
        }
    }

    func sendReply(conversationID: String, in tabID: UUID) async {
        guard let current = state.providerWriteTab(tabID),
            let index = current.replyDrafts.firstIndex(where: { $0.conversationID == conversationID }),
            let conversation = current.conversations.first(where: { $0.id == conversationID }),
            let commentID = conversation.comments.last?.databaseID
        else { return }
        let originalBody = current.replyDrafts[index].body
        let providerBody = originalBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerBody.isEmpty else { return }
        let operation = ReplyOperationKey(pullRequest: current.pullRequest, conversationID: conversationID)
        guard sentReplies[operation] == nil else { return }
        sentReplies[operation] = originalBody
        defer { sentReplies.removeValue(forKey: operation) }
        do {
            try await provider.reply(to: commentID, body: providerBody, in: current.pullRequest)
            state.reconcileSentReply(current.pullRequest, conversationID, originalBody)
            effects.persist()
            if state.matchesTab(tabID, current.pullRequest, nil) {
                await effects.refreshTab(tabID)
            }
        } catch {
            state.recordReplyError(tabID, conversationID, error.localizedDescription)
            effects.reportError(error.localizedDescription)
        }
    }

    func setResolved(_ resolved: Bool, conversationID: String, in tabID: UUID) async {
        guard let current = state.providerWriteTab(tabID),
            let conversation = current.conversations.first(where: { $0.id == conversationID }),
            resolved ? conversation.permissions.canResolve : conversation.permissions.canUnresolve
        else { return }
        let operation = ResolutionOperationKey(pullRequest: current.pullRequest, conversationID: conversationID)
        guard resolutionWrites.insert(operation).inserted else { return }
        state.resolutionWriteStateDidChange()
        defer {
            resolutionWrites.remove(operation)
            state.resolutionWriteStateDidChange()
        }
        do {
            try await provider.setResolved(
                threadID: conversationID, resolved: resolved, host: current.pullRequest.repository.host)
            if state.matchesTab(tabID, current.pullRequest, nil) {
                await effects.refreshTab(tabID)
            }
        } catch {
            effects.reportError(error.localizedDescription)
        }
    }

    func submitReview(in tabID: UUID, pendingReview confirmedPendingReview: PendingReview? = nil) async {
        guard let current = state.providerWriteTab(tabID) else { return }
        let pendingReview = confirmedPendingReview ?? current.pendingReview
        guard let revision = pendingReview.revision, revision == current.revision
        else { return }
        guard pendingReview.disposition != nil else {
            effects.reportError("Select a Review Disposition before submitting.")
            return
        }
        guard pendingReview.isValidForSubmission(with: current.changedFiles) else {
            effects.reportError("Inline drafts require a positive line and a valid diff side before submission.")
            return
        }
        guard reviewSubmissions[current.pullRequest] == nil else { return }
        let operation = ReviewSubmissionOperation(
            pullRequest: current.pullRequest,
            revision: revision,
            pendingReview: pendingReview
        )
        reviewSubmissions[operation.pullRequest] = operation
        defer { reviewSubmissions.removeValue(forKey: operation.pullRequest) }
        do {
            try await provider.submitReview(
                identity: operation.pullRequest,
                revision: operation.revision,
                pendingReview: operation.pendingReview
            )
            state.reconcileSubmittedReview(operation.pullRequest, operation.pendingReview)
            effects.persist()
            if state.matchesTab(tabID, operation.pullRequest, operation.revision) {
                await effects.refreshTab(tabID)
            }
        } catch {
            effects.reportError(error.localizedDescription)
        }
    }

    func isSubmittingReview(for pullRequest: PullRequestIdentity?) -> Bool {
        pullRequest.map { reviewSubmissions[$0] != nil } ?? false
    }

    func isSendingReply(conversationID: String, in tabID: UUID, pullRequest: PullRequestIdentity?) -> Bool {
        guard let pullRequest else { return false }
        return sentReplies[.init(pullRequest: pullRequest, conversationID: conversationID)] != nil
    }

    func isSettingResolution(conversationID: String, in tabID: UUID, pullRequest: PullRequestIdentity?) -> Bool {
        guard let pullRequest else { return false }
        return resolutionWrites.contains(.init(pullRequest: pullRequest, conversationID: conversationID))
    }

    private func synchronizeViewed(_ operation: ViewedOperationKey) async {
        defer { viewedSyncTasks.removeValue(forKey: operation) }
        while let desired = state.viewedIntent(operation.pullRequest, operation.revision, operation.path)?.viewed {
            guard state.currentTabID(operation.pullRequest, operation.revision) != nil else { return }
            do {
                let metadata = try await provider.pullRequestMetadata(operation.pullRequest)
                let metadataRevision = ReviewRevision(baseCommit: metadata.baseCommit, headCommit: metadata.headCommit)
                guard let tabID = state.currentTabID(operation.pullRequest, operation.revision) else { return }
                guard metadataRevision == operation.revision else {
                    state.announceRevision(metadataRevision, tabID)
                    effects.persist()
                    return
                }
                try await provider.setViewed(
                    path: operation.path, pullRequestNodeID: metadata.nodeID, viewed: desired,
                    host: operation.pullRequest.repository.host)
                guard state.viewedIntent(operation.pullRequest, operation.revision, operation.path)?.viewed == desired else { continue }
                state.acknowledgeViewedIntent(
                    .init(revision: operation.revision, path: operation.path, viewed: desired),
                    operation.pullRequest, operation.revision, operation.path)
                effects.persist()
            } catch {
                guard state.viewedIntent(operation.pullRequest, operation.revision, operation.path)?.viewed == desired else { continue }
                effects.reportError(error.localizedDescription)
                return
            }
        }
    }
}
