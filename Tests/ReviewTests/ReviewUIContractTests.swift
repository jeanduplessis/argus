import Foundation
import Testing

@testable import Argus

@Suite
struct ReviewUIContractTests {
    @Test
    @MainActor func reviewWorkModePreservesReusablePullRequestTabs() {
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "argus", name: "app"), number: 42)
        let store = ReviewStore()
        let first = store.openTab(for: identity)
        let second = store.openTab(for: identity)

        #expect(first.id == second.id)
        #expect(store.session.tabs.count == 1)
        #expect(store.session.selectedPullRequest == identity)
    }

    @Test
    @MainActor func reviewedFileRequiresExplicitMutation() {
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "argus", name: "app"), number: 42)
        let store = ReviewStore(session: .init(tabs: [.init(pullRequest: identity, changedFiles: [.init(path: "Source.swift")])]))
        let tab = try! #require(store.session.tabs.first)

        #expect(tab.changedFiles[0].viewedState == .unviewed)
        store.setViewed(true, path: "Source.swift", in: tab.id)
        #expect(store.session.tabs[0].changedFiles[0].viewedState == .pendingViewed)
    }

    @Test
    func inboxAttentionIsAssignedByStoreInsertionAndClearedWhenVisible() throws {
        let mapper = try SourceContract("Argus/Views/Review/Model/ReviewProviderMapper.swift")
        let store = try SourceContract("Argus/Services/ReviewStore.swift")
        let model = try SourceContract("Argus/Views/Review/ReviewWorkModeModel.swift")

        mapper.excludes("attention: .newRequest", "Mapper must not assign discovery attention")
        store.contains("item.attention = .newRequest", "Only newly inserted Inbox identities receive discovery attention")
        store.contains("func acknowledgeVisiblePullRequest", "Store owns discovery-attention acknowledgment")
        model.contains("store.acknowledgeVisiblePullRequest(identity)", "A complete relevant Pull Request refresh clears discovery attention")
    }

    @Test
    func reviewInboxHostIsExplicitAndPickerOnlyAppearsForMultipleKnownHosts() throws {
        let domain = try SourceContract("Argus/Models/ReviewDomain.swift")
        let model = try SourceContract("Argus/Views/Review/ReviewWorkModeModel.swift")
        let view = try SourceContract("Argus/Views/Review/ReviewWorkModeView.swift")

        domain.contains("var selectedInboxHost: String", "Review Session State persists the selected Inbox host")
        domain.contains("static let defaultInboxHost = \"github.com\"", "Legacy Review Session State defaults to GitHub.com")
        model.contains("provider.authenticationStatus(host: selectedHost)", "Inbox refresh authenticates the selected host")
        model.contains("var inboxHosts: [String]", "Known Review Project hosts supply host choices")
        view.contains("if model.inboxHosts.count > 1", "Host picker appears only when there are multiple supported hosts")
    }

    @Test
    @MainActor func revisionUpdateDoesNotReplaceLoadedRevisionUntilExplicitlyRequested() {
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "argus", name: "app"), number: 42)
        let old = ReviewRevision(baseCommit: "base", headCommit: "old")
        let store = ReviewStore(session: .init(tabs: [.init(pullRequest: identity, revision: old)]))
        let tab = try! #require(store.session.tabs.first)

        #expect(store.announceNewHead("new", in: tab.id) == .staleHeadAvailable)
        #expect(store.session.tabs[0].revision == old)
        #expect(store.session.tabs[0].announcedHeadCommit == "new")
    }

    @Test
    func modeSwitchSourceFlushesReviewStateBeforePersistingSelection() throws {
        let source = try SourceContract("Argus/Views/MainWindowView.swift")
        let switcher = try source.section(after: "private func selectWorkMode", before: "\n    }\n}")

        #expect(switcher.contains("reviewWorkMode.flushSynchronously()"))
        #expect(switcher.contains("storedWorkMode = destination.rawValue"))
        let flush = try #require(switcher.range(of: "reviewWorkMode.flushSynchronously()"))
        let selection = try #require(switcher.range(of: "storedWorkMode = destination.rawValue"))
        #expect(flush.lowerBound < selection.lowerBound)
    }

    @Test
    func workModeStorageUsesOneKeyDefaultAndParseContract() throws {
        #expect(WorkModeStorage.key == "Argus.workMode")
        #expect(WorkModeStorage.defaultValue == WorkMode.code.rawValue)
        #expect(WorkModeStorage.parse(nil) == .code)
        #expect(WorkModeStorage.parse("invalid") == .code)
        #expect(WorkModeStorage.parse(WorkMode.review.rawValue) == .review)

        let mainWindow = try SourceContract("Argus/Views/MainWindowView.swift")
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        mainWindow.contains("@AppStorage(WorkModeStorage.key) private var storedWorkMode = WorkModeStorage.defaultValue", "Main window observes the centralized Work Mode storage key and default")
        mainWindow.contains("WorkModeStorage.parse(storedWorkMode)", "Main window parses stored Work Mode values through the shared contract")
        app.contains("WorkModeStorage.read() == .review", "App command routing reads Work Mode through the shared contract")
    }

    @Test
    func globalTabCommandsRouteByActiveWorkModeWithoutMutatingHiddenTabs() {
        #expect(WorkModeTabCommandRouter.route(.close, in: .review) == .closeReviewTab)
        #expect(WorkModeTabCommandRouter.route(.selectPrevious, in: .review) == .selectReviewTab(offset: -1))
        #expect(WorkModeTabCommandRouter.route(.selectNext, in: .review) == .selectReviewTab(offset: 1))
        #expect(WorkModeTabCommandRouter.route(.close, in: .code) == .closeCodeTab)
        #expect(WorkModeTabCommandRouter.route(.selectPrevious, in: .code) == .selectCodeTab(offset: -1))
        #expect(WorkModeTabCommandRouter.route(.selectNext, in: .code) == .selectCodeTab(offset: 1))
    }

    @Test
    func codeOnlyGlobalTabCommandsAreDisabledInReviewWorkMode() {
        #expect(WorkModeCodeCommandEligibility.isEnabled(in: .code))
        #expect(!WorkModeCodeCommandEligibility.isEnabled(in: .review))
    }

    @Test
    func submissionReplyAndPendingViewedActionsExposeAccessibleRuntimeState() throws {
        let source = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")
        let domain = try SourceContract("Argus/Models/ReviewDomain.swift")

        source.contains("model.isSubmittingReview(in: tab.id)", "Review submit controls expose runtime submission state")
        source.contains("model.isSendingReply(conversationID: conversation.id, in: tab.id)", "Reply controls expose runtime send state")
        domain.contains("Retry Mark Viewed", "Pending viewed state names its retry action")
        domain.contains("Retry Mark Unviewed", "Pending unviewed state names its retry action")
        source.contains("accessibilityValue(viewedAction.status)", "Viewed action exposes its state accessibly")
        source.contains("model.isProviderWriteEligible(in: tab.id)", "Provider-write controls share model eligibility")
        source.contains("Provider writes unavailable", "Disabled provider-write controls expose their unavailable status")
    }

    @Test
    func reviewSubmissionStateIsKeyedOnlyByPullRequest() throws {
        let coordinator = try SourceContract("Argus/Views/Review/Model/ReviewProviderWriteCoordinator.swift")
        let model = try SourceContract("Argus/Views/Review/ReviewWorkModeModel.swift")

        coordinator.contains("func isSubmittingReview(for pullRequest: PullRequestIdentity?) -> Bool", "Submission state accepts only Pull Request identity")
        coordinator.excludes("func isSubmittingReview(in tabID:", "Submission state must not accept unused tab identity")
        model.contains("providerWriteCoordinator.isSubmittingReview(for: pullRequest)", "Model queries submission state by Pull Request identity")
    }

    @Test
    func inlineDraftComposerExposesModifiedFileSideSelection() throws {
        let source = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")

        source.contains("Picker(\"Diff side\"", "Modified files allow selecting a LEFT or RIGHT inline anchor")
        source.contains("case .deleted:", "Deleted files use a dedicated LEFT anchor path")
        source.contains("case .added:", "Added files use a dedicated RIGHT anchor path")
        source.contains("Choose a line included in the loaded diff patch.", "Invalid inline anchor state is actionable")
        source.contains("complete diff patch missing", "Unavailable inline anchors have accessible explanation")
    }

    @Test
    func reviewSubmissionRequiresExplicitDispositionAndConversationActionsRespectPermissions() throws {
        let source = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")

        source.contains("Select disposition", "Review submission exposes an unselected disposition")
        source.contains("conversation.permissions.canResolve", "Resolve control is permission-gated")
        source.contains("conversation.permissions.canUnresolve", "Unresolve control is permission-gated")
        source.contains("model.isSettingResolution(conversationID: conversation.id, in: tab.id)", "Resolution controls expose their in-flight state")
        source.contains("Setting resolution", "Resolution controls expose their busy state accessibly")
    }

    @Test
    func reviewSubmissionEligibilityRequiresRevisionDispositionProviderAccessAndNoInFlightSubmission() {
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let ready = PendingReview(revision: revision, disposition: .comment)

        #expect(ReviewSubmissionEligibility.canSubmit(
            pendingReview: ready, providerWriteEligible: true, isSubmitting: false
        ))
        #expect(!ReviewSubmissionEligibility.canSubmit(
            pendingReview: .init(revision: nil, disposition: .comment), providerWriteEligible: true, isSubmitting: false
        ))
        #expect(!ReviewSubmissionEligibility.canSubmit(
            pendingReview: .init(revision: revision), providerWriteEligible: true, isSubmitting: false
        ))
        #expect(!ReviewSubmissionEligibility.canSubmit(
            pendingReview: ready, providerWriteEligible: false, isSubmitting: false
        ))
        #expect(!ReviewSubmissionEligibility.canSubmit(
            pendingReview: ready, providerWriteEligible: true, isSubmitting: true
        ))
    }

    @Test
    func reviewSubmissionConfirmationCapturesImmutablePayloadBeforeAlertPresentation() throws {
        let source = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")

        source.contains("@State private var submitConfirmation: SubmitReviewConfirmation?", "Confirmation state is ephemeral view state")
        source.contains("pendingReview: tab.pendingReview", "Confirmation captures the Pending Review before the alert opens")
        source.contains("submitConfirmation = nil", "Cancel and submit clear transient confirmation state")
        source.contains("pendingReview: confirmation.pendingReview", "Submission uses the captured confirmation payload")
    }

    @Test
    func reviewSubmissionConfirmationDescribesZeroOneAndManyDraftsAndSummaryPresence() {
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let noDrafts = SubmitReviewConfirmation(
            pullRequestNumber: 42,
            pendingReview: .init(revision: revision, disposition: .approve)
        )
        let oneDraft = SubmitReviewConfirmation(
            pullRequestNumber: 42,
            pendingReview: .init(
                revision: revision,
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "One")],
                disposition: .comment
            )
        )
        let manyDrafts = SubmitReviewConfirmation(
            pullRequestNumber: 42,
            pendingReview: .init(
                revision: revision,
                inlineDrafts: [
                    .init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "One"),
                    .init(anchor: .init(path: "Source.swift", line: 2, side: .right), body: "Two")
                ],
                summary: "Summary",
                disposition: .requestChanges
            )
        )

        #expect(noDrafts.inlineDraftDescription == "0 inline drafts")
        #expect(oneDraft.inlineDraftDescription == "1 inline draft")
        #expect(manyDrafts.inlineDraftDescription == "2 inline drafts")
        #expect(noDrafts.summaryDescription == "No summary will be included.")
        #expect(manyDrafts.summaryDescription == "A summary will be included.")
        #expect(manyDrafts.disposition == .requestChanges)
        #expect(manyDrafts.message == "Submit requestChanges for Pull Request #42 with 2 inline drafts. A summary will be included.")
    }

    @Test
    @MainActor func reviewLayoutUsesSharedWidthBoundsForMutationsAndPaneDividers() throws {
        let tab = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")
        let model = try SourceContract("Argus/Views/Review/ReviewWorkModeModel.swift")
        let state = try SourceContract("Argus/Models/Review/ReviewState.swift")

        state.contains("static let fileListWidthBounds: ClosedRange<Double> = 180...480", "File-list bounds have one named owner")
        state.contains("static let rightSidebarWidthBounds: ClosedRange<Double> = 180...600", "Right-sidebar bounds have one named owner")
        tab.contains("bounds: ReviewPaneState.fileListWidthBounds", "Review pane bindings and dividers use shared file-list bounds")
        tab.contains("ReviewPaneState.normalized(initial + value.translation.width, to: bounds)", "Divider drags normalize through their shared bounds")
        model.contains("ReviewPaneState.normalizedRightSidebarWidth", "Review sidebar mutations normalize through shared bounds")
    }

    @Test
    func compactReviewDrawersReadAndClearActiveDrawerWithoutChangingCollapseState() throws {
        let source = try SourceContract("Argus/Views/Review/PullRequestReviewTab.swift")

        source.contains("switch tab.paneState.activeDrawer", "Compact rendering reads the active drawer state")
        source.contains("case .files where size.width <= 760:", "Changed files has a narrow drawer route")
        source.contains("case .conversations where size.width <= 980:", "Conversations has a narrow drawer route")
        source.contains("ChangedFilesView(model: model, tab: tab)", "Changed files render inside the drawer")
        source.contains("ConversationsView(model: model, tab: tab)", "Conversations render inside the drawer")
        source.contains("Button(\"Close\", action: closeDrawer)", "Each drawer has an explicit keyboard-reachable close control")
        source.contains("$0.paneState.activeDrawer = nil", "Closing a drawer clears only active drawer state")
        source.contains("size.width * 0.6", "Compact drawers leave central diff content visible")
    }
}
