import Combine
import Foundation

@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var session: ReviewSessionSnapshot

    init(session: ReviewSessionSnapshot = .init()) { self.session = session.reconciledForRestore() }

    /// Resolves intake against an explicitly supplied Code Work Mode match, or
    /// creates/reuses exactly one remote-capable Review Project per identity.
    @discardableResult
    func resolveProject(
        for identity: RepositoryIdentity,
        namedProject: SharedProjectReference?
    ) -> ReviewProject {
        let targetID = namedProject?.projectID
        let existing = session.projects.first { $0.repositoryIdentity == identity }
        let project: ReviewProject
        if let namedProject {
            project = .init(
                projectID: namedProject.projectID,
                repositoryIdentity: identity,
                displayName: namedProject.displayName,
                providerMetadata: namedProject.providerMetadata
            )
        } else if let existing {
            project = existing
        } else {
            project = .init(repositoryIdentity: identity)
        }

        let previousIDs = Set(
            session.projects
                .filter { $0.repositoryIdentity == identity }
                .map(\.projectID))
        session.projects.removeAll { $0.repositoryIdentity == identity }
        session.projects.append(project)
        if !previousIDs.isEmpty || targetID != nil {
            for index in session.pullRequests.indices where session.pullRequests[index].identity.repository == identity
            {
                session.pullRequests[index].projectID = project.projectID
            }
        }
        return project
    }

    @discardableResult
    func openTab(for identity: PullRequestIdentity) -> ReviewTabState {
        if let tab = session.tabs.first(where: { $0.pullRequest == identity }) {
            session.activeTabID = tab.id
            session.selectedPullRequest = identity
            retain(identity, because: .openTab)
            return tab
        }
        var tab = ReviewTabState(pullRequest: identity)
        if let authored = session.closedAuthoredState.removeValue(forKey: identity) {
            tab.restoreAuthoredState(authored)
        }
        session.tabs.append(tab)
        session.activeTabID = tab.id
        session.selectedPullRequest = identity
        retain(identity, because: .openTab)
        return tab
    }

    func closeTab(id: UUID) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = session.tabs.remove(at: index)
        if tab.authoredState.hasContent { session.closedAuthoredState[tab.pullRequest] = tab.authoredState }
        // Closing a background tab must not redirect the user's current review.
        guard session.activeTabID == id else { return }
        let adjacent = session.tabs.indices.contains(index) ? session.tabs[index] : session.tabs.last
        session.activeTabID = adjacent?.id
        session.selectedPullRequest = adjacent?.pullRequest
    }

    func discardSavedPullRequest(_ identity: PullRequestIdentity) {
        let removedIndex = session.tabs.firstIndex { $0.pullRequest == identity }
        let removedActiveTab = session.tabs.first { $0.pullRequest == identity }?.id == session.activeTabID
        session.tabs.removeAll { $0.pullRequest == identity }
        session.closedAuthoredState.removeValue(forKey: identity)
        session.pullRequests.removeAll { $0.identity == identity }
        guard removedActiveTab, let removedIndex else { return }
        let replacement = session.tabs.indices.contains(removedIndex) ? session.tabs[removedIndex] : session.tabs.last
        session.activeTabID = replacement?.id
        session.selectedPullRequest = replacement?.pullRequest
    }

    func moveTab(id: UUID, to destination: Int) {
        guard let source = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(destination, 0), session.tabs.count - 1)
        guard source != target else { return }
        let tab = session.tabs.remove(at: source)
        session.tabs.insert(tab, at: target)
    }

    func selectRelativeTab(_ offset: Int) {
        guard !session.tabs.isEmpty else { return }
        let current = session.tabs.firstIndex { $0.id == session.activeTabID } ?? 0
        let target = (current + offset + session.tabs.count) % session.tabs.count
        session.activeTabID = session.tabs[target].id
        session.selectedPullRequest = session.tabs[target].pullRequest
    }
    func save(_ pullRequest: ReviewPullRequest) {
        var pullRequest = pullRequest
        pullRequest.projectID = resolveProject(for: pullRequest.identity.repository, namedProject: nil).projectID
        upsert(pullRequest)
    }

    func synchronizeInbox(_ inbox: [ReviewPullRequest], host: String? = nil) {
        let refreshedHost = RepositoryIdentity.normalizeHost(host ?? session.selectedInboxHost)
        let incoming = inbox.reduce(into: [PullRequestIdentity: ReviewPullRequest]()) { result, item in
            guard item.identity.repository.host == refreshedHost else { return }
            result[item.identity] = item
        }
        for index in session.pullRequests.indices {
            let identity = session.pullRequests[index].identity
            guard identity.repository.host == refreshedHost else { continue }
            if let remote = incoming[identity] {
                session.pullRequests[index].title = remote.title
                session.pullRequests[index].author = remote.author
                session.pullRequests[index].state = remote.state
                session.pullRequests[index].latestActivity = remote.latestActivity
                if !session.pullRequests[index].isManuallySaved { session.pullRequests[index].membership = .inbox }
            } else if shouldRetain(identity) {
                session.pullRequests[index].membership = .saved
            }
        }
        for var item in incoming.values.sorted(by: { $0.identity < $1.identity })
        where !session.pullRequests.contains(where: { $0.identity == item.identity }) {
            item.projectID = resolveProject(for: item.identity.repository, namedProject: nil).projectID
            item.attention = .newRequest
            session.pullRequests.append(item)
        }
        session.pullRequests.removeAll {
            $0.identity.repository.host == refreshedHost
                && incoming[$0.identity] == nil
                && !shouldRetain($0.identity)
        }
    }

    /// Opening a Pull Request acknowledges discovery attention only. Revision
    /// and failed-operation attention remain actionable until their own flows
    /// resolve them.
    func acknowledgeVisiblePullRequest(_ identity: PullRequestIdentity) {
        guard let index = session.pullRequests.firstIndex(where: { $0.identity == identity }) else { return }
        switch session.pullRequests[index].attention {
        case .newRequest, .remoteActivity:
            session.pullRequests[index].attention = .none
        case .none, .newCommits, .failedOperation:
            break
        }
    }

    func setViewed(_ viewed: Bool, path: String, in tabID: UUID) {
        mutateTab(tabID) { $0.setViewed(viewed, path: path) }
    }
    func acknowledgeViewedSync(path: String, viewed: Bool, in tabID: UUID) {
        mutateTab(tabID) { $0.acknowledgeViewedSync(path: path, viewed: viewed) }
    }
    func reconcileSentReply(identity: PullRequestIdentity, conversationID: String, body: String) {
        mutateTabMatching(identity) { $0.reconcileSentReply(conversationID: conversationID, body: body) }
        if var authored = session.closedAuthoredState[identity] {
            authored.reconcileSentReply(conversationID: conversationID, body: body)
            if authored.hasContent {
                session.closedAuthoredState[identity] = authored
            } else {
                session.closedAuthoredState.removeValue(forKey: identity)
            }
        }
    }
    func reconcileSubmittedReview(identity: PullRequestIdentity, submitted: PendingReview) {
        mutateTabMatching(identity) { $0.reconcileSubmittedReview(submitted) }
        if var authored = session.closedAuthoredState[identity] {
            authored.reconcileSubmittedReview(submitted)
            if authored.hasContent {
                session.closedAuthoredState[identity] = authored
            } else {
                session.closedAuthoredState.removeValue(forKey: identity)
            }
        }
    }
    func updateRevision(tabID: UUID, to revision: ReviewRevision, pathMapping: [String: String])
        -> ReviewRevisionUpdateResult?
    {
        guard let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        return session.tabs[index].updateRevision(to: revision, pathMapping: pathMapping)
    }
    func announceNewHead(_ headCommit: String, in tabID: UUID) -> ReviewRevisionUpdateOutcome? {
        guard let index = session.tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        return session.tabs[index].announceNewHead(headCommit)
    }

    private enum RetentionReason { case openTab }
    private func retain(_ identity: PullRequestIdentity, because: RetentionReason) {
        if let index = session.pullRequests.firstIndex(where: { $0.identity == identity }) {
            session.pullRequests[index].membership = .saved
        } else {
            let project = resolveProject(for: identity.repository, namedProject: nil)
            session.pullRequests.append(
                .init(
                    identity: identity, projectID: project.projectID, title: "Pull Request #\(identity.number)",
                    author: "", membership: .saved))
        }
    }
    private func shouldRetain(_ identity: PullRequestIdentity) -> Bool {
        guard let item = session.pullRequests.first(where: { $0.identity == identity }) else {
            return session.tabs.contains(where: { $0.pullRequest == identity })
        }
        return item.isManuallySaved || session.closedAuthoredState[identity]?.hasContent == true
            || session.tabs.contains(where: { $0.pullRequest == identity })
    }
    private func upsert(_ item: ReviewPullRequest) {
        if let index = session.pullRequests.firstIndex(where: { $0.identity == item.identity }) {
            session.pullRequests[index] = item
        } else {
            session.pullRequests.append(item)
        }
    }
    private func mutateTab(_ id: UUID, _ body: (inout ReviewTabState) -> Void) {
        guard let index = session.tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&session.tabs[index])
    }
    private func mutateTabMatching(_ identity: PullRequestIdentity, _ body: (inout ReviewTabState) -> Void) {
        guard let index = session.tabs.firstIndex(where: { $0.pullRequest == identity }) else { return }
        body(&session.tabs[index])
    }

    func mutateTabForTesting(_ id: UUID, _ body: (inout ReviewTabState) -> Void) { mutateTab(id, body) }
}
