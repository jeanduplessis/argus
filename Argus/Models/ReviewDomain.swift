import Foundation

enum WorkMode: String, Codable, CaseIterable, Sendable {
    case code
    case review
}

struct PendingReview: Codable, Hashable, Sendable {
    var revision: ReviewRevision?
    var inlineDrafts: [ReviewInlineDraft]
    var summary: String
    /// Nil is an intentional, unselected Review Disposition. It prevents old
    /// snapshots from being mistaken for an author-confirmed submission choice.
    var disposition: ReviewDisposition?

    init(
        revision: ReviewRevision?, inlineDrafts: [ReviewInlineDraft] = [], summary: String = "",
        disposition: ReviewDisposition? = nil
    ) {
        self.revision = revision
        self.inlineDrafts = inlineDrafts
        self.summary = summary
        self.disposition = disposition
    }

    var hasAuthoredContent: Bool { !inlineDrafts.isEmpty || !summary.isEmpty || disposition != nil }

    private enum CodingKeys: String, CodingKey {
        case revision, inlineDrafts, summary, selectedDisposition
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decodeIfPresent(ReviewRevision.self, forKey: .revision)
        inlineDrafts = try values.decodeIfPresent([ReviewInlineDraft].self, forKey: .inlineDrafts) ?? []
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        // Legacy snapshots recorded `disposition` unconditionally with a
        // default. Only the new field represents explicit author intent.
        disposition = try values.decodeIfPresent(ReviewDisposition.self, forKey: .selectedDisposition)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(revision, forKey: .revision)
        try values.encode(inlineDrafts, forKey: .inlineDrafts)
        try values.encode(summary, forKey: .summary)
        try values.encodeIfPresent(disposition, forKey: .selectedDisposition)
    }

    mutating func reconcileSubmittedContent(_ submitted: PendingReview) {
        inlineDrafts.removeAll { current in
            submitted.inlineDrafts.contains { submittedDraft in
                // Draft IDs alone are not enough: an author can edit or remap a
                // draft while its earlier value is being submitted. Only remove
                // the exact submitted value.
                submittedDraft == current
            }
        }
        if summary == submitted.summary {
            summary = ""
        }
        // A selection made while submission was in flight belongs to the next
        // Pending Review. Clear only the disposition that was actually sent.
        if disposition == submitted.disposition {
            disposition = nil
        }
    }

    func isValidForSubmission(with files: [ReviewChangedFile]) -> Bool {
        guard disposition != nil else { return false }
        return inlineDrafts.allSatisfy { draft in
            guard let file = files.first(where: { $0.path == draft.anchor.path }) else { return false }
            return !draft.requiresRemap
                && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && draft.anchor.isValid(for: file)
        }
    }
}

/// The user-authored portion of a closed Pull Request Review Tab. It remains in
/// Review Session State so closing chrome can never discard unsent work.
struct ReviewAuthoredState: Codable, Hashable, Sendable {
    var replyDrafts: [ReviewReplyDraft] = []
    var pendingReview: PendingReview = .init(revision: nil)
    var pendingViewedIntents: [ReviewViewedIntent] = []

    var hasContent: Bool {
        replyDrafts.contains { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || pendingReview.hasAuthoredContent
            || !pendingViewedIntents.isEmpty
    }

    /// Removes a sent reply only when the current draft is byte-for-byte the
    /// draft captured for that send. Provider delivery may normalize whitespace,
    /// but that normalization must never make a later author edit look unchanged.
    mutating func reconcileSentReply(conversationID: String, body: String) {
        guard let index = replyDrafts.firstIndex(where: { $0.conversationID == conversationID }),
            replyDrafts[index].body == body
        else { return }
        replyDrafts.remove(at: index)
    }

    mutating func reconcileSubmittedReview(_ submitted: PendingReview) {
        pendingReview.reconcileSubmittedContent(submitted)
    }
}

struct ReviewTabState: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let pullRequest: PullRequestIdentity
    var section: ReviewSection
    var revision: ReviewRevision?
    /// A complete provider revision waiting for the author to explicitly adopt
    /// it. `announcedHeadCommit` remains encoded for older session snapshots
    /// and the existing tab chrome.
    var announcedRevision: ReviewRevision?
    var announcedHeadCommit: String?
    var changedFiles: [ReviewChangedFile]
    var selectedFilePath: String?
    var selectedLine: Int?
    var fileFilter: ReviewFileFilter
    var conversations: [ReviewConversation]
    var activity: [ReviewActivityItem]
    var checks: ReviewChecksState?
    var paneState: ReviewPaneState
    var lastSuccessfulRefresh: Date?
    var replyDrafts: [ReviewReplyDraft]
    var pendingReview: PendingReview
    var pendingViewedIntents: [ReviewViewedIntent]
    var loadState: ReviewLoadState
    var attention: ReviewAttention

    init(
        id: UUID = UUID(), pullRequest: PullRequestIdentity, section: ReviewSection = .files,
        revision: ReviewRevision? = nil, changedFiles: [ReviewChangedFile] = [], selectedFilePath: String? = nil,
        fileFilter: ReviewFileFilter = .init(), conversations: [ReviewConversation] = [],
        replyDrafts: [ReviewReplyDraft] = [], activity: [ReviewActivityItem] = [], checks: ReviewChecksState? = nil,
        paneState: ReviewPaneState = .init(), pendingReview: PendingReview = .init(revision: nil),
        pendingViewedIntents: [ReviewViewedIntent] = [],
        loadState: ReviewLoadState = .initialLoading, attention: ReviewAttention = .none
    ) {
        self.id = id
        self.pullRequest = pullRequest
        self.section = section
        self.revision = revision
        self.announcedRevision = nil
        self.announcedHeadCommit = nil
        self.changedFiles = changedFiles
        self.selectedFilePath = selectedFilePath
        self.selectedLine = nil
        self.fileFilter = fileFilter
        self.conversations = conversations
        self.replyDrafts = replyDrafts
        self.activity = activity
        self.checks = checks
        self.paneState = paneState
        self.lastSuccessfulRefresh = nil
        self.pendingReview = pendingReview
        self.pendingViewedIntents = pendingViewedIntents
        self.loadState = loadState
        self.attention = attention
    }

    var hasLocalDrafts: Bool {
        replyDrafts.contains(where: { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || pendingReview.hasAuthoredContent
            || !pendingViewedIntents.isEmpty
    }

    /// A restored Pending Review without an immutable Review Revision cannot be
    /// safely bound to provider data. Its author must explicitly adopt the
    /// loaded revision before any provider write may proceed.
    var pendingReviewRequiresExplicitRevisionAdoption: Bool {
        pendingReview.hasAuthoredContent && pendingReview.revision == nil
    }

    mutating func preserveUnboundPendingReviewForRemap() {
        guard pendingReviewRequiresExplicitRevisionAdoption else { return }
        for index in pendingReview.inlineDrafts.indices {
            pendingReview.inlineDrafts[index].requiresRemap = true
        }
    }

    @discardableResult
    mutating func adoptLoadedRevisionForPendingReview() -> Bool {
        guard pendingReviewRequiresExplicitRevisionAdoption, let revision else { return false }
        pendingReview.revision = revision
        for index in pendingReview.inlineDrafts.indices {
            pendingReview.inlineDrafts[index].requiresRemap = true
        }
        return true
    }

    var authoredState: ReviewAuthoredState {
        .init(replyDrafts: replyDrafts, pendingReview: pendingReview, pendingViewedIntents: pendingViewedIntents)
    }

    mutating func reconcileSentReply(conversationID: String, body: String) {
        var authored = authoredState
        authored.reconcileSentReply(conversationID: conversationID, body: body)
        replyDrafts = authored.replyDrafts
    }

    mutating func reconcileSubmittedReview(_ submitted: PendingReview) {
        pendingReview.reconcileSubmittedContent(submitted)
    }

    mutating func restoreAuthoredState(_ authored: ReviewAuthoredState) {
        replyDrafts = authored.replyDrafts
        pendingReview = authored.pendingReview
        pendingViewedIntents = authored.pendingViewedIntents
        // An authored Pending Review belongs to its original immutable Review
        // Revision. Make that revision the loaded identity until the author
        // explicitly updates and remaps the drafts.
        if let authoredRevision = authored.pendingReview.revision {
            revision = authoredRevision
        }
    }

    /// Provider coordinates are immutable revision data. Authored drafts remain
    /// visible when restored coordinates no longer contain their anchor, but
    /// cannot be submitted until the author remaps them.
    mutating func requireRemapForInvalidInlineDraftAnchors() {
        for index in pendingReview.inlineDrafts.indices {
            let draft = pendingReview.inlineDrafts[index]
            guard let file = changedFiles.first(where: { $0.path == draft.anchor.path }),
                  draft.anchor.isValid(for: file)
            else {
                pendingReview.inlineDrafts[index].requiresRemap = true
                continue
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, pullRequest, section, revision, announcedRevision, announcedHeadCommit, selectedFilePath,
            selectedLine, fileFilter,
            replyDrafts, pendingReview, pendingViewedIntents, loadState, attention, paneState
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        pullRequest = try values.decode(PullRequestIdentity.self, forKey: .pullRequest)
        section = try values.decodeIfPresent(ReviewSection.self, forKey: .section) ?? .files
        revision = try values.decodeIfPresent(ReviewRevision.self, forKey: .revision)
        announcedRevision = try values.decodeIfPresent(ReviewRevision.self, forKey: .announcedRevision)
        announcedHeadCommit = try values.decodeIfPresent(String.self, forKey: .announcedHeadCommit)
        // Snapshots written before complete announced revisions retained only a
        // head. Their loaded base is the only safe base to migrate forward.
        if announcedRevision == nil, let announcedHeadCommit, let revision,
            announcedHeadCommit != revision.headCommit
        {
            announcedRevision = .init(baseCommit: revision.baseCommit, headCommit: announcedHeadCommit)
        }
        if announcedHeadCommit == nil { announcedHeadCommit = announcedRevision?.headCommit }
        // Provider payloads are replaceable cache data, never authoritative
        // Review Session State. Older snapshots may contain them; ignore them.
        changedFiles = []
        selectedFilePath = try values.decodeIfPresent(String.self, forKey: .selectedFilePath)
        selectedLine = try values.decodeIfPresent(Int.self, forKey: .selectedLine)
        fileFilter = try values.decodeIfPresent(ReviewFileFilter.self, forKey: .fileFilter) ?? .init()
        conversations = []
        replyDrafts = try values.decodeIfPresent([ReviewReplyDraft].self, forKey: .replyDrafts) ?? []
        pendingReview =
            try values.decodeIfPresent(PendingReview.self, forKey: .pendingReview) ?? .init(revision: revision)
        pendingViewedIntents = try values.decodeIfPresent([ReviewViewedIntent].self, forKey: .pendingViewedIntents) ?? []
        let persistedLoadState =
            try values.decodeIfPresent(ReviewLoadState.self, forKey: .loadState) ?? .initialLoading
        // Session state deliberately omits provider payloads and the time they
        // were last read. A persisted loaded or refreshing state therefore
        // cannot establish that this tab has complete current data after launch.
        // Retain a valid immutable revision as a stale cache candidate; a tab
        // without one must load from scratch.
        switch persistedLoadState {
        case .loaded, .refreshing:
            loadState = revision?.isValid == true ? .stale : .initialLoading
        case .initialLoading, .stale, .blocked, .failed:
            loadState = persistedLoadState
        }
        attention = try values.decodeIfPresent(ReviewAttention.self, forKey: .attention) ?? .none
        activity = []
        checks = nil
        paneState = try values.decodeIfPresent(ReviewPaneState.self, forKey: .paneState) ?? .init()
        lastSuccessfulRefresh = nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(pullRequest, forKey: .pullRequest)
        try values.encode(section, forKey: .section)
        try values.encodeIfPresent(revision, forKey: .revision)
        try values.encodeIfPresent(announcedRevision, forKey: .announcedRevision)
        try values.encodeIfPresent(announcedHeadCommit, forKey: .announcedHeadCommit)
        try values.encodeIfPresent(selectedFilePath, forKey: .selectedFilePath)
        try values.encodeIfPresent(selectedLine, forKey: .selectedLine)
        try values.encode(fileFilter, forKey: .fileFilter)
        try values.encode(replyDrafts, forKey: .replyDrafts)
        try values.encode(pendingReview, forKey: .pendingReview)
        try values.encode(pendingViewedIntents, forKey: .pendingViewedIntents)
        try values.encode(loadState, forKey: .loadState)
        try values.encode(attention, forKey: .attention)
        try values.encode(paneState, forKey: .paneState)
    }

    mutating func setViewed(_ viewed: Bool, path: String) {
        guard let index = changedFiles.firstIndex(where: { $0.path == path }) else { return }
        changedFiles[index].viewedState = viewed ? .pendingViewed : .pendingUnviewed
    }

    mutating func recordViewedIntent(_ viewed: Bool, path: String, revision: ReviewRevision) {
        let intent = ReviewViewedIntent(revision: revision, path: path, viewed: viewed)
        pendingViewedIntents.removeAll { $0.key == intent.key }
        pendingViewedIntents.append(intent)
        setViewed(viewed, path: path)
    }

    @discardableResult
    mutating func acknowledgeViewedIntent(_ intent: ReviewViewedIntent) -> Bool {
        guard let index = pendingViewedIntents.firstIndex(of: intent) else { return false }
        pendingViewedIntents.remove(at: index)
        acknowledgeViewedSync(path: intent.path, viewed: intent.viewed)
        return true
    }

    mutating func overlayPendingViewedIntents() {
        guard let revision else { return }
        for intent in pendingViewedIntents where intent.revision == revision {
            guard let index = changedFiles.firstIndex(where: { $0.path == intent.path }) else { continue }
            changedFiles[index].viewedState = intent.viewed ? .pendingViewed : .pendingUnviewed
        }
    }

    mutating func acknowledgeViewedSync(path: String, viewed: Bool) {
        guard let index = changedFiles.firstIndex(where: { $0.path == path }) else { return }
        changedFiles[index].viewedState = viewed ? .viewed : .unviewed
    }

    /// Records remote revision availability without replacing the immutable loaded revision.
    mutating func announceNewRevision(_ revision: ReviewRevision) -> ReviewRevisionUpdateOutcome {
        guard revision.isValid, revision != self.revision else { return .unchanged }
        announcedRevision = revision
        announcedHeadCommit = revision.headCommit
        attention = .newCommits
        // A refresh that discovered a new revision must not leave the existing,
        // still-readable Review Revision appearing to load indefinitely.
        loadState = .loaded
        return .staleHeadAvailable
    }

    /// Compatibility entry point for callers that only have a provider head.
    mutating func announceNewHead(_ headCommit: String) -> ReviewRevisionUpdateOutcome {
        guard let loaded = revision else { return .unchanged }
        return announceNewRevision(.init(baseCommit: loaded.baseCommit, headCommit: headCommit))
    }

    var viewedAction: (target: Bool, title: String, status: String) {
        switch changedFiles.first(where: { $0.path == selectedFilePath })?.viewedState {
        case .pendingViewed:
            (true, "Retry Mark Viewed", "Marking viewed is pending; retry Mark Viewed")
        case .pendingUnviewed:
            (false, "Retry Mark Unviewed", "Marking unviewed is pending; retry Mark Unviewed")
        case .viewed:
            (false, "Mark Unviewed", "File is viewed")
        case .unviewed, .none:
            (true, "Mark Viewed", "File is unviewed")
        }
    }

    func nextFile(after path: String?, unviewedOnly: Bool = false) -> ReviewChangedFile? {
        let files = changedFiles.filter { !unviewedOnly || $0.viewedState != .viewed }
        guard !files.isEmpty else { return nil }
        guard let path, let index = files.firstIndex(where: { $0.path == path }) else { return files.first }
        return files[(index + 1) % files.count]
    }

    mutating func updateRevision(to newRevision: ReviewRevision, pathMapping: [String: String])
        -> ReviewRevisionUpdateResult
    {
        guard revision != newRevision else {
            return .init(outcome: .unchanged, mappedDraftIDs: [], unmappedDraftIDs: [])
        }
        var unmapped = Set<UUID>()
        for index in pendingReview.inlineDrafts.indices {
            let path = pendingReview.inlineDrafts[index].anchor.path
            // Changed-file data can establish only a path rename. It supplies no
            // old-line-to-new-line mapping, so even a renamed anchor must remain
            // explicitly remapped before it can be submitted.
            if let mappedPath = pathMapping[path], mappedPath != path {
                pendingReview.inlineDrafts[index].anchor.path = mappedPath
            }
            pendingReview.inlineDrafts[index].requiresRemap = true
            unmapped.insert(pendingReview.inlineDrafts[index].id)
        }
        revision = newRevision
        pendingReview.revision = newRevision
        // Viewed intent cannot be mapped safely across immutable revisions.
        // Retain it for recovery, but never overlay or publish it until the
        // author explicitly makes a new choice for the loaded revision.
        announcedRevision = nil
        announcedHeadCommit = nil
        let outcome: ReviewRevisionUpdateOutcome =
            unmapped.isEmpty ? .updated : .draftsRequireRemap
        return .init(outcome: outcome, mappedDraftIDs: [], unmappedDraftIDs: unmapped)
    }
}

struct ReviewSessionSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 4
    static let defaultInboxHost = "github.com"
    var schemaVersion: Int = currentSchemaVersion
    /// The GitHub host explicitly selected for Review Inbox synchronization.
    /// Older Review Session State did not record a host and defaults to GitHub.com.
    var selectedInboxHost: String
    var selectedPullRequest: PullRequestIdentity?
    var activeTabID: UUID?
    var projects: [ReviewProject]
    var pullRequests: [ReviewPullRequest]
    var tabs: [ReviewTabState]
    var closedAuthoredState: [PullRequestIdentity: ReviewAuthoredState]
    var isRightSidebarVisible: Bool
    var rightSidebarWidth: Double
    var selectedSidebarContext: ReviewSection

    init(
        selectedInboxHost: String = Self.defaultInboxHost,
        selectedPullRequest: PullRequestIdentity? = nil, activeTabID: UUID? = nil,
        projects: [ReviewProject] = [], pullRequests: [ReviewPullRequest] = [], tabs: [ReviewTabState] = [],
        closedAuthoredState: [PullRequestIdentity: ReviewAuthoredState] = [:], isRightSidebarVisible: Bool = false,
        rightSidebarWidth: Double = 250, selectedSidebarContext: ReviewSection = .files
    ) {
        self.selectedInboxHost = Self.normalizedInboxHost(selectedInboxHost)
        self.selectedPullRequest = selectedPullRequest
        self.activeTabID = activeTabID
        self.projects = projects
        self.pullRequests = pullRequests
        self.tabs = tabs
        self.closedAuthoredState = closedAuthoredState
        self.isRightSidebarVisible = isRightSidebarVisible
        self.rightSidebarWidth = rightSidebarWidth
        self.selectedSidebarContext = selectedSidebarContext
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedInboxHost, selectedPullRequest, activeTabID, projects, pullRequests, tabs, closedAuthoredState,
            isRightSidebarVisible, rightSidebarWidth, selectedSidebarContext
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        selectedInboxHost = Self.normalizedInboxHost(
            try values.decodeIfPresent(String.self, forKey: .selectedInboxHost) ?? Self.defaultInboxHost
        )
        selectedPullRequest = try values.decodeIfPresent(PullRequestIdentity.self, forKey: .selectedPullRequest)
        activeTabID = try values.decodeIfPresent(UUID.self, forKey: .activeTabID)
        projects = try values.decodeIfPresent([ReviewProject].self, forKey: .projects) ?? []
        pullRequests = try values.decodeIfPresent([ReviewPullRequest].self, forKey: .pullRequests) ?? []
        tabs = try values.decodeIfPresent([ReviewTabState].self, forKey: .tabs) ?? []
        closedAuthoredState =
            try values.decodeIfPresent([PullRequestIdentity: ReviewAuthoredState].self, forKey: .closedAuthoredState)
            ?? [:]
        isRightSidebarVisible = try values.decodeIfPresent(Bool.self, forKey: .isRightSidebarVisible) ?? false
        rightSidebarWidth = try values.decodeIfPresent(Double.self, forKey: .rightSidebarWidth) ?? 250
        selectedSidebarContext =
            try values.decodeIfPresent(ReviewSection.self, forKey: .selectedSidebarContext) ?? .files
    }

    func reconciledForRestore() -> Self {
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else { return .init() }
        let projectReconciliation = validatedProjectsAndProjectIDRemapping()
        let pullRequests = validatedAndRemappedPullRequests(
            projectsByIdentity: projectReconciliation.projectsByIdentity,
            projectIDRemapping: projectReconciliation.projectIDRemapping
        )
        let tabs = reconciledTabsPreservingAuthoredState()

        return normalizedSelectionAndLayout(
            projectsByIdentity: projectReconciliation.projectsByIdentity,
            pullRequests: pullRequests,
            tabs: tabs
        )
    }

    private func validatedProjectsAndProjectIDRemapping() -> (
        projectsByIdentity: [RepositoryIdentity: ReviewProject],
        projectIDRemapping: [UUID: UUID]
    ) {
        var projectsByIdentity = [RepositoryIdentity: ReviewProject]()
        var projectIDRemapping = [UUID: UUID]()
        for sourceProject in projects {
            guard sourceProject.repositoryIdentity.isValid,
                  sourceProject.providerMetadata.hasSafeAccountLogin
            else { continue }
            var project = sourceProject
            // Repository Identity is the authoritative provider coordinate. A
            // stale metadata provider is repairable without losing account or
            // review state, provided the account login remains safe.
            if project.providerMetadata.provider != project.repositoryIdentity.provider {
                project.providerMetadata = .init(
                    provider: project.repositoryIdentity.provider,
                    accountLogin: project.providerMetadata.accountLogin
                )
            }
            guard project.providerMetadata.isValid else { continue }
            guard projectsByIdentity[project.repositoryIdentity] == nil else {
                projectIDRemapping[project.projectID] = projectsByIdentity[project.repositoryIdentity]!.projectID
                continue
            }
            projectsByIdentity[project.repositoryIdentity] = project
        }
        return (projectsByIdentity, projectIDRemapping)
    }

    private func validatedAndRemappedPullRequests(
        projectsByIdentity: [RepositoryIdentity: ReviewProject],
        projectIDRemapping: [UUID: UUID]
    ) -> [ReviewPullRequest] {
        var seen = Set<PullRequestIdentity>()
        return pullRequests.compactMap { item -> ReviewPullRequest? in
            guard item.identity.isValid, seen.insert(item.identity).inserted else { return nil }
            var item = item
            if let project = projectsByIdentity[item.identity.repository] {
                item.projectID = projectIDRemapping[item.projectID ?? project.projectID] ?? project.projectID
            } else if let projectID = item.projectID, projectIDRemapping[projectID] != nil {
                item.projectID = projectIDRemapping[projectID]
            } else {
                // The referenced project was discarded. Retain the Pull Request
                // and its authored state, but do not preserve a dangling link.
                item.projectID = nil
            }
            if item.projectID == nil, let project = projectsByIdentity[item.identity.repository] {
                item.projectID = project.projectID
            }
            return item
        }
    }

    private func reconciledTabsPreservingAuthoredState() -> [ReviewTabState] {
        var tabIndexes = [PullRequestIdentity: Int]()
        var tabs = [ReviewTabState]()
        for sourceTab in self.tabs {
            guard sourceTab.pullRequest.isValid else { continue }
            if let index = tabIndexes[sourceTab.pullRequest] {
                mergeAuthoredContent(from: sourceTab, into: &tabs[index])
                continue
            }
            tabIndexes[sourceTab.pullRequest] = tabs.count
            tabs.append(sourceTab)
        }
        return tabs.map { tab in
            var tab = tab
            // Changed files are deliberately absent from Review Session State.
            // Keep the tab-local selection until cache or provider data can
            // authoritatively validate it.
            if !tab.changedFiles.isEmpty {
                tab.selectedFilePath =
                    tab.changedFiles.contains(where: { $0.path == tab.selectedFilePath })
                    ? tab.selectedFilePath : tab.changedFiles.first?.path
            }
            if let revision = tab.revision, !revision.isValid { tab.revision = nil }
            if let revision = tab.pendingReview.revision, !revision.isValid { tab.pendingReview.revision = nil }
            tab.pendingViewedIntents = tab.pendingViewedIntents.filter { $0.revision.isValid && !$0.path.isEmpty }
            // Persisted authored content continues to belong to the Review
            // Revision captured when it was created. Do not silently bind it
            // to a newer provider head during the first post-restore load.
            if tab.revision == nil, let authoredRevision = tab.pendingReview.revision,
                tab.pendingReview.hasAuthoredContent
            {
                tab.revision = authoredRevision
            }
            return tab
        }
    }

    private func normalizedSelectionAndLayout(
        projectsByIdentity: [RepositoryIdentity: ReviewProject],
        pullRequests: [ReviewPullRequest],
        tabs: [ReviewTabState]
    ) -> Self {
        let validTabs = tabs.filter { $0.pullRequest.isValid }
        let validIdentities = Set(pullRequests.map(\.identity)).union(validTabs.map(\.pullRequest))
        let selected =
            selectedPullRequest.flatMap { validIdentities.contains($0) ? $0 : nil } ?? validTabs.first?.pullRequest
            ?? pullRequests.first?.identity
        let active =
            activeTabID.flatMap { id in validTabs.contains(where: { $0.id == id }) ? id : nil } ?? validTabs.first?.id
        return .init(
            selectedInboxHost: selectedInboxHost,
            selectedPullRequest: selected,
            activeTabID: active,
            projects: projectsByIdentity.values.filter { $0.repositoryIdentity.isValid }.sorted {
                $0.repositoryIdentity < $1.repositoryIdentity
            },
            pullRequests: pullRequests,
            tabs: tabs,
            closedAuthoredState: closedAuthoredState.filter { $0.key.isValid && $0.value.hasContent },
            isRightSidebarVisible: isRightSidebarVisible,
            rightSidebarWidth: ReviewPaneState.normalizedRightSidebarWidth(rightSidebarWidth),
            selectedSidebarContext: selectedSidebarContext
        )
    }

    private static func normalizedInboxHost(_ host: String) -> String {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? Self.defaultInboxHost : normalized
    }

    /// Normalizes snapshots supplied by a restoration boundary that may not
    /// have passed through ReviewTabState Codable decoding, such as tests or a
    /// future alternate session source.
    func normalizingProviderPayloadLoadStates() -> Self {
        var snapshot = self
        snapshot.tabs = snapshot.tabs.map { tab in
            var tab = tab
            switch tab.loadState {
            case .loaded, .refreshing:
                tab.loadState = tab.revision?.isValid == true ? .stale : .initialLoading
            case .initialLoading, .stale, .blocked, .failed:
                break
            }
            return tab
        }
        return snapshot
    }

    private func mergeAuthoredContent(from source: ReviewTabState, into destination: inout ReviewTabState) {
        // Duplicate tabs reconcile in persisted order: the first retained tab's
        // nonnil revision and Review Disposition win. A later nonnil value fills a
        // gap only. Conflicting revisions cannot establish line mappings, so every
        // inline draft from both tabs remains attached to the retained Pending
        // Review but requires explicit remapping before submission.
        let revisions = Set(
            [
                destination.revision,
                destination.pendingReview.revision,
                source.revision,
                source.pendingReview.revision
            ].compactMap { $0 })
        let retainedRevision =
            destination.revision
            ?? destination.pendingReview.revision
            ?? source.revision
            ?? source.pendingReview.revision
        let revisionsConflict = revisions.count > 1

        if destination.revision == nil { destination.revision = retainedRevision }
        if destination.pendingReview.revision == nil {
            destination.pendingReview.revision = retainedRevision
        }
        if destination.pendingReview.disposition == nil {
            destination.pendingReview.disposition = source.pendingReview.disposition
        }

        if revisionsConflict {
            for index in destination.pendingReview.inlineDrafts.indices {
                destination.pendingReview.inlineDrafts[index].requiresRemap = true
            }
        }
        let existingDraftIDs = Set(destination.pendingReview.inlineDrafts.map(\.id))
        destination.pendingReview.inlineDrafts.append(
            contentsOf: source.pendingReview.inlineDrafts.compactMap { draft in
                guard !existingDraftIDs.contains(draft.id) else { return nil }
                var draft = draft
                if revisionsConflict { draft.requiresRemap = true }
                return draft
            })

        for draft in source.replyDrafts where !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index = destination.replyDrafts.firstIndex(where: { $0.conversationID == draft.conversationID }) {
                if destination.replyDrafts[index].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    destination.replyDrafts[index] = draft
                }
            } else {
                destination.replyDrafts.append(draft)
            }
        }

        let sourceSummary = source.pendingReview.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationSummary = destination.pendingReview.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceSummary.isEmpty, sourceSummary != destinationSummary {
            destination.pendingReview.summary =
                destinationSummary.isEmpty
                ? source.pendingReview.summary
                : "\(destination.pendingReview.summary)\n\n\(source.pendingReview.summary)"
        }
        for intent in source.pendingViewedIntents {
            destination.pendingViewedIntents.removeAll { $0.key == intent.key }
            destination.pendingViewedIntents.append(intent)
        }
    }
}
