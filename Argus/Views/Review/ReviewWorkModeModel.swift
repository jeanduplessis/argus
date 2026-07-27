import Combine
import Foundation
import SwiftUI

@MainActor
final class ReviewWorkModeModel: ObservableObject {
    @Published private(set) var store: ReviewStore
    @Published var errorMessage: String?
    @Published var isRefreshing = false

    let sessionStore: ReviewSessionStore
    private let provider: any ReviewProviding
    private let diffLoader: ReviewDiffLoader
    private let sessionCoordinator: ReviewSessionCoordinator
    private let refreshCoordinator = ReviewRefreshCoordinator()
    private weak var workspaceManager: WorkspaceManager?
    private var storeChangeCancellable: AnyCancellable?
    private var providerWriteCoordinator: ReviewProviderWriteCoordinator!

    /// Test-only visibility into ephemeral Viewed synchronization ownership.
    /// A completed or superseded operation must leave no desired state or task.
    var viewedSynchronizationOperationCountForTesting: Int {
        providerWriteCoordinator.viewedSynchronizationOperationCount
    }

    /// Test-only visibility into active Viewed synchronization tasks. A failed
    /// current intent remains pending without retaining a completed task.
    var viewedSynchronizationTaskCountForTesting: Int {
        providerWriteCoordinator.viewedSynchronizationTaskCount
    }

    private var pendingViewedOperationCount: Int {
        store.session.tabs.reduce(into: 0) { $0 += $1.pendingViewedIntents.count }
            + store.session.closedAuthoredState.values.reduce(into: 0) { $0 += $1.pendingViewedIntents.count }
    }

    init(
        workspaceManager: WorkspaceManager? = nil,
        sessionStore: ReviewSessionStore = ReviewSessionStore(),
        provider: any ReviewProviding = GitHubCLIProvider(),
        restoreSession: (@Sendable () async throws -> ReviewSessionSnapshot)? = nil
    ) {
        self.sessionStore = sessionStore
        self.provider = provider
        self.diffLoader = ReviewDiffLoader(provider: provider)
        self.sessionCoordinator = ReviewSessionCoordinator(
            sessionStore: sessionStore,
            restoreSession: restoreSession ?? { try await sessionStore.restore() }
        )
        self.workspaceManager = workspaceManager
        let store = ReviewStore()
        self.store = store
        observe(store)
        providerWriteCoordinator = ReviewProviderWriteCoordinator(
            provider: provider,
            state: ReviewWriteStateBridge(
                providerWriteTab: { [weak self] in self?.eligibleProviderWriteTab($0) },
                recordViewedIntent: { [weak self] tabID, viewed, path, revision in
                    self?.markLiveMutation()
                    self?.mutateTabWithoutPersist(tabID) {
                        $0.pendingViewedIntents.removeAll { $0.path == path && $0.revision != revision }
                        $0.recordViewedIntent(viewed, path: path, revision: revision)
                    }
                },
                viewedIntent: { [weak self] identity, revision, path in self?.viewedIntent(pullRequest: identity, revision: revision, path: path) },
                currentTabID: { [weak self] identity, revision in self?.currentTabID(pullRequest: identity, revision: revision) },
                matchesTab: { [weak self] tabID, identity, revision in
                    guard let tab = self?.tab(tabID), tab.pullRequest == identity else { return false }
                    return revision.map { tab.revision == $0 } ?? true
                },
                acknowledgeViewedIntent: { [weak self] intent, identity, revision, path in self?.acknowledgeViewedIntent(intent, pullRequest: identity, revision: revision, path: path) },
                announceRevision: { [weak self] revision, tabID in self?.announceNewRevision(revision, in: tabID) },
                reconcileSentReply: { [weak self] identity, conversationID, body in self?.store.reconcileSentReply(identity: identity, conversationID: conversationID, body: body) },
                reconcileSubmittedReview: { [weak self] identity, pending in self?.store.reconcileSubmittedReview(identity: identity, submitted: pending) },
                recordReplyError: { [weak self] tabID, conversationID, message in
                    self?.mutateTab(tabID) { tab in
                        if let index = tab.replyDrafts.firstIndex(where: { $0.conversationID == conversationID }) {
                            tab.replyDrafts[index].lastSendError = message
                        }
                    }
                },
                pendingViewedOperationCount: { [weak self] in self?.pendingViewedOperationCount ?? 0 },
                resolutionWriteStateDidChange: { [weak self] in self?.objectWillChange.send() }
            ),
            effects: ReviewWriteEffects(
                persist: { [weak self] in self?.persistDebounced() },
                refreshTab: { [weak self] in await self?.refreshTab(tabID: $0) },
                reportError: { [weak self] in self?.errorMessage = $0 }
            )
        )
    }

    /// Records a user-confirmed association with a local Named Project. No
    /// identity is inferred from its path, name, or git remote.
    @discardableResult
    func associateRepositoryIdentity(
        _ identity: RepositoryIdentity,
        withNamedProject projectID: UUID
    ) -> Bool {
        let metadata = RepositoryProviderMetadata(provider: identity.provider)
        guard
            let reference = workspaceManager?.associateRepositoryIdentity(
                identity,
                providerMetadata: metadata,
                withNamedProject: projectID
            )
        else { return false }
        _ = store.resolveProject(for: identity, namedProject: reference)
        persistDebounced()
        return true
    }

    func restore() async {
        defer { sessionCoordinator.completeRestore() }
        switch await sessionCoordinator.restoreSnapshot() {
        case .restored(let restored):
            replaceStore(with: ReviewStore(session: restored.normalizingProviderPayloadLoadStates()))
        case .failed(let message):
            errorMessage = message
        case .ignored:
            break
        }
    }

    func persistDebounced() {
        sessionCoordinator.scheduleSave(store.session)
    }

    func setRightSidebar(visible: Bool? = nil, width: CGFloat? = nil, context: ReviewSection? = nil) {
        mutate { snapshot in
            if let visible { snapshot.isRightSidebarVisible = visible }
            if let width {
                snapshot.rightSidebarWidth = ReviewPaneState.normalizedRightSidebarWidth(Double(width))
            }
            if let context { snapshot.selectedSidebarContext = context }
        }
        persistDebounced()
    }

    func flush() {
        let snapshot = store.session
        Task { [weak self] in
            do { try await self?.sessionCoordinator.flush(snapshot) } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Lifecycle owners call this before closing a tab or leaving Review Work Mode.
    func flushSynchronously() {
        sessionCoordinator.flushSynchronously(store.session) { [weak self] message in
            self?.errorMessage = "Could not save Review Session State: \(message)"
        }
    }

    func refreshInbox() async {
        let selectedHost = store.session.selectedInboxHost
        let generation = refreshCoordinator.nextInboxGeneration()
        beginRefresh()
        defer { endRefresh() }
        do {
            let account = try await provider.authenticationStatus(host: selectedHost)
            let inbox = try await provider.reviewInbox(for: account)
            guard refreshCoordinator.acceptsInbox(
                host: account.host,
                account: account.login,
                generation: generation,
                selectedHost: selectedHost
            ) else { return }
            let pullRequests = inbox.map(ReviewProviderMapper.pullRequest).map { item in
                var item = item
                item.projectID =
                    store.resolveProject(
                        for: item.identity.repository,
                        namedProject: workspaceManager?.namedProject(matching: item.identity.repository)
                    ).projectID
                return item
            }
            store.synchronizeInbox(pullRequests, host: account.host)
            persistDebounced()
        } catch {
            guard refreshCoordinator.isCurrentInboxGeneration(generation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func openURL(_ source: String) async {
        guard let url = URL(string: source), let identity = GitHubCLIProvider.parsePullRequestURL(url) else {
            errorMessage = "Enter a canonical GitHub Pull Request URL."
            return
        }
        await open(identity: identity)
    }

    func open(identity: PullRequestIdentity) async {
        let generation = refreshCoordinator.nextTabGeneration(for: identity)
        beginRefresh()
        defer { endRefresh() }
        do {
            let metadata = try await provider.pullRequestMetadata(identity)
            guard generation == refreshCoordinator.currentTabGeneration(for: identity),
                identity.repository.host == metadata.identity.repository.host
            else { return }
            await sessionCoordinator.recordLiveMutationAfterRestore()
            guard generation == refreshCoordinator.currentTabGeneration(for: identity) else { return }
            let existingTab = store.session.tabs.first { $0.pullRequest == identity }
            // Capture this immediately before the intake commit. A failed
            // complete read must leave prior visible content readable, while a
            // partial read is always stale.
            let priorLoadState = existingTab.map(ReviewRemoteCachePolicy.usableLoadStateBeforeOpen)
            let project = store.resolveProject(
                for: identity.repository,
                namedProject: workspaceManager?.namedProject(matching: identity.repository)
            )
            mutate { snapshot in
                let item = ReviewPullRequest(
                    identity: identity, projectID: project.projectID, title: metadata.title,
                    author: metadata.authorLogin ?? "", state: ReviewProviderMapper.pullRequestState(metadata.state), membership: .saved,
                    isManuallySaved: true)
                if let index = snapshot.pullRequests.firstIndex(where: { $0.identity == identity }) {
                    snapshot.pullRequests[index] = item
                } else {
                    snapshot.pullRequests.append(item)
                }
            }
            let tab = store.openTab(for: identity)
            if existingTab?.loadState == .loaded || existingTab?.loadState == .stale {
                store.acknowledgeVisiblePullRequest(identity)
            }
            persistDebounced()
            await refreshTab(
                tabID: tab.id, expectedIdentity: identity, expectedRevision: nil, generation: generation,
                metadata: metadata, priorLoadState: priorLoadState)
        } catch {
            guard generation == refreshCoordinator.currentTabGeneration(for: identity) else { return }
            if let existingTab = store.session.tabs.first(where: { $0.pullRequest == identity }) {
                finalizeOpenFailure(
                    tabID: existingTab.id,
                    identity: identity,
                    generation: generation,
                    priorLoadState: ReviewRemoteCachePolicy.usableLoadStateBeforeOpen(existingTab)
                )
            }
            errorMessage = error.localizedDescription
        }
    }

    func refreshTab(tabID: UUID) async {
        guard let current = tab(tabID) else { return }
        let generation = refreshCoordinator.nextTabGeneration(for: current.pullRequest)
        await refreshTab(
            tabID: tabID, expectedIdentity: current.pullRequest, expectedRevision: current.revision,
            generation: generation, metadata: nil, priorLoadState: nil)
    }

    private func refreshTab(
        tabID: UUID, expectedIdentity: PullRequestIdentity, expectedRevision: ReviewRevision?, generation: UInt64,
        metadata suppliedMetadata: GitHubPullRequest?, priorLoadState: ReviewLoadState?
    ) async {
        let previousLoadState = tab(tabID)?.loadState
        mutateTabWithoutPersist(tabID) { $0.loadState = $0.changedFiles.isEmpty ? .initialLoading : .refreshing }
        var verifiedRevision: ReviewRevision?
        do {
            let metadata: GitHubPullRequest
            if let suppliedMetadata {
                metadata = suppliedMetadata
            } else {
                metadata = try await provider.pullRequestMetadata(expectedIdentity)
            }
            guard let revision = await validateRefreshMetadata(
                metadata,
                tabID: tabID,
                identity: expectedIdentity,
                expectedRevision: expectedRevision,
                generation: generation
            ) else { return }
            verifiedRevision = revision
            try await completeRemoteRead(
                tabID: tabID, identity: expectedIdentity, revision: revision, expectedRevision: expectedRevision,
                generation: generation, priorLoadState: previousLoadState)
        } catch {
            await applyRefreshFailure(
                error, tabID: tabID, identity: expectedIdentity, generation: generation, priorLoadState: priorLoadState,
                expectedCacheRevision: verifiedRevision)
        }
    }

    func updateToAnnouncedRevision(tabID: UUID) async {
        guard let current = tab(tabID) else { return }
        let announced = current.announcedRevision ?? current.announcedHeadCommit.flatMap { head in
            current.revision.map { .init(baseCommit: $0.baseCommit, headCommit: head) }
        }
        guard let announced else { return }
        // Claim ownership before the provider read. An ordinary refresh that
        // began earlier must not be able to apply or cache its older payload
        // while this explicit revision update is in flight.
        let generation = refreshCoordinator.nextTabGeneration(for: current.pullRequest)
        do {
            let metadata = try await provider.pullRequestMetadata(current.pullRequest)
            let revision = ReviewRevision(baseCommit: metadata.baseCommit, headCommit: metadata.headCommit)
            guard
                revision == announced,
                generation == refreshCoordinator.currentTabGeneration(for: current.pullRequest),
                tab(tabID)?.pullRequest == current.pullRequest,
                tab(tabID)?.revision == current.revision
            else { return }
            async let files = provider.allChangedFiles(for: current.pullRequest, at: revision, pageSize: 100)
            async let activity = provider.pullRequestActivity(current.pullRequest)
            async let checks = provider.pullRequestChecks(current.pullRequest)
            async let conversations = provider.publishedReviewConversations(current.pullRequest)
            let payload = try await (files, activity, checks, conversations)
            try await finalizeCompleteRead(
                tabID: tabID, revision: revision, files: payload.0, activity: payload.1, checks: payload.2,
                conversations: payload.3, identity: current.pullRequest, expectedRevision: current.revision,
                generation: generation, adoptsRevision: true, priorLoadState: current.loadState)
        } catch {
            guard generation == refreshCoordinator.currentTabGeneration(for: current.pullRequest) else { return }
            await applyRefreshFailure(
                error, tabID: tabID, identity: current.pullRequest, generation: generation,
                priorLoadState: current.loadState, expectedCacheRevision: announced)
        }
    }

    func setViewed(_ viewed: Bool, path: String, in tabID: UUID) {
        providerWriteCoordinator.setViewed(viewed, path: path, in: tabID)
    }

    func sendReply(conversationID: String, in tabID: UUID) async {
        await providerWriteCoordinator.sendReply(conversationID: conversationID, in: tabID)
    }

    func setResolved(_ resolved: Bool, conversationID: String, in tabID: UUID) async {
        await providerWriteCoordinator.setResolved(resolved, conversationID: conversationID, in: tabID)
    }

    func submitReview(tabID: UUID) async {
        await providerWriteCoordinator.submitReview(in: tabID)
    }

    /// Submits the exact Pending Review the author confirmed. The caller may
    /// continue editing the live Pending Review while the provider write runs;
    /// reconciliation removes only values that exactly match this snapshot.
    func submitReview(tabID: UUID, pendingReview: PendingReview) async {
        await providerWriteCoordinator.submitReview(in: tabID, pendingReview: pendingReview)
    }

    func addInlineDraft(path: String, line: Int, side: ReviewDraftSide, body: String, in tabID: UUID) {
        guard let current = tab(tabID), let file = current.changedFiles.first(where: { $0.path == path }) else {
            errorMessage = "Select a changed file before adding an inline draft."
            return
        }
        let anchor = ReviewDraftAnchor(path: path, line: line, side: side)
        guard anchor.isValid(for: file) else {
            errorMessage = "Choose a changed line from this file's available diff coordinates."
            return
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mutateTab(tabID) {
            $0.pendingReview.inlineDrafts.append(.init(anchor: anchor, body: body))
            $0.selectedLine = line
        }
    }

    func diffInput(for file: ReviewChangedFile, in tab: ReviewTabState) async throws -> ArgusDiffInput {
        guard let revision = tab.revision else {
            throw GitHubCLIProviderError.validation("The Review Revision has not loaded")
        }
        let identity = tab.pullRequest
        return try await diffLoader.load(
            .init(
                file: file,
                tabID: tab.id,
                pullRequest: identity,
                revision: revision,
                theme: GhosttyApp.shared.chromePalette.isDark ? .dark : .light
            ),
            isCurrent: { [weak self] tabID, identity, revision, path in
                self?.tab(tabID)?.pullRequest == identity
                    && self?.tab(tabID)?.revision == revision
                    && self?.tab(tabID)?.selectedFilePath == path
            }
        )
    }

    func mutateTab(_ id: UUID, _ body: (inout ReviewTabState) -> Void) {
        markLiveMutation()
        mutateTabWithoutPersist(id, body)
        persistDebounced()
    }
    func selectTab(_ id: UUID, pullRequest: PullRequestIdentity) {
        mutate {
            $0.activeTabID = id
            $0.selectedPullRequest = pullRequest
        }
        if let tab = tab(id), tab.loadState == .loaded || tab.loadState == .stale {
            store.acknowledgeVisiblePullRequest(pullRequest)
        }
        persistDebounced()
    }

    var inboxHosts: [String] {
        let hosts = Set(store.session.projects.map(\.repositoryIdentity.host))
            .union([ReviewSessionSnapshot.defaultInboxHost])
        return hosts.sorted()
    }

    func selectInboxHost(_ host: String) {
        guard inboxHosts.contains(host), host != store.session.selectedInboxHost else { return }
        _ = refreshCoordinator.nextInboxGeneration()
        mutate { $0.selectedInboxHost = host }
        persistDebounced()
    }
    func closeTab(_ id: UUID) {
        markLiveMutation()
        store.closeTab(id: id)
        flushSynchronously()
    }
    func discardSavedPullRequest(_ identity: PullRequestIdentity) {
        markLiveMutation()
        store.discardSavedPullRequest(identity)
        flush()
    }
    func moveTab(_ id: UUID, to destination: Int) {
        markLiveMutation()
        store.moveTab(id: id, to: destination)
        persistDebounced()
    }
    func selectRelativeTab(_ offset: Int) {
        markLiveMutation()
        store.selectRelativeTab(offset)
        persistDebounced()
    }
    func selectFile(_ path: String, line: Int? = nil, in tabID: UUID) {
        mutateTab(tabID) { tab in
            tab.section = .files
            tab.selectedFilePath = path
            tab.selectedLine = line
            tab.paneState.conversationsCollapsed = false
        }
    }
    /// Explicitly binds a restored Pending Review to the loaded Review Revision.
    /// Inline drafts still require author remapping before submission.
    @discardableResult
    func adoptLoadedRevisionForPendingReview(in tabID: UUID) -> Bool {
        guard tab(tabID)?.pendingReviewRequiresExplicitRevisionAdoption == true else { return false }
        mutateTab(tabID) { _ = $0.adoptLoadedRevisionForPendingReview() }
        return true
    }
    func tab(_ id: UUID) -> ReviewTabState? { store.session.tabs.first { $0.id == id } }

    private func applyCompleteRead(
        tabID: UUID,
        revision: ReviewRevision,
        files: [GitHubChangedFile],
        activity: [GitHubPullRequestActivity],
        checks: GitHubPullRequestChecks,
        conversations: [GitHubReviewConversation]
    ) {
        mutateTabWithoutPersist(tabID) { tab in
            tab.revision = revision
            if tab.pendingReviewRequiresExplicitRevisionAdoption {
                tab.preserveUnboundPendingReviewForRemap()
            } else {
                tab.pendingReview.revision = revision
            }
            tab.conversations = conversations.map(ReviewProviderMapper.conversation)
            tab.changedFiles = files.map(ReviewProviderMapper.file).map { file in
                var file = file
                let related = tab.conversations.filter { $0.path == file.path }
                file.publishedConversationCount = related.count
                file.hasUnresolvedConversation = related.contains { !$0.isResolved }
                let conversationIDs = Set(related.map(\.id))
                file.hasLocalDraft =
                    tab.pendingReview.inlineDrafts.contains { $0.anchor.path == file.path }
                    || tab.replyDrafts.contains {
                        !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && conversationIDs.contains($0.conversationID)
                    }
                return file
            }
            tab.requireRemapForInvalidInlineDraftAnchors()
            tab.activity = activity.map {
                .init(
                    id: $0.id,
                    kind: $0.kind.rawValue,
                    author: $0.authorLogin,
                    body: $0.body,
                    createdAt: $0.createdAt
                )
            }
            tab.checks = .init(
                mergeable: checks.mergeable,
                mergeStateStatus: checks.mergeStateStatus,
                reviewDecision: checks.reviewDecision,
                checks: checks.checkRuns.map {
                    .init(
                        id: $0.id,
                        name: $0.name,
                        status: $0.status,
                        conclusion: $0.conclusion
                    )
                }
            )
            tab.selectedFilePath =
                tab.changedFiles.contains(where: {
                    $0.path == tab.selectedFilePath
                }) ? tab.selectedFilePath : tab.changedFiles.first?.path
            tab.loadState = .loaded
            tab.lastSuccessfulRefresh = Date()
            tab.overlayPendingViewedIntents()
        }
    }
    private func applyCachedRead(
        _ cache: ReviewRemoteCache,
        tabID: UUID,
        loadState: ReviewLoadState
    ) {
        mutateTabWithoutPersist(tabID) {
            ReviewRemoteCachePolicy.hydrating(&$0, from: cache, loadState: loadState)
            $0.requireRemapForInvalidInlineDraftAnchors()
            $0.overlayPendingViewedIntents()
        }
    }
    private func mutate(_ body: (inout ReviewSessionSnapshot) -> Void) {
        sessionCoordinator.recordLiveMutation()
        var snapshot = store.session
        body(&snapshot)
        replaceStore(with: ReviewStore(session: snapshot))
    }
    private func mutateTabWithoutPersist(_ id: UUID, _ body: (inout ReviewTabState) -> Void) {
        mutate { snapshot in
            guard let index = snapshot.tabs.firstIndex(where: { $0.id == id }) else { return }
            body(&snapshot.tabs[index])
        }
    }
    private func markLiveMutation() { sessionCoordinator.recordLiveMutation() }
    func isSubmittingReview(in tabID: UUID) -> Bool {
        guard let pullRequest = tab(tabID)?.pullRequest else { return false }
        return providerWriteCoordinator.isSubmittingReview(for: pullRequest)
    }
    func isSendingReply(conversationID: String, in tabID: UUID) -> Bool {
        providerWriteCoordinator.isSendingReply(conversationID: conversationID, in: tabID, pullRequest: tab(tabID)?.pullRequest)
    }
    func isSettingResolution(conversationID: String, in tabID: UUID) -> Bool {
        providerWriteCoordinator.isSettingResolution(
            conversationID: conversationID, in: tabID, pullRequest: tab(tabID)?.pullRequest)
    }
    func isProviderWriteEligible(in tabID: UUID) -> Bool {
        guard let tab = tab(tabID), tab.revision != nil else { return false }
        return tab.loadState == .loaded
            && tab.announcedRevision == nil
            && !tab.pendingReviewRequiresExplicitRevisionAdoption
    }
    private func eligibleProviderWriteTab(_ tabID: UUID) -> ReviewTabState? {
        guard isProviderWriteEligible(in: tabID), let current = tab(tabID) else {
            errorMessage =
                "Provider writes require a complete, current Review Revision. Refresh or update this Pull Request before sending changes."
            return nil
        }
        return current
    }
    private func validateRefreshMetadata(
        _ metadata: GitHubPullRequest,
        tabID: UUID,
        identity: PullRequestIdentity,
        expectedRevision: ReviewRevision?,
        generation: UInt64
    ) async -> ReviewRevision? {
        let providerRevision = ReviewRevision(baseCommit: metadata.baseCommit, headCommit: metadata.headCommit)
        guard
            let current = tab(tabID),
            current.pullRequest == identity,
            generation == refreshCoordinator.currentTabGeneration(for: identity)
        else {
            return nil
        }
        if let loaded = current.revision, loaded != providerRevision {
            announceNewRevision(providerRevision, in: tabID)
            if current.changedFiles.isEmpty,
                let cache = try? await sessionStore.readRemoteCache(for: identity),
                ReviewRemoteCachePolicy.canApply(cache, to: current),
                let live = tab(tabID), live.pullRequest == identity, live.revision == loaded,
            generation == refreshCoordinator.currentTabGeneration(for: identity)
            {
                // Metadata confirms this exact retained revision. The newer
                // announced revision still independently blocks writes.
                applyCachedRead(cache, tabID: tabID, loadState: .loaded)
            }
            persistDebounced()
            return nil
        }
        return expectedRevision ?? providerRevision
    }
    private func completeRemoteRead(
        tabID: UUID,
        identity: PullRequestIdentity,
        revision: ReviewRevision,
        expectedRevision: ReviewRevision?,
        generation: UInt64,
        priorLoadState: ReviewLoadState?
    ) async throws {
        async let files = provider.allChangedFiles(for: identity, at: revision, pageSize: 100)
        async let activity = provider.pullRequestActivity(identity)
        async let checks = provider.pullRequestChecks(identity)
        async let conversations = provider.publishedReviewConversations(identity)
        let payload = try await (files, activity, checks, conversations)
        try await finalizeCompleteRead(
            tabID: tabID, revision: revision, files: payload.0, activity: payload.1, checks: payload.2,
            conversations: payload.3, identity: identity, expectedRevision: expectedRevision,
            generation: generation, adoptsRevision: false, priorLoadState: priorLoadState)
    }

    /// Applies every successful complete provider read through one ordered path.
    /// Payload becomes visible before Review Session State is persisted, while
    /// the cache write is awaited so callers can observe its completion.
    private func finalizeCompleteRead(
        tabID: UUID,
        revision: ReviewRevision,
        files: [GitHubChangedFile],
        activity: [GitHubPullRequestActivity],
        checks: GitHubPullRequestChecks,
        conversations: [GitHubReviewConversation],
        identity: PullRequestIdentity,
        expectedRevision: ReviewRevision?,
        generation: UInt64,
        adoptsRevision: Bool,
        priorLoadState: ReviewLoadState?
    ) async throws {
        let finalMetadata = try await provider.pullRequestMetadata(identity)
        let finalRevision = ReviewRevision(baseCommit: finalMetadata.baseCommit, headCommit: finalMetadata.headCommit)
        guard
            let live = tab(tabID),
            live.pullRequest == identity,
            generation == refreshCoordinator.currentTabGeneration(for: identity),
            live.revision == expectedRevision || expectedRevision == nil
        else { return }
        guard finalRevision == revision else {
            finalizeRevisionMismatch(
                finalRevision, tabID: tabID, identity: identity, generation: generation,
                previousLoadState: priorLoadState)
            return
        }
        if adoptsRevision {
            // Rename and copy status does not establish a safe line mapping.
            _ = store.updateRevision(tabID: tabID, to: revision, pathMapping: [:])
        }
        applyCompleteRead(
            tabID: tabID, revision: revision, files: files, activity: activity, checks: checks,
            conversations: conversations)
        store.acknowledgeVisiblePullRequest(identity)
        guard
            let completed = tab(tabID),
            completed.pullRequest == identity,
            completed.revision == revision,
            completed.announcedRevision == nil,
            generation == refreshCoordinator.currentTabGeneration(for: identity)
        else { return }
        let cache = ReviewRemoteCache(
            pullRequest: identity, revision: revision, changedFiles: completed.changedFiles,
            conversations: completed.conversations, activity: completed.activity,
            checks: completed.checks ?? .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
            savedAt: Date())
        // The complete payload has been applied before persistence. A cache
        // failure is non-authoritative: retain the loaded revision and drafts.
        persistDebounced()
        do {
            try await sessionStore.writeRemoteCache(cache, owner: identity, generation: generation)
        } catch {
            guard generation == refreshCoordinator.currentTabGeneration(for: identity) else { return }
            errorMessage = "Could not cache Pull Request data: \(error.localizedDescription)"
        }
    }
    private func finalizeRevisionMismatch(
        _ announcedRevision: ReviewRevision,
        tabID: UUID,
        identity: PullRequestIdentity,
        generation: UInt64,
        previousLoadState: ReviewLoadState?
    ) {
        guard
            generation == refreshCoordinator.currentTabGeneration(for: identity),
            let live = tab(tabID),
            live.pullRequest == identity
        else { return }
        announceNewRevision(announcedRevision, in: tabID)
        mutateTabWithoutPersist(tabID) { tab in
            switch previousLoadState {
            case .loaded?:
                tab.loadState = .loaded
            case .stale?:
                tab.loadState = .stale
            default:
                tab.loadState = live.changedFiles.isEmpty ? .failed : .stale
            }
        }
        persistDebounced()
    }
    private func applyRefreshFailure(
        _ error: Error, tabID: UUID, identity: PullRequestIdentity, generation: UInt64,
        priorLoadState: ReviewLoadState?, expectedCacheRevision: ReviewRevision?
    ) async {
        guard
            generation == refreshCoordinator.currentTabGeneration(for: identity),
            let live = tab(tabID),
            live.pullRequest == identity
        else { return }
        if live.changedFiles.isEmpty {
            if let cache = try? await sessionStore.readRemoteCache(for: identity),
                ReviewRemoteCachePolicy.canApply(cache, to: live, expectedRevision: expectedCacheRevision)
            {
                // A provider read failed. Cached content remains readable, but
                // cannot establish provider-write eligibility on its own.
                applyCachedRead(cache, tabID: tabID, loadState: .stale)
            } else {
                mutateTabWithoutPersist(tabID) { $0.loadState = .failed }
            }
        } else {
            // Any failure after a partial provider read invalidates provider
            // write eligibility, even when intake had readable content first.
            mutateTabWithoutPersist(tabID) { $0.loadState = .stale }
        }
        errorMessage = error.localizedDescription
    }
    private func finalizeOpenFailure(
        tabID: UUID,
        identity: PullRequestIdentity,
        generation: UInt64,
        priorLoadState: ReviewLoadState?
    ) {
        guard
            generation == refreshCoordinator.currentTabGeneration(for: identity),
            let live = tab(tabID),
            live.pullRequest == identity
        else { return }
        let finalState: ReviewLoadState
        switch priorLoadState {
        case .loaded?, .stale?:
            finalState = priorLoadState!
        default:
            finalState = live.changedFiles.isEmpty ? .failed : .stale
        }
        mutateTabWithoutPersist(tabID) { $0.loadState = finalState }
    }
    private func beginRefresh() {
        isRefreshing = refreshCoordinator.beginRefresh()
    }
    private func endRefresh() {
        isRefreshing = refreshCoordinator.endRefresh()
    }
    private func observe(_ store: ReviewStore) {
        storeChangeCancellable = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func replaceStore(with store: ReviewStore) {
        self.store = store
        observe(store)
    }

    private func announceNewRevision(_ revision: ReviewRevision, in tabID: UUID) {
        mutateTabWithoutPersist(tabID) { _ = $0.announceNewRevision(revision) }
    }

    private func viewedIntent(
        pullRequest: PullRequestIdentity,
        revision: ReviewRevision,
        path: String
    ) -> ReviewViewedIntent? {
        let intent = store.session.tabs.first(where: {
            $0.pullRequest == pullRequest && $0.revision == revision
        })?.pendingViewedIntents.first {
            $0.revision == revision && $0.path == path
        }
        return intent ?? store.session.closedAuthoredState[pullRequest]?.pendingViewedIntents.first {
            $0.revision == revision && $0.path == path
        }
    }

    private func acknowledgeViewedIntent(
        _ intent: ReviewViewedIntent,
        pullRequest: PullRequestIdentity,
        revision: ReviewRevision,
        path: String
    ) {
        if let tabID = currentTabID(pullRequest: pullRequest, revision: revision) {
            mutateTabWithoutPersist(tabID) { _ = $0.acknowledgeViewedIntent(intent) }
            return
        }
        mutate { snapshot in
            guard var authored = snapshot.closedAuthoredState[pullRequest],
                let index = authored.pendingViewedIntents.firstIndex(of: intent)
            else { return }
            authored.pendingViewedIntents.remove(at: index)
            if authored.hasContent {
                snapshot.closedAuthoredState[pullRequest] = authored
            } else {
                snapshot.closedAuthoredState.removeValue(forKey: pullRequest)
            }
        }
    }

    private func currentTabID(pullRequest: PullRequestIdentity, revision: ReviewRevision) -> UUID? {
        store.session.tabs.first {
            $0.pullRequest == pullRequest && $0.revision == revision
        }?.id
    }
}
