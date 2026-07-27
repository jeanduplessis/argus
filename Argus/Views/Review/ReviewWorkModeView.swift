import SwiftUI

struct WorkModePicker: View {
    @Binding var mode: WorkMode
    let hasAttention: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker("Work Mode", selection: $mode) {
                Text("Code").tag(WorkMode.code)
                Text("Review").tag(WorkMode.review)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            if hasAttention {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Review attention")
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 8)
        .padding(.top, 28)  // Space for titlebar traffic lights
        .accessibilityLabel("Work Mode")
    }
}

struct ReviewWorkModeView: View {
    @ObservedObject var model: ReviewWorkModeModel

    var body: some View {
        VStack(spacing: 0) {
            ReviewTabBar(model: model)
            if let id = model.store.session.activeTabID, let tab = model.tab(id) {
                PullRequestReviewTab(model: model, tab: tab)
            } else {
                ContentUnavailableView(
                    "No Pull Request Open",
                    systemImage: "arrow.triangle.pull",
                    description: Text("Paste a Pull Request URL in the Review sidebar.")
                )
            }
        }
        .background(ChromeColors.shellBackground)
    }
}

struct ReviewSidebarView: View {
    @ObservedObject var model: ReviewWorkModeModel
    @State private var url = ""
    @State private var filter = ""
    @State private var discardCandidate: ReviewPullRequest?

    var body: some View {
        VStack(spacing: 0) {
            intakeControls
            refreshControls

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 6)
                    .accessibilityLabel("Refreshing Review Inbox")
            }

            List {
                reviewSection("Inbox", membership: .inbox)
                reviewSection("Saved", membership: .saved)
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .textSelection(.enabled)
                    .accessibilityLabel("Review error: \(error)")
            }
        }
        .background(ChromeColors.shellBackground)
        .alert(
            "Remove Saved Pull Request?",
            isPresented: Binding(
                get: { discardCandidate != nil },
                set: { if !$0 { discardCandidate = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                discardCandidate = nil
            }
            Button("Discard", role: .destructive) {
                if let item = discardCandidate {
                    model.discardSavedPullRequest(item.identity)
                }
                discardCandidate = nil
            }
        } message: {
            if let item = discardCandidate {
                let tab = model.store.session.tabs.first { $0.pullRequest == item.identity }
                let hasDrafts =
                    tab?.hasLocalDrafts == true
                    || model.store.session.closedAuthoredState[item.identity]?.hasContent == true
                Text(
                    "Remove Saved Pull Request #\(item.identity.number)\(tab == nil ? "" : " and close its open tab")?\(hasDrafts ? " This permanently discards unsent replies and the Pending Review." : "")"
                )
            }
        }
    }

    private var intakeControls: some View {
        HStack {
            TextField("Pull Request URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Pull Request URL")
            iconButton("arrow.right.circle.fill", help: "Open Pull Request URL") {
                Task { await model.openURL(url) }
            }
            .disabled(url.isEmpty)
        }
        .padding(8)
    }

    private var refreshControls: some View {
        HStack {
            if model.inboxHosts.count > 1 {
                Picker("Inbox host", selection: Binding(
                    get: { model.store.session.selectedInboxHost },
                    set: { model.selectInboxHost($0) }
                )) {
                    ForEach(model.inboxHosts, id: \.self) { host in
                        Text(host).tag(host)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Review Inbox host")
            }
            TextField("Filter reviews", text: $filter)
                .textFieldStyle(.roundedBorder)
            iconButton("arrow.clockwise", help: "Retry Review Inbox refresh") {
                Task { await model.refreshInbox() }
            }
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func reviewSection(_ title: String, membership: ReviewMembership) -> some View {
        let items = model.store.session.pullRequests
            .filter { $0.membership == membership && matches($0) }
            .sorted { $0.identity < $1.identity }

        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack {
                        Button {
                            Task { await model.open(identity: item.identity) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(item.identity.number) \(item.title)")
                                    .lineLimit(2)
                                HStack(spacing: 4) {
                                    Text(
                                        item.author.isEmpty
                                            ? item.state.rawValue : "\(item.author) · \(item.state.rawValue)")
                                    indicator(for: item)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .help("Open Pull Request #\(item.identity.number)")
                        .accessibilityLabel("Pull Request \(item.identity.number), \(item.title)")

                        if membership == .saved {
                            iconButton("trash", help: "Remove Saved Pull Request") {
                                discardCandidate = item
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func indicator(for item: ReviewPullRequest) -> some View {
        let tab = model.store.session.tabs.first { $0.pullRequest == item.identity }
        if tab?.hasLocalDrafts == true || model.store.session.closedAuthoredState[item.identity]?.hasContent == true {
            Image(systemName: "pencil.circle.fill")
                .accessibilityLabel("Has local drafts")
        }
        if item.attention != .none {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityLabel("\(item.attention.rawValue) attention")
        }
        if tab?.loadState == .failed {
            Image(systemName: "xmark.octagon.fill")
                .accessibilityLabel("Refresh failed")
        }
    }

    private func matches(_ item: ReviewPullRequest) -> Bool {
        guard !filter.isEmpty else { return true }
        let searchable =
            "\(item.identity.repository.owner)/\(item.identity.repository.name) \(item.title) \(item.author) \(item.identity.number)"
        return searchable.localizedCaseInsensitiveContains(filter)
    }
}

private struct ReviewTabBar: View {
    @ObservedObject var model: ReviewWorkModeModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.store.session.tabs.enumerated()), id: \.element.id) { index, tab in
                ReviewTabItem(
                    model: model,
                    tab: tab,
                    index: index,
                    isActive: tab.id == model.store.session.activeTabID
                )
            }
            Spacer()
        }
        .padding(6)
        .background(ChromeColors.shellBackground)
    }
}

private struct ReviewTabItem: View {
    @ObservedObject var model: ReviewWorkModeModel
    let tab: ReviewTabState
    let index: Int
    let isActive: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button {
                model.selectTab(tab.id, pullRequest: tab.pullRequest)
            } label: {
                HStack(spacing: 5) {
                    Text("#\(tab.pullRequest.number)")
                    if tab.hasLocalDrafts {
                        Image(systemName: "pencil.circle.fill")
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(isActive ? ChromeColors.hoveredTabFill : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .help("Pull Request #\(tab.pullRequest.number)")
            .accessibilityLabel("Pull Request tab \(tab.pullRequest.number)")

            Menu {
                Button("Move Left") {
                    model.moveTab(tab.id, to: index - 1)
                }
                .disabled(index == 0)
                Button("Move Right") {
                    model.moveTab(tab.id, to: index + 1)
                }
                .disabled(index == model.store.session.tabs.count - 1)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .help("Move Pull Request tab")
            .accessibilityLabel("Move Pull Request tab")

            iconButton("xmark", help: "Close Pull Request tab") {
                model.closeTab(tab.id)
            }
        }
        .onDrag { NSItemProvider(object: NSString(string: tab.id.uuidString)) }
        .onDrop(of: [.text], delegate: ReviewTabDropDelegate(tab: tab, index: index, model: model))
    }
}

private struct ReviewTabDropDelegate: DropDelegate {
    let tab: ReviewTabState
    let index: Int
    let model: ReviewWorkModeModel

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? NSString, let id = UUID(uuidString: value as String) else {
                return
            }
            DispatchQueue.main.async {
                model.moveTab(id, to: index)
            }
        }
        return true
    }
}

@MainActor
private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: name)
            .frame(width: 20, height: 20)
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .help(help)
    .accessibilityLabel(help)
}
