import AppKit
import SwiftUI

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
            return "Stage"
        case .unstage:
            return "Unstage"
        case .discard:
            return "Discard"
        case .delete:
            return "Delete"
        case .diff:
            return "Diff"
        case .blame:
            return "Blame"
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
            return "Stage All"
        case .unstageAll:
            return "Unstage All"
        case .discardAll:
            return "Discard All"
        case .deleteAll:
            return "Delete All"
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
}

struct GitSidebarView: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var viewModel: GitStatusViewModel
    @State private var autoRefreshController = GitStatusAutoRefreshController()
    @State private var stagedExpanded = true
    @State private var unstagedExpanded = true
    @State private var untrackedExpanded = true
    @State private var hoveredFileId: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 28)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .task {
            startAutoRefresh()
            await refresh()
        }
        .onChange(of: workspaceManager.selectedWorkspaceId) { _, _ in
            startAutoRefresh()
            Task { await refresh() }
        }
        .onDisappear {
            autoRefreshController.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.secondary)
            Text("Git Status")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh git status")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
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
            statusContent(summary)
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

    private func statusContent(_ summary: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            branchBar(summary)

            if summary.isClean {
                Label("Working tree clean", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 12)
            }

            if summary.isFileDisplayCapped {
                Text("Showing first \(GitStatusSummary.displayFileLimit) of \(summary.totalFileCount) files")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if summary.stagedCount > 0 {
                        fileSection(title: "Staged", sectionKey: "staged", count: summary.stagedCount, files: summary.stagedFiles, isExpanded: $stagedExpanded)
                    }
                    if summary.unstagedCount > 0 {
                        fileSection(title: "Unstaged", sectionKey: "unstaged", count: summary.unstagedCount, files: summary.unstagedFiles, isExpanded: $unstagedExpanded)
                    }
                    if summary.untrackedCount > 0 {
                        fileSection(title: "Untracked", sectionKey: "untracked", count: summary.untrackedCount, files: summary.untrackedFiles, isExpanded: $untrackedExpanded)
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private func branchBar(_ summary: GitStatusSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(summary.branchName ?? "Detached HEAD")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))

            if let upstreamName = summary.upstreamName {
                Text(upstreamText(summary, upstreamName: upstreamName))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
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
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(spacing: 0) {
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

                Spacer()

                ForEach(sectionActions(title: title, count: count)) { action in
                    Button {
                        Task { await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count) }
                    } label: {
                        Text(action.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help(action.title)
                }
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if isExpanded.wrappedValue {
                ForEach(files) { file in
                    fileRow(file)
                }
            }
        }
    }

    private func fileRow(_ file: GitFileChange) -> some View {
        HStack(spacing: 7) {
            Image(systemName: file.status.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(file.status.tintColor)
                .frame(width: 14)
            Text(file.path)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if hoveredFileId == file.id {
                HStack(spacing: 5) {
                    ForEach(fileActions(for: file)) { action in
                        Button {
                            switch action {
                            case .stage, .unstage:
                                Task { await performFileOperation(action.operation, path: file.path) }
                            case .discard, .delete:
                                Task { await confirmAndPerformFileOperation(action.operation, paths: [file.path]) }
                            case .diff:
                                Task { await showPreview(kind: .diff, file: file) }
                            case .blame:
                                Task { await showPreview(kind: .blame, file: file) }
                            case .copyPath:
                                viewModel.copyPath(file.path)
                            }
                        } label: {
                            Image(systemName: action.systemImage)
                        }
                        .buttonStyle(.plain)
                        .help(action.title)
                    }
                }
            } else {
                if let additions = file.additions {
                    Text("+\(additions)")
                        .foregroundColor(.green)
                }
                if let deletions = file.deletions {
                    Text("-\(deletions)")
                        .foregroundColor(.red)
                }
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .onHover { isHovering in
            hoveredFileId = isHovering ? file.id : nil
        }
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
                Text("Initialize Repository")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func operationFailureContent(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text("File operation failed")
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button {
                Task { await refresh() }
            } label: {
                Text("Refresh")
            }
            .controlSize(.small)
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

    private func refresh() async {
        guard let workspace = workspaceManager.selectedWorkspace,
              let context = statusContext()
        else { return }
        await viewModel.refresh(workspaceId: workspace.id, context: context)
    }

    private func initializeRepository() async {
        guard let context = statusContext() else { return }
        await viewModel.initializeRepository(context: context)
    }

    private func performFileOperation(_ operation: GitStatusFileOperation?, path: String) async {
        guard let operation, let context = statusContext() else { return }
        await viewModel.performFileOperation(operation, path: path, context: context)
    }

    private func confirmAndPerformFileOperation(_ operation: GitStatusFileOperation?, paths: [String]) async {
        guard let operation, let context = statusContext() else { return }
        await viewModel.confirmAndPerformFileOperation(operation, paths: paths, context: context)
    }

    private func confirmAndPerformSectionFileOperation(_ operation: GitStatusFileOperation, sectionKey: String, pathCount: Int) async {
        guard let context = statusContext() else { return }
        await viewModel.confirmAndPerformSectionFileOperation(operation, sectionKey: sectionKey, pathCount: pathCount, context: context)
    }

    private func showPreview(kind: GitPreviewKind, file: GitFileChange) async {
        guard let context = statusContext() else { return }
        await viewModel.showPreview(kind: kind, file: file, context: context, parentWindow: NSApp.mainWindow)
    }

    private func startAutoRefresh() {
        guard let context = statusContext() else {
            autoRefreshController.stop()
            return
        }
        let rootPath = viewModel.rootPath(for: context)
        autoRefreshController.start(rootPath: rootPath) {
            await refresh()
        }
    }

    private func statusContext() -> GitStatusRootContext? {
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        let project = workspaceManager.project(for: workspace.id)
        let projectRepositoryPath = project?.isCatchAll == false ? project?.repositoryPath : nil

        let kind: GitStatusRootContext.WorkspaceKind
        switch workspace.workspaceType {
        case .worktree:
            kind = .worktree
        case .mainCheckout:
            kind = .mainCheckout
        case .external:
            kind = .standalone
        }

        return GitStatusRootContext(
            kind: kind,
            currentDirectory: workspace.currentDirectory,
            worktreePath: workspace.worktreePath,
            projectRepositoryPath: projectRepositoryPath
        )
    }
}
