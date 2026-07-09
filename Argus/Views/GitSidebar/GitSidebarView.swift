import AppKit
import SwiftUI

struct GitFileTreeNode: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(children: [GitFileTreeNode])
        case file(GitFileChange)
    }

    let id: String
    let name: String
    let path: String
    let content: Content

    var children: [GitFileTreeNode] {
        guard case .directory(let children) = content else { return [] }
        return children
    }

    var file: GitFileChange? {
        guard case .file(let file) = content else { return nil }
        return file
    }
}

struct GitFileTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(GitFileTreeNode)
        case file(GitFileChange)
    }

    let id: String
    let name: String
    let depth: Int
    let content: Content
}

enum GitFileTree {
    static func makeNodes(files: [GitFileChange]) -> [GitFileTreeNode] {
        var root = DirectoryBuilder()
        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            root.insert(file: file, components: components[...])
        }
        return root.nodes(prefix: "", sectionKey: files.first?.sectionKey ?? "")
    }

    static func visibleRows(
        nodes: [GitFileTreeNode],
        collapsedDirectoryIds: Set<String>
    ) -> [GitFileTreeRow] {
        rows(nodes: nodes, depth: 0, collapsedDirectoryIds: collapsedDirectoryIds)
    }

    private static func rows(
        nodes: [GitFileTreeNode],
        depth: Int,
        collapsedDirectoryIds: Set<String>
    ) -> [GitFileTreeRow] {
        nodes.flatMap { node in
            switch node.content {
            case .directory(let children):
                let directoryRow = GitFileTreeRow(
                    id: node.id,
                    name: node.name,
                    depth: depth,
                    content: .directory(node)
                )
                guard !collapsedDirectoryIds.contains(node.id) else { return [directoryRow] }
                return [directoryRow] + rows(
                    nodes: children,
                    depth: depth + 1,
                    collapsedDirectoryIds: collapsedDirectoryIds
                )
            case .file(let file):
                return [
                    GitFileTreeRow(
                        id: node.id,
                        name: node.name,
                        depth: depth,
                        content: .file(file)
                    )
                ]
            }
        }
    }

    private struct DirectoryBuilder {
        var directories: [String: DirectoryBuilder] = [:]
        var files: [GitFileChange] = []

        mutating func insert(file: GitFileChange, components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                files.append(file)
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insert(file: file, components: components.dropFirst())
            directories[component] = directory
        }

        func nodes(prefix: String, sectionKey: String) -> [GitFileTreeNode] {
            let directoryNodes = directories.keys.sorted().map { directoryName in
                compactedDirectoryNode(
                    name: directoryName,
                    builder: directories[directoryName]!,
                    prefix: prefix,
                    sectionKey: sectionKey
                )
            }
            let fileNodes = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                .map { file in
                    GitFileTreeNode(
                        id: file.id,
                        name: file.path.split(separator: "/").last.map(String.init) ?? file.path,
                        path: file.path,
                        content: .file(file)
                    )
                }
            return directoryNodes + fileNodes
        }

        private func compactedDirectoryNode(
            name: String,
            builder: DirectoryBuilder,
            prefix: String,
            sectionKey: String
        ) -> GitFileTreeNode {
            var names = [name]
            var path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var directory = builder

            while directory.files.isEmpty, directory.directories.count == 1,
                  let nextName = directory.directories.keys.first,
                  let nextDirectory = directory.directories[nextName]
            {
                names.append(nextName)
                path += "/\(nextName)"
                directory = nextDirectory
            }

            return GitFileTreeNode(
                id: "\(sectionKey):directory:\(path)",
                name: names.joined(separator: " / "),
                path: path,
                content: .directory(children: directory.nodes(prefix: path, sectionKey: sectionKey))
            )
        }
    }
}

private enum GitFileRowAction: String, Identifiable {
    case stage
    case unstage
    case discard
    case delete
    case diff
    case blame
    case copyPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stage:
            return "Stage File"
        case .unstage:
            return "Unstage File"
        case .discard:
            return "Discard Changes"
        case .delete:
            return "Delete File"
        case .diff:
            return "View Diff"
        case .blame:
            return "View Blame"
        case .copyPath:
            return "Copy Path"
        }
    }

    var systemImage: String {
        switch self {
        case .stage:
            return "plus.circle"
        case .unstage:
            return "minus.circle"
        case .discard:
            return "arrow.uturn.backward.circle"
        case .delete:
            return "trash"
        case .diff:
            return "doc.text.magnifyingglass"
        case .blame:
            return "person.line.dotted.person"
        case .copyPath:
            return "doc.on.doc"
        }
    }

    var operation: GitStatusFileOperation? {
        switch self {
        case .stage:
            return .stage
        case .unstage:
            return .unstage
        case .discard:
            return .discard
        case .delete:
            return .delete
        case .diff, .blame, .copyPath:
            return nil
        }
    }
}

private enum GitFileSectionAction: String, Identifiable {
    case stageAll
    case unstageAll
    case discardAll
    case deleteAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stageAll:
            return "Stage All Files"
        case .unstageAll:
            return "Unstage All Files"
        case .discardAll:
            return "Discard All Changes"
        case .deleteAll:
            return "Delete All Untracked Files"
        }
    }

    var operation: GitStatusFileOperation {
        switch self {
        case .stageAll:
            return .stage
        case .unstageAll:
            return .unstage
        case .discardAll:
            return .discard
        case .deleteAll:
            return .delete
        }
    }

    var isDestructive: Bool {
        operation.requiresConfirmation
    }
}

struct GitSidebarView: View {
    let showsHeader: Bool
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var viewModel: GitStatusViewModel
    @State private var autoRefreshController = GitStatusAutoRefreshController()
    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true
    @State private var untrackedExpanded = true
    @State private var collapsedDirectoryIds: Set<String> = []
    @State private var hoveredDirectoryId: String?
    @State private var hoveredFileId: String?
    @State private var hoveredFileActionId: String?
    @State private var hoveredSectionActionId: String?
    @FocusState private var focusedFileId: String?

    init(showsHeader: Bool = true) {
        self.showsHeader = showsHeader
    }

    var body: some View {
        return VStack(spacing: 0) {
            if showsHeader {
                header
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if showsHeader {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            }
        }
        .task {
            guard let owner = selectedSnapshotOwner else {
                viewModel.clearSelection()
                autoRefreshController.stop()
                return
            }
            viewModel.activate(owner)
            startAutoRefresh(owner: owner)
            await refresh(owner: owner)
        }
        .onChange(of: workspaceManager.selectedWorkspaceId) { _, _ in
            guard let owner = selectedSnapshotOwner else {
                viewModel.clearSelection()
                autoRefreshController.stop()
                return
            }
            viewModel.activate(owner)
            startAutoRefresh(owner: owner)
            Task { await refresh(owner: owner) }
        }
        .onDisappear {
            autoRefreshController.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text("Changes")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            ZStack {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 12, height: 12)
            Button {
                guard let owner = selectedSnapshotOwner else { return }
                Task { await refresh(owner: owner) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing || selectedSnapshotOwner == nil)
            .cursor(viewModel.isRefreshing || selectedSnapshotOwner == nil ? .arrow : .pointingHand)
            .help("Refresh changes")
            .accessibilityLabel("Refresh changes")
        }
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner) {
            ownedContent(owner: owner)
        } else if selectedSnapshotOwner == nil {
            emptyMessage("Select a workspace", systemImage: "folder")
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading changes")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ownedContent(owner: GitStatusSnapshotOwner) -> some View {
        switch viewModel.state {
        case .idle:
            emptyMessage("Select a workspace", systemImage: "folder")
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        case .loaded(let summary):
            statusContent(summary, owner: owner)
        case .notRepository(let rootPath):
            notRepositoryContent(rootPath: rootPath)
        case .repositoryInitializationFailed(let rootPath, let message):
            notRepositoryContent(rootPath: rootPath, message: message)
        case .fileOperationFailed(_, let message):
            operationFailureContent(message)
        case .error(_, let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text("Git status failed")
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func statusContent(_ summary: GitStatusSummary, owner: GitStatusSnapshotOwner) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            branchBar(summary)

            if summary.isClean {
                Label("Working tree clean", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if summary.isFileDisplayCapped {
                Text("Showing first \(GitStatusSummary.displayFileLimit) of \(summary.totalFileCount) files")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            ScrollView {
                VStack(spacing: 0) {
                    fileSection(title: "Staged", sectionKey: "staged", count: summary.stagedCount, files: summary.stagedFiles, isExpanded: $stagedExpanded, owner: owner)
                    fileSection(title: "Unstaged", sectionKey: "unstaged", count: summary.unstagedCount, files: summary.unstagedFiles, isExpanded: $unstagedExpanded, owner: owner)
                    fileSection(title: "Untracked", sectionKey: "untracked", count: summary.untrackedCount, files: summary.untrackedFiles, isExpanded: $untrackedExpanded, owner: owner)
                }
            }
        }
    }

    private func branchBar(_ summary: GitStatusSummary) -> some View {
        let totals = totalDiffStats(summary)
        let allCollapsed = allSectionsCollapsed(summary)

        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text(summary.branchName ?? "Detached HEAD")
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Text("\(summary.totalFileCount) \(summary.totalFileCount == 1 ? "file" : "files")")
                .foregroundColor(.secondary)
                .fixedSize()
            Text("+\(totals.additions)")
                .foregroundColor(.green)
                .fixedSize()
            Text("-\(totals.deletions)")
                .foregroundColor(.red)
                .fixedSize()

            if let upstreamName = summary.upstreamName {
                Text(upstreamText(summary, upstreamName: upstreamName))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                setAllSectionsExpanded(allCollapsed, summary: summary)
            } label: {
                Image(systemName: allCollapsed
                    ? "arrow.up.and.line.horizontal.and.arrow.down"
                    : "arrow.down.and.line.horizontal.and.arrow.up")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(allCollapsed ? "Expand All" : "Collapse All")
            .accessibilityLabel(allCollapsed ? "Expand all file sections" : "Collapse all file sections")
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private func totalDiffStats(_ summary: GitStatusSummary) -> (additions: Int, deletions: Int) {
        let files = summary.stagedFiles + summary.unstagedFiles + summary.untrackedFiles
        return files.reduce(into: (additions: 0, deletions: 0)) { totals, file in
            totals.additions += file.additions ?? 0
            totals.deletions += file.deletions ?? 0
        }
    }

    private func allSectionsCollapsed(_ summary: GitStatusSummary) -> Bool {
        !stagedExpanded && !unstagedExpanded && !untrackedExpanded
    }

    private func setAllSectionsExpanded(_ isExpanded: Bool, summary: GitStatusSummary) {
        stagedExpanded = isExpanded
        unstagedExpanded = isExpanded
        untrackedExpanded = isExpanded
    }

    private func upstreamText(_ summary: GitStatusSummary, upstreamName: String) -> String {
        var parts = [upstreamName]
        if summary.aheadCount > 0 { parts.append("↑\(summary.aheadCount)") }
        if summary.behindCount > 0 { parts.append("↓\(summary.behindCount)") }
        return parts.joined(separator: " ")
    }

    private func fileSection(
        title: String,
        sectionKey: String,
        count: Int,
        files: [GitFileChange],
        isExpanded: Binding<Bool>,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let actions = sectionActions(title: title, count: count)
        let visibleAction = actions.first(where: { !$0.isDestructive })
        let destructiveActions = actions.filter(\.isDestructive)

        return VStack(spacing: 0) {
            HStack {
                Button {
                    isExpanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .cursor(.pointingHand)
                .help("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title) section")
                .accessibilityLabel("\(isExpanded.wrappedValue ? "Collapse" : "Expand") \(title) section")
                .accessibilityValue("\(count) \(count == 1 ? "change" : "changes")")

                Spacer()

                if let action = visibleAction {
                    let actionHoverId = "\(sectionKey):\(action.id)"
                    Button {
                        Task { await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count, owner: owner) }
                    } label: {
                        Text(action.title)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(hoveredSectionActionId == actionHoverId ? Color.primary.opacity(0.1) : Color.clear)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!viewModel.canPerformActions(for: owner))
                    .onHover { isHovering in
                        if isHovering {
                            hoveredSectionActionId = actionHoverId
                        } else if hoveredSectionActionId == actionHoverId {
                            hoveredSectionActionId = nil
                        }
                    }
                    .cursor(viewModel.canPerformActions(for: owner) ? .pointingHand : .arrow)
                    .help(action.title)
                }

                if !destructiveActions.isEmpty {
                    Menu {
                        ForEach(destructiveActions) { action in
                            Button(action.title, role: .destructive) {
                                Task { await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count, owner: owner) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!viewModel.canPerformActions(for: owner))
                    .help("More \(title.lowercased()) actions")
                    .accessibilityLabel("More \(title.lowercased()) actions")
                }
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isExpanded.wrappedValue {
                ForEach(
                    GitFileTree.visibleRows(
                        nodes: GitFileTree.makeNodes(files: files),
                        collapsedDirectoryIds: collapsedDirectoryIds
                    )
                ) { row in
                    switch row.content {
                    case .directory(let directory):
                        directoryRow(directory, depth: row.depth)
                    case .file(let file):
                        fileRow(file, name: row.name, depth: row.depth, owner: owner)
                    }
                }
            }
        }
        .contextMenu {
            ForEach(actions) { action in
                if action.isDestructive {
                    Button(action.title, role: .destructive) {
                        Task { await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count, owner: owner) }
                    }
                    .disabled(!viewModel.canPerformActions(for: owner))
                } else {
                    Button(action.title) {
                        Task { await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count, owner: owner) }
                    }
                    .disabled(!viewModel.canPerformActions(for: owner))
                }
            }
        }
    }

    private func directoryRow(_ directory: GitFileTreeNode, depth: Int) -> some View {
        let isExpanded = !collapsedDirectoryIds.contains(directory.id)

        return Button {
            if isExpanded {
                collapsedDirectoryIds.insert(directory.id)
            } else {
                collapsedDirectoryIds.remove(directory.id)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                Text(directory.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, treeRowLeadingPadding(depth: depth))
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hoveredDirectoryId == directory.id ? ChromeColors.hoveredTabFill : Color.clear)
        }
        .onHover { isHovering in
            if isHovering {
                hoveredDirectoryId = directory.id
            } else if hoveredDirectoryId == directory.id {
                hoveredDirectoryId = nil
            }
        }
        .cursor(.pointingHand)
        .help("\(isExpanded ? "Collapse" : "Expand") directory \(directory.path)")
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") directory \(directory.path)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private func fileRow(
        _ file: GitFileChange,
        name: String,
        depth: Int,
        owner: GitStatusSnapshotOwner
    ) -> some View {
        let revealsActions = hoveredFileId == file.id || focusedFileId == file.id

        return HStack(spacing: 7) {
            Image(systemName: file.status.systemImage)
                .foregroundColor(file.status.tintColor)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            ZStack(alignment: .trailing) {
                HStack(spacing: 5) {
                    if let additions = file.additions {
                        Text("+\(additions)")
                            .foregroundColor(.green)
                    }
                    if let deletions = file.deletions {
                        Text("-\(deletions)")
                            .foregroundColor(.red)
                    }
                }
                .opacity(revealsActions ? 0 : 1)

                HStack(spacing: 5) {
                    ForEach(fileActions(for: file)) { action in
                        let actionHoverId = "\(file.id):\(action.id)"
                        Button {
                            perform(action, for: file, owner: owner)
                        } label: {
                            Image(systemName: action.systemImage)
                                .frame(width: 20, height: 20)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(hoveredFileActionId == actionHoverId ? Color.primary.opacity(0.1) : Color.clear)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canPerformActions(for: owner))
                        .onHover { isHovering in
                            if isHovering {
                                hoveredFileActionId = actionHoverId
                            } else if hoveredFileActionId == actionHoverId {
                                hoveredFileActionId = nil
                            }
                        }
                        .cursor(viewModel.canPerformActions(for: owner) ? .pointingHand : .arrow)
                        .help(action.title)
                        .accessibilityLabel(action.title)
                    }
                }
                .opacity(revealsActions ? 1 : 0)
                .allowsHitTesting(revealsActions)
                .accessibilityHidden(!revealsActions)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.leading, treeRowLeadingPadding(depth: depth))
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hoveredFileId == file.id ? ChromeColors.hoveredTabFill : Color.clear)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedFileId, equals: file.id)
        .onHover { isHovering in
            if isHovering {
                hoveredFileId = file.id
            } else if hoveredFileId == file.id {
                hoveredFileId = nil
            }
        }
        .accessibilityLabel(file.path)
        .accessibilityValue(fileAccessibilityValue(file))
        .accessibilityActions {
            ForEach(fileActions(for: file)) { action in
                Button(action.title) {
                    perform(action, for: file, owner: owner)
                }
            }
        }
        .contextMenu {
            ForEach(fileActions(for: file)) { action in
                if action == .discard || action == .delete {
                    Button(action.title, role: .destructive) {
                        perform(action, for: file, owner: owner)
                    }
                    .disabled(!viewModel.canPerformActions(for: owner))
                } else {
                    Button(action.title) {
                        perform(action, for: file, owner: owner)
                    }
                    .disabled(!viewModel.canPerformActions(for: owner))
                }
            }
        }
    }

    private func treeRowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 16)
    }

    private func fileActions(for file: GitFileChange) -> [GitFileRowAction] {
        switch file.sectionKey {
        case "staged":
            return [.unstage, .diff, .blame, .copyPath]
        case "unstaged":
            return [.stage, .discard, .diff, .blame, .copyPath]
        case "untracked":
            return [.stage, .delete, .diff, .copyPath]
        default:
            return [.copyPath]
        }
    }

    private func perform(
        _ action: GitFileRowAction,
        for file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) {
        guard selectedSnapshotOwner == owner, viewModel.canPerformActions(for: owner) else { return }
        switch action {
        case .stage, .unstage:
            Task { await performFileOperation(action.operation, path: file.path, owner: owner) }
        case .discard, .delete:
            Task { await confirmAndPerformFileOperation(action.operation, paths: [file.path], owner: owner) }
        case .diff:
            Task { await showPreview(kind: .diff, file: file, owner: owner) }
        case .blame:
            Task { await showPreview(kind: .blame, file: file, owner: owner) }
        case .copyPath:
            viewModel.copyPath(file.path)
        }
    }

    private func fileAccessibilityValue(_ file: GitFileChange) -> String {
        var values = [file.status.displayName]
        if let originalPath = file.originalPath { values.append("from \(originalPath)") }
        if let additions = file.additions { values.append("\(additions) lines added") }
        if let deletions = file.deletions { values.append("\(deletions) lines removed") }
        return values.joined(separator: ", ")
    }

    private func sectionActions(title: String, count: Int) -> [GitFileSectionAction] {
        guard count > 0 else { return [] }
        switch title {
        case "Staged":
            return [.unstageAll]
        case "Unstaged":
            return [.stageAll, .discardAll]
        case "Untracked":
            return [.stageAll, .deleteAll]
        default:
            return []
        }
    }

    private func notRepositoryContent(rootPath: String, message: String? = nil) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Not a git repository")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(rootPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            Button {
                Task { await initializeRepository() }
            } label: {
                Text("Initialize Git Repository")
            }
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func operationFailureContent(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("Git file operation failed")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button {
                guard let owner = selectedSnapshotOwner else { return }
                Task { await refresh(owner: owner) }
            } label: {
                Text("Refresh Changes")
            }
            .controlSize(.small)
            .disabled(viewModel.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyMessage(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh(owner: GitStatusSnapshotOwner) async {
        guard selectedSnapshotOwner == owner else { return }
        await viewModel.refresh(owner: owner)
    }

    private func initializeRepository() async {
        guard let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner) else { return }
        await viewModel.initializeRepository(owner: owner)
    }

    private func performFileOperation(
        _ operation: GitStatusFileOperation?,
        path: String,
        owner: GitStatusSnapshotOwner
    ) async {
        guard let operation, selectedSnapshotOwner == owner else { return }
        await viewModel.performFileOperation(operation, path: path, owner: owner)
    }

    private func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation?,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        guard let operation, selectedSnapshotOwner == owner else { return }
        await viewModel.confirmAndPerformFileOperation(operation, paths: paths, owner: owner)
    }

    private func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        owner: GitStatusSnapshotOwner
    ) async {
        guard selectedSnapshotOwner == owner else { return }
        await viewModel.confirmAndPerformSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            pathCount: pathCount,
            owner: owner
        )
    }

    private func showPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) async {
        guard selectedSnapshotOwner == owner else { return }

        let result = await viewModel.loadPreview(kind: kind, file: file, owner: owner)
        guard let sourceWorkspace = workspaceManager.workspaces.first(where: { $0.id == owner.workspaceId }) else {
            return
        }

        switch result {
        case .loaded(let preview):
            sourceWorkspace.openGitPreviewPanel(rootPath: owner.rootPath, preview: preview)
        case .failed(let kind, let path, let message):
            sourceWorkspace.openGitPreviewPanel(
                rootPath: owner.rootPath,
                preview: GitPreview(kind: kind, path: path, content: .ansiText(message))
            )
        }
    }

    private func startAutoRefresh(owner: GitStatusSnapshotOwner) {
        autoRefreshController.start(rootPath: owner.rootPath) {
            await refresh(owner: owner)
        }
    }

    private var selectedSnapshotOwner: GitStatusSnapshotOwner? {
        guard let workspace = workspaceManager.selectedWorkspace,
              let context = statusContext()
        else { return nil }
        return viewModel.owner(workspaceId: workspace.id, context: context)
    }

    private func statusContext() -> GitStatusRootContext? {
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        return gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )
    }
}
