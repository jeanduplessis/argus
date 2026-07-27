import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ReviewDomainTests {
    private let repository = RepositoryIdentity(host: "GitHub.com", owner: "Argus", name: "Argus")

    @Test
    func identitiesAreProviderQualifiedAndCanonical() {
        let upper = PullRequestIdentity(repository: repository, number: 12)
        let lower = PullRequestIdentity(repository: .init(host: "github.com", owner: "argus", name: "argus"), number: 12)
        #expect(upper == lower)
        #expect(upper != PullRequestIdentity(repository: repository, number: 13))
    }

    @Test
    func decodedProviderMetadataNormalizesMixedCaseAndWhitespace() throws {
        let metadata = try JSONDecoder().decode(
            RepositoryProviderMetadata.self,
            from: Data(#"{"provider":"  GitHub\n","accountLogin":"\tOcto-Cat  "}"#.utf8)
        )

        #expect(metadata.provider == "github")
        #expect(metadata.accountLogin == "octo-cat")
        #expect(metadata.isValid)
    }

    @Test
    func reviewRevisionAcceptsProviderSafeShortIdentifiersAndRejectsUnsafeCommits() {
        #expect(ReviewRevision(baseCommit: "base", headCommit: "head").isValid)
        #expect(ReviewRevision(baseCommit: "a_b-c", headCommit: "deadbeef").isValid)
        #expect(!ReviewRevision(baseCommit: "base/main", headCommit: "head").isValid)
        #expect(!ReviewRevision(baseCommit: "base", headCommit: "head;command").isValid)
    }

    @Test
    func decodedReviewRevisionNormalizesWhitespaceForProviderSafeOutput() throws {
        let revision = try JSONDecoder().decode(
            ReviewRevision.self,
            from: Data(#"{"baseCommit":" \n base-commit \t","headCommit":"\nhead_commit \r\n"}"#.utf8)
        )

        #expect(revision.baseCommit == "base-commit")
        #expect(revision.headCommit == "head_commit")
        #expect(revision.isValid)
        let encoded = try JSONEncoder().encode(revision)
        let output = try JSONDecoder().decode(ReviewRevision.self, from: encoded)
        #expect(output == revision)
    }

    @Test
    func reconciliationClearsMalformedPersistedRevisionsWithoutDroppingAuthoredText() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let tab = ReviewTabState(
            pullRequest: identity,
            revision: .init(baseCommit: "base/main", headCommit: "head"),
            replyDrafts: [.init(conversationID: "draft", body: "Keep this reply")],
            pendingReview: .init(revision: .init(baseCommit: "base", headCommit: "head;command"), summary: "Keep this summary")
        )

        let restored = ReviewSessionSnapshot(tabs: [tab]).reconciledForRestore()

        #expect(restored.tabs[0].revision == nil)
        #expect(restored.tabs[0].pendingReview.revision == nil)
        #expect(restored.tabs[0].replyDrafts[0].body == "Keep this reply")
        #expect(restored.tabs[0].pendingReview.summary == "Keep this summary")
    }

    @Test
    func reconciliationDropsPersistedIdentitiesOutsideCanonicalGitHubCoordinates() {
        let invalidRepository = RepositoryIdentity(host: "github.com.evil", owner: "../owner", name: "argus")
        let invalidIdentity = PullRequestIdentity(repository: invalidRepository, number: 12)
        let invalidTab = ReviewTabState(
            pullRequest: invalidIdentity,
            replyDrafts: [.init(conversationID: "draft", body: "Do not retain unsafe state")]
        )
        let restored = ReviewSessionSnapshot(
            projects: [.init(repositoryIdentity: invalidRepository)],
            pullRequests: [.init(identity: invalidIdentity, title: "Unsafe", author: "")],
            tabs: [invalidTab],
            closedAuthoredState: [invalidIdentity: .init(replyDrafts: invalidTab.replyDrafts)]
        ).reconciledForRestore()

        #expect(!invalidRepository.isValid)
        #expect(restored.projects.isEmpty)
        #expect(restored.pullRequests.isEmpty)
        #expect(restored.tabs.isEmpty)
        #expect(restored.closedAuthoredState.isEmpty)
    }

    @Test
    func intakeMatchesIdentityBearingNamedProject() {
        let projectID = UUID()
        let reference = SharedProjectReference(projectID: projectID, displayName: "Local Argus", repositoryIdentity: repository, providerMetadata: .init(provider: "github"))
        let store = ReviewStore()

        let project = store.resolveProject(for: repository, namedProject: reference)

        #expect(project.projectID == projectID)
        #expect(project.displayName == "Local Argus")
        #expect(store.session.projects == [project])
    }

    @Test
    func remoteOnlyProjectIsCreatedOnceAndReusedForItsIdentity() {
        let store = ReviewStore()
        let first = store.resolveProject(for: repository, namedProject: nil)
        let second = store.resolveProject(for: repository, namedProject: nil)

        #expect(first.projectID == second.projectID)
        #expect(store.session.projects.count == 1)
        #expect(store.session.projects[0].displayName == "argus")
    }

    @Test
    func reconciliationRemovesDuplicateReviewProjectsByRepositoryIdentity() {
        let duplicateOne = ReviewProject(projectID: UUID(), repositoryIdentity: repository)
        let duplicateTwo = ReviewProject(projectID: UUID(), repositoryIdentity: repository)
        let pullRequest = ReviewPullRequest(identity: .init(repository: repository, number: 42), projectID: duplicateTwo.projectID, title: "Review", author: "author")

        let restored = ReviewSessionSnapshot(projects: [duplicateOne, duplicateTwo], pullRequests: [pullRequest]).reconciledForRestore()

        #expect(restored.projects.count == 1)
        #expect(restored.pullRequests[0].projectID == duplicateOne.projectID)
    }

    @Test
    func reconciliationRepairsMismatchedProviderMetadataWithoutLosingAuthoredContent() {
        let projectID = UUID()
        let identity = PullRequestIdentity(repository: repository, number: 42)
        let project = ReviewProject(
            projectID: projectID,
            repositoryIdentity: repository,
            providerMetadata: .init(provider: "gitlab", accountLogin: "  Octo-Cat ")
        )
        let tab = ReviewTabState(
            pullRequest: identity,
            replyDrafts: [.init(conversationID: "draft", body: "Keep this reply")],
            pendingReview: .init(revision: nil, summary: "Keep this summary")
        )

        let restored = ReviewSessionSnapshot(
            projects: [project],
            pullRequests: [.init(identity: identity, projectID: projectID, title: "Review", author: "author")],
            tabs: [tab]
        ).reconciledForRestore()

        #expect(restored.projects[0].providerMetadata == .init(provider: "github", accountLogin: "octo-cat"))
        #expect(restored.pullRequests[0].projectID == projectID)
        #expect(restored.tabs[0].replyDrafts[0].body == "Keep this reply")
        #expect(restored.tabs[0].pendingReview.summary == "Keep this summary")
    }

    @Test
    func reconciliationDiscardsProjectWithUnsafeMetadataAndPreservesAuthoredTab() {
        let projectID = UUID()
        let identity = PullRequestIdentity(repository: repository, number: 42)
        let project = ReviewProject(
            projectID: projectID,
            repositoryIdentity: repository,
            providerMetadata: .init(provider: "github", accountLogin: "unsafe/account")
        )
        let tab = ReviewTabState(
            pullRequest: identity,
            replyDrafts: [.init(conversationID: "draft", body: "Keep this reply")]
        )

        let restored = ReviewSessionSnapshot(
            projects: [project],
            pullRequests: [.init(identity: identity, projectID: projectID, title: "Review", author: "author")],
            tabs: [tab]
        ).reconciledForRestore()

        #expect(restored.projects.isEmpty)
        #expect(restored.pullRequests[0].projectID == nil)
        #expect(restored.tabs[0].replyDrafts[0].body == "Keep this reply")
    }

    @Test
    func reconciliationNormalizesProgrammaticMetadataProviderMismatch() {
        let project = ReviewProject(
            repositoryIdentity: repository,
            providerMetadata: .init(provider: " unsupported ", accountLogin: "  OCTOCAT ")
        )

        let restored = ReviewSessionSnapshot(projects: [project]).reconciledForRestore()

        #expect(restored.projects[0].providerMetadata == .init(provider: "github", accountLogin: "octocat"))
    }

    @Test
    func reconciliationDeduplicatesRepairedProjectsAndRemapsPullRequests() {
        let canonicalID = UUID()
        let duplicateID = UUID()
        let identity = PullRequestIdentity(repository: repository, number: 42)
        let canonical = ReviewProject(projectID: canonicalID, repositoryIdentity: repository)
        let duplicate = ReviewProject(
            projectID: duplicateID,
            repositoryIdentity: repository,
            providerMetadata: .init(provider: "gitlab", accountLogin: "octocat")
        )

        let restored = ReviewSessionSnapshot(
            projects: [canonical, duplicate],
            pullRequests: [.init(identity: identity, projectID: duplicateID, title: "Review", author: "author")]
        ).reconciledForRestore()

        #expect(restored.projects.count == 1)
        #expect(restored.projects[0].projectID == canonicalID)
        #expect(restored.pullRequests[0].projectID == canonicalID)
    }

    @Test
    func openingPullRequestReusesItsTab() {
        let store = ReviewStore()
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let first = store.openTab(for: identity)
        let second = store.openTab(for: identity)
        #expect(first.id == second.id)
        #expect(store.session.tabs.count == 1)
    }

    @Test
    func activeDrawerStoresAtMostOneCompactReviewDrawer() {
        var paneState = ReviewPaneState(activeDrawer: .files)

        #expect(paneState.activeDrawer == .files)
        paneState.activeDrawer = .conversations
        #expect(paneState.activeDrawer == .conversations)
        paneState.activeDrawer = nil
        #expect(paneState.activeDrawer == nil)
    }

    @Test
    func inboxItemMovesToSavedWhenTabRemainsOpen() {
        let store = ReviewStore()
        let identity = PullRequestIdentity(repository: repository, number: 12)
        store.save(.init(identity: identity, title: "Review", author: "A"))
        store.openTab(for: identity)
        store.synchronizeInbox([])
        #expect(store.session.pullRequests.first?.membership == .saved)
    }

    @Test
    func inboxSynchronizationRemovesUnretainedPreviouslySavedItem() {
        let store = ReviewStore()
        let identity = PullRequestIdentity(repository: repository, number: 12)
        store.save(.init(identity: identity, title: "Review", author: "A", membership: .saved))

        store.synchronizeInbox([])

        #expect(!store.session.pullRequests.contains { $0.identity == identity })
    }

    @Test
    func inboxSynchronizationPreservesExplicitManualSave() {
        let store = ReviewStore()
        let identity = PullRequestIdentity(repository: repository, number: 12)
        store.save(.init(identity: identity, title: "Review", author: "A", membership: .saved, isManuallySaved: true))

        store.synchronizeInbox([])

        #expect(store.session.pullRequests.first?.identity == identity)
    }

    @Test
    func inboxSynchronizationCreatesDiscoveryAttentionOnlyForNewIdentity() {
        let store = ReviewStore()
        let first = PullRequestIdentity(repository: repository, number: 12)
        let second = PullRequestIdentity(repository: repository, number: 13)
        let request = ReviewPullRequest(identity: first, title: "First", author: "A")

        store.synchronizeInbox([request])
        #expect(store.session.pullRequests.first?.attention == .newRequest)

        store.acknowledgeVisiblePullRequest(first)
        store.synchronizeInbox([request])
        #expect(store.session.pullRequests.first?.attention == ReviewAttention.none)

        store.synchronizeInbox([request, .init(identity: second, title: "Second", author: "B")])
        #expect(store.session.pullRequests.first { $0.identity == first }?.attention == ReviewAttention.none)
        #expect(store.session.pullRequests.first { $0.identity == second }?.attention == .newRequest)
    }

    @Test
    func inboxSynchronizationChangesOnlyTheRefreshedHost() {
        let github = PullRequestIdentity(repository: repository, number: 12)
        let enterpriseRepository = RepositoryIdentity(host: "ghe.example.com", owner: "argus", name: "app")
        let enterprise = PullRequestIdentity(repository: enterpriseRepository, number: 13)
        let store = ReviewStore(session: .init(pullRequests: [
            .init(identity: github, title: "GitHub", author: "A", membership: .inbox),
            .init(identity: enterprise, title: "Enterprise", author: "B", membership: .inbox)
        ]))

        store.synchronizeInbox([], host: "github.com")

        #expect(!store.session.pullRequests.contains { $0.identity == github })
        #expect(store.session.pullRequests.first { $0.identity == enterprise }?.membership == .inbox)
    }

    @Test
    func inboxHostDefaultsForLegacySessionStateAndRoundTripsExplicitEnterpriseHost() throws {
        let legacy = try JSONDecoder().decode(ReviewSessionSnapshot.self, from: Data(#"{"schemaVersion":3}"#.utf8))
        #expect(legacy.selectedInboxHost == "github.com")

        let enterprise = ReviewSessionSnapshot(selectedInboxHost: "GHE.Example.Com")
        let restored = try JSONDecoder().decode(ReviewSessionSnapshot.self, from: JSONEncoder().encode(enterprise))
        #expect(restored.selectedInboxHost == "ghe.example.com")
    }

    @Test
    func viewedChangesOnlyWithExplicitIntent() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let tab = ReviewTabState(pullRequest: identity, changedFiles: [.init(path: "Sources/App.swift")])
        let store = ReviewStore(session: .init(tabs: [tab]))
        #expect(store.session.tabs[0].changedFiles[0].viewedState == .unviewed)
        store.setViewed(true, path: "Sources/App.swift", in: tab.id)
        #expect(store.session.tabs[0].changedFiles[0].viewedState == .pendingViewed)
        store.acknowledgeViewedSync(path: "Sources/App.swift", viewed: true, in: tab.id)
        #expect(store.session.tabs[0].changedFiles[0].viewedState == .viewed)
    }

    @Test
    func viewedIntentRoundTripsWithoutProviderChangedFilesAndLegacyTabsDecode() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let snapshot = ReviewSessionSnapshot(tabs: [
            .init(
                pullRequest: identity,
                revision: revision,
                changedFiles: [.init(path: "Provider.swift")],
                pendingViewedIntents: [.init(revision: revision, path: "Source.swift", viewed: true)]
            )
        ])

        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(ReviewSessionSnapshot.self, from: data)

        #expect(restored.tabs[0].changedFiles.isEmpty)
        #expect(restored.tabs[0].pendingViewedIntents == [.init(revision: revision, path: "Source.swift", viewed: true)])
        let legacy = try JSONDecoder().decode(
            ReviewTabState.self,
            from: Data(#"{"id":"00000000-0000-0000-0000-000000000001","pullRequest":{"repository":{"provider":"github","host":"github.com","owner":"argus","name":"argus"},"number":12}}"#.utf8)
        )
        #expect(legacy.pendingViewedIntents.isEmpty)
    }

    @Test
    func closeAndReopenRetainsPendingViewedIntentUntilExplicitDiscard() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let store = ReviewStore()
        let tab = store.openTab(for: identity)
        store.mutateTabForTesting(tab.id) { $0.revision = revision }
        store.mutateTabForTesting(tab.id) { $0.recordViewedIntent(true, path: "Source.swift", revision: revision) }

        store.closeTab(id: tab.id)
        #expect(store.session.closedAuthoredState[identity]?.pendingViewedIntents.count == 1)
        let reopened = store.openTab(for: identity)
        #expect(reopened.pendingViewedIntents.count == 1)
        store.discardSavedPullRequest(identity)
        #expect(store.session.closedAuthoredState[identity] == nil)
    }

    @Test
    func staleRevisionRetainsUnmappableAuthoring() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(pullRequest: identity, revision: .init(baseCommit: "a", headCommit: "b"))
        let draft = ReviewInlineDraft(anchor: .init(path: "Old.swift", line: 2, side: .right), body: "Keep this")
        tab.pendingReview = .init(revision: tab.revision, inlineDrafts: [draft], summary: "Summary")
        let result = tab.updateRevision(to: .init(baseCommit: "a", headCommit: "c"), pathMapping: [:])
        #expect(result.outcome == .draftsRequireRemap)
        #expect(tab.pendingReview.inlineDrafts[0].body == "Keep this")
        #expect(tab.pendingReview.summary == "Summary")
        #expect(tab.pendingReview.inlineDrafts[0].requiresRemap)
    }

    @Test
    func unboundAuthoredPendingReviewRequiresExplicitRevisionAdoption() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        var tab = ReviewTabState(
            pullRequest: identity,
            revision: revision,
            pendingReview: .init(
                revision: nil,
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 1, side: .right), body: "Keep")],
                disposition: .comment
            )
        )

        tab.preserveUnboundPendingReviewForRemap()

        #expect(tab.pendingReview.revision == nil)
        #expect(tab.pendingReview.inlineDrafts.allSatisfy { $0.requiresRemap })
        let adopted = tab.adoptLoadedRevisionForPendingReview()
        #expect(adopted)
        #expect(tab.pendingReview.revision == revision)
        #expect(tab.pendingReview.inlineDrafts.allSatisfy { $0.requiresRemap })
    }

    @Test
    func localDraftDetectionRetainsNonEmptyReplyText() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let draftTab = ReviewTabState(pullRequest: identity, replyDrafts: [.init(conversationID: "conversation", body: "Keep this reply")])
        let emptyTab = ReviewTabState(pullRequest: identity, replyDrafts: [.init(conversationID: "conversation", body: "  ")])
        #expect(draftTab.hasLocalDrafts)
        #expect(!emptyTab.hasLocalDrafts)
    }

    @Test
    func deletedFileDraftAnchorRequiresLeftSide() {
        let deleted = ReviewChangedFile(
            path: "Removed.swift", status: .deleted,
            validAnchorCoordinates: [.init(side: .left, line: 4)]
        )
        let left = ReviewDraftAnchor(path: "Removed.swift", line: 4, side: .left)
        let right = ReviewDraftAnchor(path: "Removed.swift", line: 4, side: .right)

        #expect(left.isValid(for: deleted))
        #expect(!right.isValid(for: deleted))
    }

    @Test
    func modifiedFileDraftAnchorAllowsExplicitSideSelection() {
        let modified = ReviewChangedFile(
            path: "Source.swift", status: .modified,
            validAnchorCoordinates: [.init(side: .left, line: 4), .init(side: .right, line: 4)]
        )

        #expect(ReviewDraftAnchor(path: "Source.swift", line: 4, side: .left).isValid(for: modified))
        #expect(ReviewDraftAnchor(path: "Source.swift", line: 4, side: .right).isValid(for: modified))
        #expect(!ReviewDraftAnchor(path: "Source.swift", line: 0, side: .right).isValid(for: modified))
    }

    @Test
    func restoredAnchorOutsideImmutableCoordinatesRequiresRemapButRetainsDraft() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(
            pullRequest: identity,
            pendingReview: .init(
                revision: .init(baseCommit: "base", headCommit: "head"),
                inlineDrafts: [.init(anchor: .init(path: "Source.swift", line: 99, side: .right), body: "Keep")]
            )
        )
        tab.changedFiles = [.init(
            path: "Source.swift",
            validAnchorCoordinates: [.init(side: .right, line: 1)]
        )]

        tab.requireRemapForInvalidInlineDraftAnchors()

        #expect(tab.pendingReview.inlineDrafts[0].body == "Keep")
        #expect(tab.pendingReview.inlineDrafts[0].requiresRemap)
        #expect(!tab.pendingReview.isValidForSubmission(with: tab.changedFiles))
    }

    @Test
    func reconciliationMergesDuplicateTabsWithoutDroppingAuthoredText() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let first = ReviewTabState(pullRequest: identity, replyDrafts: [.init(conversationID: "first", body: "First reply")])
        let second = ReviewTabState(pullRequest: identity, replyDrafts: [.init(conversationID: "second", body: "Second reply")], pendingReview: .init(revision: nil, summary: "Review summary"))

        let restored = ReviewSessionSnapshot(tabs: [first, second]).reconciledForRestore()

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].replyDrafts.map(\.body).sorted() == ["First reply", "Second reply"])
        #expect(restored.tabs[0].pendingReview.summary == "Review summary")
    }

    @Test
    func reconciliationMergesDuplicateTabsPreservingDispositionWhenDestinationLacksIt() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let first = ReviewTabState(pullRequest: identity)
        let second = ReviewTabState(
            pullRequest: identity,
            pendingReview: .init(revision: nil, disposition: .requestChanges)
        )

        let restored = ReviewSessionSnapshot(tabs: [first, second]).reconciledForRestore()

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].pendingReview.disposition == .requestChanges)
    }

    @Test
    func reconciliationUsesFirstRevisionForConflictingDuplicateTabsAndRequiresRemap() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let firstRevision = ReviewRevision(baseCommit: "base", headCommit: "first")
        let secondRevision = ReviewRevision(baseCommit: "base", headCommit: "second")
        let first = ReviewTabState(
            pullRequest: identity,
            revision: firstRevision,
            pendingReview: .init(
                revision: firstRevision,
                inlineDrafts: [.init(anchor: .init(path: "First.swift", line: 1, side: .right), body: "First")],
                disposition: .comment
            )
        )
        let second = ReviewTabState(
            pullRequest: identity,
            revision: secondRevision,
            pendingReview: .init(
                revision: secondRevision,
                inlineDrafts: [.init(anchor: .init(path: "Second.swift", line: 2, side: .right), body: "Second")],
                disposition: .approve
            )
        )

        let restored = ReviewSessionSnapshot(tabs: [first, second]).reconciledForRestore()

        #expect(restored.tabs.count == 1)
        #expect(restored.tabs[0].revision == firstRevision)
        #expect(restored.tabs[0].pendingReview.revision == firstRevision)
        #expect(restored.tabs[0].pendingReview.disposition == .comment)
        #expect(restored.tabs[0].pendingReview.inlineDrafts.map(\.body).sorted() == ["First", "Second"])
        let allDraftsRequireRemap = restored.tabs[0].pendingReview.inlineDrafts.allSatisfy { $0.requiresRemap }
        #expect(allDraftsRequireRemap)
    }

    @Test
    func newHeadIsAnnouncedWithoutReplacingLoadedRevision() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(pullRequest: identity, revision: .init(baseCommit: "a", headCommit: "b"))
        #expect(tab.announceNewHead("c") == .staleHeadAvailable)
        #expect(tab.revision?.headCommit == "b")
        #expect(tab.announcedHeadCommit == "c")
        #expect(tab.announcedRevision == .init(baseCommit: "a", headCommit: "c"))
    }

    @Test
    func baseOnlyRevisionChangeIsAnnouncedWithoutReplacingLoadedRevision() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let old = ReviewRevision(baseCommit: "base-a", headCommit: "head")
        let new = ReviewRevision(baseCommit: "base-b", headCommit: "head")
        var tab = ReviewTabState(pullRequest: identity, revision: old, loadState: .refreshing)

        #expect(tab.announceNewRevision(new) == .staleHeadAvailable)
        #expect(tab.revision == old)
        #expect(tab.announcedRevision == new)
        #expect(tab.announcedHeadCommit == "head")
        #expect(tab.loadState == .loaded)
    }

    @Test
    func reconciliationPreservesAuthoredTextWhenMetadataIsInvalid() {
        let valid = PullRequestIdentity(repository: repository, number: 12)
        let tab = ReviewTabState(pullRequest: valid, replyDrafts: [.init(conversationID: "c", body: "Do not lose")])
        let invalid = ReviewPullRequest(identity: .init(repository: repository, number: 0), title: "bad", author: "")
        let restored = ReviewSessionSnapshot(pullRequests: [invalid], tabs: [tab]).reconciledForRestore()
        #expect(restored.tabs.first?.replyDrafts.first?.body == "Do not lose")
        #expect(restored.selectedPullRequest == valid)
    }

    @Test
    func revisionUpdateRequiresExplicitRenameEvidenceForDraftMapping() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(pullRequest: identity, revision: .init(baseCommit: "a", headCommit: "b"))
        let draft = ReviewInlineDraft(anchor: .init(path: "Same.swift", line: 2, side: .right), body: "Keep")
        tab.pendingReview = .init(revision: tab.revision, inlineDrafts: [draft])

        let result = tab.updateRevision(to: .init(baseCommit: "a", headCommit: "c"), pathMapping: ["Same.swift": "Same.swift"])

        #expect(result.outcome == .draftsRequireRemap)
        #expect(tab.pendingReview.inlineDrafts[0].requiresRemap)
    }

    @Test
    func revisionUpdateRenamesAnchorButRequiresExplicitLineRemap() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(pullRequest: identity, revision: .init(baseCommit: "a", headCommit: "b"))
        tab.pendingReview = .init(
            revision: tab.revision,
            inlineDrafts: [.init(anchor: .init(path: "Old.swift", line: 2, side: .right), body: "Keep")],
            disposition: .comment
        )

        let result = tab.updateRevision(
            to: .init(baseCommit: "a", headCommit: "c"), pathMapping: ["Old.swift": "New.swift"])

        #expect(result.outcome == .draftsRequireRemap)
        #expect(tab.pendingReview.inlineDrafts[0].anchor.path == "New.swift")
        #expect(tab.pendingReview.inlineDrafts[0].requiresRemap)
        #expect(!tab.pendingReview.isValidForSubmission(with: [.init(path: "New.swift")]))
    }

    @Test
    func tabStateRestoresNewPaneAndRemoteReadFieldsFromOlderSnapshot() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let oldJSON = #"{"id":"00000000-0000-0000-0000-000000000001","pullRequest":{"repository":{"provider":"github","host":"github.com","owner":"argus","name":"argus"},"number":12},"section":"files","changedFiles":[],"fileFilter":{"pathQuery":"","onlyUnviewed":false},"conversations":[],"replyDrafts":[],"pendingReview":{"inlineDrafts":[],"summary":"","disposition":"comment"},"loadState":"loaded","attention":"none"}"#
        let tab = try JSONDecoder().decode(ReviewTabState.self, from: Data(oldJSON.utf8))
        #expect(tab.pullRequest == identity)
        #expect(tab.paneState.activeDrawer == nil)
        #expect(tab.activity.isEmpty)
    }

    @Test
    func decodingLoadedTabDropsProviderPayloadAndNormalizesToStale() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let source = ReviewTabState(
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
                    comments: [],
                    permissions: .init(canReply: true, canResolve: true, canUnresolve: true)
                )
            ],
            activity: [.init(id: "activity", kind: "reviewed", author: "author", body: "body", createdAt: .now)],
            checks: .init(mergeable: "MERGEABLE", mergeStateStatus: nil, reviewDecision: nil, checks: []),
            loadState: .loaded
        )

        let restored = try JSONDecoder().decode(ReviewTabState.self, from: JSONEncoder().encode(source))

        #expect(restored.revision == revision)
        #expect(restored.loadState == ReviewLoadState.stale)
        #expect(restored.changedFiles.isEmpty)
        #expect(restored.conversations.isEmpty)
        #expect(restored.activity.isEmpty)
        #expect(restored.checks == nil)
        #expect(restored.lastSuccessfulRefresh == nil)
    }

    @Test
    func decodingLoadedTabWithoutRevisionNormalizesToInitialLoading() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let source = ReviewTabState(pullRequest: identity, loadState: .loaded)

        let restored = try JSONDecoder().decode(ReviewTabState.self, from: JSONEncoder().encode(source))

        #expect(restored.loadState == .initialLoading)
    }

    @Test
    func persistedPaneWidthsNormalizeToTheirSharedBounds() throws {
        let decoded = try JSONDecoder().decode(
            ReviewPaneState.self,
            from: Data(#"{"filesWidth":120,"conversationsWidth":800}"#.utf8)
        )

        #expect(decoded.filesWidth == ReviewPaneState.fileListWidthBounds.lowerBound)
        #expect(decoded.conversationsWidth == ReviewPaneState.fileListWidthBounds.upperBound)
        #expect(ReviewPaneState.normalizedRightSidebarWidth(120) == ReviewPaneState.rightSidebarWidthBounds.lowerBound)
        #expect(ReviewPaneState.normalizedRightSidebarWidth(800) == ReviewPaneState.rightSidebarWidthBounds.upperBound)
    }

    @Test
    func sentReplyReconciliationRequiresTheExactOriginalDraftBody() {
        var authored = ReviewAuthoredState(replyDrafts: [.init(conversationID: "conversation", body: "  Reply\n")])

        authored.reconcileSentReply(conversationID: "conversation", body: "Reply")

        #expect(authored.replyDrafts.first?.body == "  Reply\n")
        authored.reconcileSentReply(conversationID: "conversation", body: "  Reply\n")
        #expect(authored.replyDrafts.isEmpty)
    }

    @Test
    func legacyAnnouncedHeadMigratesToCompleteRevision() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","pullRequest":{"repository":{"provider":"github","host":"github.com","owner":"argus","name":"argus"},"number":12},"revision":{"baseCommit":"base","headCommit":"old"},"announcedHeadCommit":"new"}"#

        let tab = try JSONDecoder().decode(ReviewTabState.self, from: Data(json.utf8))

        #expect(tab.announcedRevision == .init(baseCommit: "base", headCommit: "new"))
        #expect(tab.announcedHeadCommit == "new")
    }

    @Test
    func closingAndReopeningTabRetainsAuthoredRepliesAndPendingReview() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let store = ReviewStore()
        let tab = store.openTab(for: identity)
        store.mutateTabForTesting(tab.id) {
            $0.replyDrafts = [.init(conversationID: "conversation", body: "Keep reply")]
            $0.pendingReview = .init(revision: nil, summary: "Keep summary")
        }

        store.closeTab(id: tab.id)
        #expect(store.session.tabs.isEmpty)
        #expect(store.session.closedAuthoredState[identity]?.hasContent == true)
        let reopened = store.openTab(for: identity)
        #expect(reopened.replyDrafts.first?.body == "Keep reply")
        #expect(reopened.pendingReview.summary == "Keep summary")
    }

    @Test(arguments: [ReviewDisposition.approve, .comment, .requestChanges])
    func closingAndReopeningTabRetainsDispositionOnlyPendingReview(_ disposition: ReviewDisposition) {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let store = ReviewStore()
        let tab = store.openTab(for: identity)
        store.mutateTabForTesting(tab.id) {
            $0.pendingReview = .init(revision: nil, disposition: disposition)
        }

        store.closeTab(id: tab.id)

        #expect(store.session.closedAuthoredState[identity]?.pendingReview.disposition == disposition)
        let reopened = store.openTab(for: identity)
        #expect(reopened.pendingReview.disposition == disposition)
    }

    @Test
    func reopeningAuthoredStateRetainsItsRevisionUntilExplicitUpdate() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let authoredRevision = ReviewRevision(baseCommit: "base-a", headCommit: "head-a")
        let store = ReviewStore()
        let tab = store.openTab(for: identity)
        store.mutateTabForTesting(tab.id) {
            $0.pendingReview = .init(revision: authoredRevision, summary: "Keep this review")
        }

        store.closeTab(id: tab.id)
        let reopened = store.openTab(for: identity)

        #expect(reopened.revision == authoredRevision)
        #expect(reopened.pendingReview.revision == authoredRevision)
    }

    @Test
    func announcingNewHeadResetsLoadingStateWhileKeepingRevision() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        var tab = ReviewTabState(
            pullRequest: identity,
            revision: .init(baseCommit: "base", headCommit: "old"),
            loadState: .refreshing
        )

        _ = tab.announceNewHead("new")

        #expect(tab.revision?.headCommit == "old")
        #expect(tab.loadState == .loaded)
    }

    @Test
    func explicitDiscardIsOnlyDeletionPathForClosedAuthoredState() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let store = ReviewStore()
        let tab = store.openTab(for: identity)
        store.mutateTabForTesting(tab.id) { $0.pendingReview.summary = "Keep" }
        store.closeTab(id: tab.id)

        store.synchronizeInbox([])
        #expect(store.session.closedAuthoredState[identity]?.hasContent == true)
        store.discardSavedPullRequest(identity)
        #expect(store.session.closedAuthoredState[identity] == nil)
        #expect(!store.session.pullRequests.contains { $0.identity == identity })
    }

    @Test
    func reviewSessionEncodesAuthoredStateButNotProviderPayload() throws {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let tab = ReviewTabState(pullRequest: identity, changedFiles: [.init(path: "Provider.swift")], conversations: [.init(id: "provider", path: "Provider.swift", line: 1, isResolved: false, isOutdated: false, comments: [], permissions: .init(canReply: false, canResolve: false, canUnresolve: false))], replyDrafts: [.init(conversationID: "draft", body: "Keep")])
        let data = try JSONEncoder().encode(ReviewSessionSnapshot(tabs: [tab]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Provider.swift"))
        #expect(text.contains("Keep"))
    }

    @Test
    func closingBackgroundTabPreservesCurrentTabAndSelection() {
        let first = PullRequestIdentity(repository: repository, number: 1)
        let second = PullRequestIdentity(repository: repository, number: 2)
        let store = ReviewStore()
        let firstTab = store.openTab(for: first)
        let secondTab = store.openTab(for: second)

        store.closeTab(id: firstTab.id)

        #expect(store.session.activeTabID == secondTab.id)
        #expect(store.session.selectedPullRequest == second)
    }

    @Test
    func closingActiveTabSelectsFollowingOrPreviousAdjacentTab() {
        let first = PullRequestIdentity(repository: repository, number: 1)
        let second = PullRequestIdentity(repository: repository, number: 2)
        let third = PullRequestIdentity(repository: repository, number: 3)
        let store = ReviewStore()
        _ = store.openTab(for: first)
        let secondTab = store.openTab(for: second)
        let thirdTab = store.openTab(for: third)
        store.selectRelativeTab(-1)

        store.closeTab(id: secondTab.id)
        #expect(store.session.activeTabID == thirdTab.id)
        #expect(store.session.selectedPullRequest == third)

        store.closeTab(id: thirdTab.id)
        #expect(store.session.selectedPullRequest == first)
    }

    @Test
    func discardBackgroundSavedPullRequestPreservesActiveSelection() {
        let first = PullRequestIdentity(repository: repository, number: 1)
        let second = PullRequestIdentity(repository: repository, number: 2)
        let store = ReviewStore()
        let firstTab = store.openTab(for: first)
        let secondTab = store.openTab(for: second)

        store.discardSavedPullRequest(first)

        #expect(store.session.activeTabID == secondTab.id)
        #expect(store.session.selectedPullRequest == second)
        #expect(!store.session.tabs.contains { $0.id == firstTab.id })
    }

    @Test
    func discardActiveSavedPullRequestSelectsFollowingThenPreviousTab() {
        let first = PullRequestIdentity(repository: repository, number: 1)
        let second = PullRequestIdentity(repository: repository, number: 2)
        let third = PullRequestIdentity(repository: repository, number: 3)
        let store = ReviewStore()
        _ = store.openTab(for: first)
        let secondTab = store.openTab(for: second)
        let thirdTab = store.openTab(for: third)
        store.selectRelativeTab(-1)

        store.discardSavedPullRequest(second)
        #expect(store.session.activeTabID == thirdTab.id)
        #expect(store.session.selectedPullRequest == third)

        store.discardSavedPullRequest(third)
        #expect(store.session.selectedPullRequest == first)
    }

    @Test
    func legacyDispositionDoesNotBecomeExplicitSubmissionIntent() throws {
        let pending = try JSONDecoder().decode(PendingReview.self, from: Data(#"{"inlineDrafts":[],"summary":"","disposition":"comment"}"#.utf8))

        #expect(pending.disposition == nil)
        #expect(!pending.isValidForSubmission(with: []))
    }

    @Test
    func invalidPersistedDraftSideIsRejected() {
        let data = Data(#"{"path":"Source.swift","line":1,"side":"MIDDLE"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReviewDraftAnchor.self, from: data) }
    }

    @Test
    func restoreRetainsSelectedFileUntilProviderDataIsAvailable() {
        let identity = PullRequestIdentity(repository: repository, number: 12)
        let tab = ReviewTabState(pullRequest: identity, selectedFilePath: "Source.swift")

        let restored = ReviewSessionSnapshot(tabs: [tab]).reconciledForRestore()

        #expect(restored.tabs.first?.selectedFilePath == "Source.swift")
        #expect(restored.tabs.first?.changedFiles.isEmpty == true)
    }
}
