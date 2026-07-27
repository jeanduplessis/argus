import SwiftUI

struct PullRequestReviewTab: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    @State private var showComposer = false
    @State private var submitConfirmation: SubmitReviewConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            header
            revisionNotice
            Picker("Review section", selection: sectionBinding) {
                ForEach(ReviewSection.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            switch tab.section {
            case .files:
                files
            case .activity:
                ActivityView(items: tab.activity)
            case .checks:
                ChecksView(checks: tab.checks)
            }
        }
        .alert("Submit Review?", isPresented: submitConfirmationPresented) {
            Button("Cancel", role: .cancel) {
                submitConfirmation = nil
            }
            Button("Submit") {
                guard let confirmation = submitConfirmation else { return }
                submitConfirmation = nil
                Task { await model.submitReview(tabID: tab.id, pendingReview: confirmation.pendingReview) }
            }
        } message: {
            if let confirmation = submitConfirmation {
                    Text(confirmation.message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewNextChangedFile)) { _ in
            selectNext(unviewed: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewNextUnviewedFile)) { _ in
            selectNext(unviewed: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewShowSummary)) { _ in
            showComposer = true
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Pull Request #\(tab.pullRequest.number)")
                    .font(.headline)
                Text("\(tab.pullRequest.repository.owner)/\(tab.pullRequest.repository.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if tab.loadState == .refreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing Pull Request")
            }
            Text(refreshDescription)
                .font(.caption)
                .foregroundStyle(tab.loadState == .stale ? .orange : .secondary)
            if let pullRequestURL {
                Link(destination: pullRequestURL) {
                    Image(systemName: "arrow.up.forward.app")
                        .frame(width: 20, height: 20)
                }
                .help("Open Pull Request on GitHub")
                .accessibilityLabel("Open Pull Request on GitHub")
            }
            reviewIcon("arrow.clockwise", "Retry Pull Request refresh") {
                Task { await model.refreshTab(tabID: tab.id) }
            }
            reviewIcon("chevron.down", "Next changed file") { selectNext(unviewed: false) }
            reviewIcon("eye.slash", "Next unviewed file") { selectNext(unviewed: true) }
            reviewIcon("sidebar.left", "Toggle changed files") { toggle(.files) }
            reviewIcon("text.bubble", "Toggle conversations") { toggle(.conversations) }
        }
        .padding(10)
    }

    @ViewBuilder
    private var revisionNotice: some View {
        if tab.announcedHeadCommit != nil {
            HStack {
                Text("New commits are available.")
                Spacer()
                Button("Update") {
                    Task { await model.updateToAnnouncedRevision(tabID: tab.id) }
                }
            }
            .font(.caption)
            .padding(8)
            .background(.orange.opacity(0.18))
            .accessibilityLabel("New commits available; loaded Review Revision remains unchanged")
        }
    }

    private var files: some View {
        GeometryReader { proxy in
            ZStack {
                HStack(spacing: 0) {
                    if proxy.size.width > 760 && !tab.paneState.filesCollapsed {
                        ChangedFilesView(model: model, tab: tab)
                            .frame(width: CGFloat(tab.paneState.filesWidth))
                        ReviewResizeDivider(
                            width: binding(\.filesWidth, bounds: ReviewPaneState.fileListWidthBounds),
                            collapsed: binding(\.filesCollapsed),
                            bounds: ReviewPaneState.fileListWidthBounds
                        )
                    }
                    ReviewDiffView(model: model, tab: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if proxy.size.width > 980 && !tab.paneState.conversationsCollapsed {
                        ReviewResizeDivider(
                            width: binding(\.conversationsWidth, bounds: ReviewPaneState.fileListWidthBounds),
                            collapsed: binding(\.conversationsCollapsed),
                            bounds: ReviewPaneState.fileListWidthBounds
                        )
                        ConversationsView(model: model, tab: tab)
                            .frame(width: CGFloat(tab.paneState.conversationsWidth))
                    }
                }
                compactDrawer(in: proxy.size)
            }
        }
        .overlay(alignment: .bottom) { reviewFooter }
    }

    @ViewBuilder
    private func compactDrawer(in size: CGSize) -> some View {
        switch tab.paneState.activeDrawer {
        case .files where size.width <= 760:
            reviewDrawer(title: "Changed files", width: drawerWidth(tab.paneState.filesWidth, in: size)) {
                ChangedFilesView(model: model, tab: tab)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .conversations where size.width <= 980:
            reviewDrawer(title: "Conversations", width: drawerWidth(tab.paneState.conversationsWidth, in: size)) {
                ConversationsView(model: model, tab: tab)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        default:
            EmptyView()
        }
    }

    private func reviewDrawer<Content: View>(
        title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Close", action: closeDrawer)
                    .help("Close \(title) drawer")
                    .accessibilityLabel("Close \(title) drawer")
            }
            .padding(8)
            Divider()
            content()
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func drawerWidth(_ storedWidth: Double, in size: CGSize) -> CGFloat {
        let boundedWidth = ReviewPaneState.normalized(storedWidth, to: ReviewPaneState.fileListWidthBounds)
        // Preserve enough of the diff for orientation and keyboard interaction.
        return min(CGFloat(boundedWidth), max(0, size.width * 0.6))
    }

    private var reviewFooter: some View {
        VStack(spacing: 6) {
            HStack {
                Text(
                    "\(tab.pendingReview.inlineDrafts.count) drafts · \(tab.pendingReview.disposition?.rawValue ?? "Select disposition")"
                )
                .font(.caption)
                Spacer()
                Button(showComposer ? "Hide Review" : "Review") { showComposer.toggle() }
            }
            if showComposer {
                TextField("Review summary", text: summaryBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Picker("Review disposition", selection: dispositionBinding) {
                    Text("Select disposition").tag(ReviewDisposition?.none)
                    ForEach(ReviewDisposition.allCases, id: \.self) {
                        Text($0.rawValue).tag(Optional($0))
                    }
                }
                .pickerStyle(.segmented)
                Button(model.isSubmittingReview(in: tab.id) ? "Submitting Review…" : "Submit Review") {
                    submitConfirmation = .init(
                        pullRequestNumber: tab.pullRequest.number,
                        pendingReview: tab.pendingReview
                    )
                }
                .disabled(!ReviewSubmissionEligibility.canSubmit(
                    pendingReview: tab.pendingReview,
                    providerWriteEligible: model.isProviderWriteEligible(in: tab.id),
                    isSubmitting: model.isSubmittingReview(in: tab.id)
                ))
                .accessibilityLabel(model.isSubmittingReview(in: tab.id) ? "Submitting Review" : "Submit Review")
                .accessibilityValue(model.isProviderWriteEligible(in: tab.id) ? "Ready to submit" : "Provider writes unavailable")
            }
        }
        .padding(8)
        .background(.bar)
    }

    private var sectionBinding: Binding<ReviewSection> {
        Binding(get: { tab.section }, set: { section in model.mutateTab(tab.id) { $0.section = section } })
    }
    private var submitConfirmationPresented: Binding<Bool> {
        Binding(get: { submitConfirmation != nil }, set: { if !$0 { submitConfirmation = nil } })
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { tab.pendingReview.summary },
            set: { text in model.mutateTab(tab.id) { $0.pendingReview.summary = text } })
    }
    private var dispositionBinding: Binding<ReviewDisposition?> {
        Binding(
            get: { tab.pendingReview.disposition },
            set: { value in model.mutateTab(tab.id) { $0.pendingReview.disposition = value } })
    }
    private var pullRequestURL: URL? {
        guard tab.pullRequest.isValid else { return nil }
        return URL(
            string:
                "https://\(tab.pullRequest.repository.host)/\(tab.pullRequest.repository.owner)/\(tab.pullRequest.repository.name)/pull/\(tab.pullRequest.number)"
        )
    }
    private var refreshDescription: String {
        tab.loadState == .stale
            ? "Offline or stale"
            : "Last refresh \(tab.lastSuccessfulRefresh?.formatted(date: .omitted, time: .shortened) ?? "never")"
    }
    private func toggle(_ drawer: ReviewDrawer) {
        model.mutateTab(tab.id) { $0.paneState.activeDrawer = $0.paneState.activeDrawer == drawer ? nil : drawer }
    }
    private func closeDrawer() {
        model.mutateTab(tab.id) { $0.paneState.activeDrawer = nil }
    }
    private func selectNext(unviewed: Bool) {
        if let file = tab.nextFile(after: tab.selectedFilePath, unviewedOnly: unviewed) {
            model.selectFile(file.path, in: tab.id)
        }
    }
    private func binding(
        _ keyPath: WritableKeyPath<ReviewPaneState, Double>,
        bounds: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { tab.paneState[keyPath: keyPath] },
            set: { value in
                model.mutateTab(tab.id) { $0.paneState[keyPath: keyPath] = ReviewPaneState.normalized(value, to: bounds) }
            })
    }
    private func binding(_ keyPath: WritableKeyPath<ReviewPaneState, Bool>) -> Binding<Bool> {
        Binding(
            get: { tab.paneState[keyPath: keyPath] },
            set: { value in model.mutateTab(tab.id) { $0.paneState[keyPath: keyPath] = value } })
    }
}

private struct ReviewResizeDivider: View {
    @Binding var width: Double
    @Binding var collapsed: Bool
    let bounds: ClosedRange<Double>
    @State private var initial: Double = 0
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(width: 12)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { collapsed.toggle() }
            .gesture(
                DragGesture(minimumDistance: 1).onChanged { value in
                    if initial == 0 { initial = width }
                    width = ReviewPaneState.normalized(initial + value.translation.width, to: bounds)
                }.onEnded { _ in initial = 0 }
            )
            .help("Drag to resize pane; double-click to collapse")
            .accessibilityLabel("Resizable review pane divider")
    }
}

private struct ChangedFilesView: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    @State private var draftLine = ""
    @State private var draftBody = ""
    @State private var selectedDraftSide: ReviewDraftSide = .right
    var body: some View {
        VStack(spacing: 6) {
            TextField(
                "Filter files",
                text: Binding(
                    get: { tab.fileFilter.pathQuery },
                    set: { query in model.mutateTab(tab.id) { $0.fileFilter.pathQuery = query } })
            )
            .textFieldStyle(.roundedBorder)
            .padding(8)
            List(tab.changedFiles.filter(tab.fileFilter.matches)) { file in
                Button {
                    model.selectFile(file.path, in: tab.id)
                } label: {
                    HStack {
                        Image(systemName: file.viewedState == .viewed ? "checkmark.circle.fill" : "circle")
                        Text(file.path).lineLimit(1)
                        Spacer()
                        if file.publishedConversationCount > 0 {
                            Label("\(file.publishedConversationCount)", systemImage: "text.bubble")
                        }
                        if file.hasUnresolvedConversation { Image(systemName: "exclamationmark.bubble.fill") }
                        if file.hasLocalDraft { Image(systemName: "pencil.circle.fill") }
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(
                    "\(file.path), \(file.publishedConversationCount) conversations\(file.hasUnresolvedConversation ? ", unresolved conversation" : "")"
                )
            }
            inlineDraftForm
        }
        .padding(.bottom, 4)
    }
    private var inlineDraftForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New inline draft").font(.caption).bold()
            TextField("Line number", text: $draftLine).textFieldStyle(.roundedBorder)
            if let selectedFile, let line = Int(draftLine),
                !ReviewDraftAnchor(path: selectedFile.path, line: line, side: draftSide(for: selectedFile)).isValid(for: selectedFile)
            {
                Text("Choose a line included in the loaded diff patch.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Invalid inline draft anchor: choose a line included in the loaded diff patch")
            } else if let selectedFile, selectedFile.validAnchorCoordinates.isEmpty {
                Text("Inline comments are unavailable because GitHub did not provide a complete diff patch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Inline comments unavailable: complete diff patch missing")
            }
            if let selectedFile {
                switch selectedFile.status {
                case .modified, .renamed, .copied:
                    Picker("Diff side", selection: $selectedDraftSide) {
                        Text("Left").tag(ReviewDraftSide.left)
                        Text("Right").tag(ReviewDraftSide.right)
                    }
                    .pickerStyle(.segmented)
                case .deleted:
                    Text("Left side").font(.caption).foregroundStyle(.secondary)
                case .added:
                    Text("Right side").font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            TextField("Draft comment", text: $draftBody, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("Add Draft") {
                guard let selectedFile, let line = Int(draftLine) else { return }
                model.addInlineDraft(
                    path: selectedFile.path,
                    line: line,
                    side: draftSide(for: selectedFile),
                    body: draftBody,
                    in: tab.id
                )
                draftLine = ""
                draftBody = ""
            }
            .disabled(
                selectedFile == nil
                    || Int(draftLine).map { line in
                        ReviewDraftAnchor(path: selectedFile!.path, line: line, side: draftSide(for: selectedFile!)).isValid(for: selectedFile!)
                    } != true
            )
        }
        .padding(.horizontal, 8)
    }

    private var selectedFile: ReviewChangedFile? {
        tab.changedFiles.first { $0.path == tab.selectedFilePath }
    }

    private func draftSide(for file: ReviewChangedFile) -> ReviewDraftSide {
        switch file.status {
        case .deleted:
            .left
        case .added:
            .right
        default:
            selectedDraftSide
        }
    }
}

private struct ReviewDiffView: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    @State private var input: ArgusDiffInput?
    @State private var message: String?
    var body: some View {
        VStack(spacing: 0) {
            if let file = tab.changedFiles.first(where: { $0.path == tab.selectedFilePath }) {
                HStack {
                    Text(file.path).font(.caption).lineLimit(1)
                    if let line = tab.selectedLine { Text("Line \(line)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    let viewedAction = tab.viewedAction
                    Button(viewedAction.title) {
                        model.setViewed(viewedAction.target, path: file.path, in: tab.id)
                    }
                    .font(.caption)
                    .accessibilityLabel(viewedAction.title)
                    .accessibilityValue(viewedAction.status)
                    .disabled(!model.isProviderWriteEligible(in: tab.id))
                }
                .padding(8)
                Divider()
                Group {
                    if file.contentState != .available || file.status == .binary {
                        ContentUnavailableView(
                            "Diff unavailable", systemImage: "doc.questionmark",
                            description: Text("This \(file.contentState.rawValue) file cannot be rendered as text."))
                    } else if let input {
                        ArgusDiffView(input: input, onError: { message = $0 })
                    } else if let message {
                        ContentUnavailableView(
                            "Diff unavailable", systemImage: "doc.questionmark", description: Text(message))
                    } else {
                        ProgressView("Loading exact Review Revision diff")
                    }
                }
                .task(id: "\(tab.revision?.baseCommit ?? "")-\(tab.revision?.headCommit ?? "")-\(file.path)") {
                    await load(file)
                }
            } else {
                ContentUnavailableView("No changed files", systemImage: "doc")
            }
        }
    }
    private func load(_ file: ReviewChangedFile) async {
        input = nil
        message = nil
        do {
            let loadedInput = try await model.diffInput(for: file, in: tab)
            guard model.tab(tab.id)?.selectedFilePath == file.path else { return }
            input = loadedInput
        } catch is CancellationError {} catch {
            guard model.tab(tab.id)?.selectedFilePath == file.path else { return }
            message = error.localizedDescription
        }
    }
}

private struct ConversationsView: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    var body: some View {
        let visible = tab.conversations.filter { $0.path == nil || $0.path == tab.selectedFilePath }
        VStack(alignment: .leading) {
            Text("Conversations").font(.headline).padding(8)
            if visible.isEmpty {
                ContentUnavailableView("No conversations", systemImage: "text.bubble")
            } else {
                List(visible) { ConversationRow(model: model, tab: tab, conversation: $0) }
            }
            Spacer()
        }
    }
}

private struct ConversationRow: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    let conversation: ReviewConversation
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if let path = conversation.path { model.selectFile(path, line: conversation.line, in: tab.id) }
            } label: {
                Text(conversation.isResolved ? "Resolved" : "Unresolved").font(.caption).bold()
            }
            .buttonStyle(.plain)
            .help("Open conversation in diff")
            if conversation.isResolved {
                if conversation.permissions.canUnresolve {
                    let isSettingResolution = model.isSettingResolution(conversationID: conversation.id, in: tab.id)
                    Button(isSettingResolution ? "Unresolving…" : "Unresolve") {
                        Task { await model.setResolved(false, conversationID: conversation.id, in: tab.id) }
                    }
                    .disabled(!model.isProviderWriteEligible(in: tab.id) || isSettingResolution)
                    .accessibilityLabel(isSettingResolution ? "Unresolving conversation" : "Unresolve conversation")
                    .accessibilityValue(
                        isSettingResolution
                            ? "Setting resolution"
                            : model.isProviderWriteEligible(in: tab.id) ? "Ready to unresolve" : "Provider writes unavailable")
                }
            } else if conversation.permissions.canResolve {
                    let isSettingResolution = model.isSettingResolution(conversationID: conversation.id, in: tab.id)
                    Button(isSettingResolution ? "Resolving…" : "Resolve") {
                        Task { await model.setResolved(true, conversationID: conversation.id, in: tab.id) }
                    }
                    .disabled(!model.isProviderWriteEligible(in: tab.id) || isSettingResolution)
                    .accessibilityLabel(isSettingResolution ? "Resolving conversation" : "Resolve conversation")
                    .accessibilityValue(
                        isSettingResolution
                            ? "Setting resolution"
                            : model.isProviderWriteEligible(in: tab.id) ? "Ready to resolve" : "Provider writes unavailable")
                }
            ForEach(conversation.comments) { Text($0.body).textSelection(.enabled) }
            if conversation.permissions.canReply {
                TextField("Reply", text: replyBinding, axis: .vertical).textFieldStyle(.roundedBorder)
                Button(model.isSendingReply(conversationID: conversation.id, in: tab.id) ? "Sending…" : "Send") {
                    Task { await model.sendReply(conversationID: conversation.id, in: tab.id) }
                }
                .disabled(
                    replyBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !model.isProviderWriteEligible(in: tab.id)
                        || model.isSendingReply(conversationID: conversation.id, in: tab.id)
                )
                .accessibilityLabel(
                    model.isSendingReply(conversationID: conversation.id, in: tab.id)
                        ? "Sending reply"
                        : "Send reply"
                )
                .accessibilityValue(model.isProviderWriteEligible(in: tab.id) ? "Ready to send" : "Provider writes unavailable")
            }
        }
    }
    private var replyBinding: Binding<String> {
        Binding(
            get: { tab.replyDrafts.first(where: { $0.conversationID == conversation.id })?.body ?? "" },
            set: { text in
                model.mutateTab(tab.id) { state in
                    if let index = state.replyDrafts.firstIndex(where: { $0.conversationID == conversation.id }) {
                        state.replyDrafts[index].body = text
                    } else {
                        state.replyDrafts.append(.init(conversationID: conversation.id, body: text))
                    }
                }
            })
    }
}

private struct ActivityView: View {
    let items: [ReviewActivityItem]

    var body: some View {
        List(items) {
            Text("\($0.kind.capitalized) · \($0.author ?? "Unknown")")
        }
    }
}

private struct ChecksView: View {
    let checks: ReviewChecksState?
    var body: some View {
        if let checks {
            List(checks.checks) { Text("\($0.name): \($0.conclusion ?? $0.status)") }
        } else {
            ContentUnavailableView("No checks loaded", systemImage: "checkmark.circle")
        }
    }
}

@MainActor
private func reviewIcon(_ name: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: name).frame(width: 20, height: 20) }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
}
