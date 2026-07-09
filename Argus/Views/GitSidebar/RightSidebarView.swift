import AppKit
import Foundation
import SwiftUI

private enum RightSidebarPanel: String, CaseIterable, Identifiable {
    case files
    case changes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files:
            return "Files"
        case .changes:
            return "Changes"
        }
    }

    var systemImage: String {
        switch self {
        case .files:
            return "doc"
        case .changes:
            return "arrow.triangle.branch"
        }
    }
}

struct RightSidebarView: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel
    @StateObject private var filesViewModel = WorkspaceFilesViewModel()
    @State private var selectedPanel: RightSidebarPanel = .changes

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch selectedPanel {
                case .files:
                    WorkspaceFilesView(
                        viewModel: filesViewModel,
                        workspaceId: workspaceManager.selectedWorkspace?.id,
                        rootPath: workspaceManager.selectedWorkspace?.currentDirectory
                    )
                case .changes:
                    GitSidebarView(showsHeader: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .onChange(of: filesRequest, initial: true) { _, request in
            filesViewModel.activate(request: request)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(RightSidebarPanel.allCases) { panel in
                tabButton(panel)
            }

            Spacer(minLength: 0)

            ZStack {
                if selectedPanel == .files, filesViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else if selectedPanel == .changes, gitStatusViewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 12, height: 12)

            Button {
                Task { await refreshSelectedPanel() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRefreshActive)
            .cursor(isRefreshActive ? .arrow : .pointingHand)
            .help(selectedPanel == .files ? "Refresh files" : "Refresh changes")
            .accessibilityLabel(selectedPanel == .files ? "Refresh files" : "Refresh changes")
            .accessibilityValue(isRefreshActive ? "Refreshing" : "")
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private func tabButton(_ panel: RightSidebarPanel) -> some View {
        let isSelected = selectedPanel == panel

        return Button {
            selectedPanel = panel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: panel.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                Text(panel.title)
                    .font(.system(size: 14, weight: .semibold))

                if panel == .changes, let count = changesCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule()
                                .fill(Color.primary.opacity(isSelected ? 0.11 : 0.07))
                        }
                }
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(isSelected ? Color.primary.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(panel.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isRefreshActive: Bool {
        switch selectedPanel {
        case .files:
            return filesViewModel.isRefreshing
        case .changes:
            return gitStatusViewModel.isRefreshing
        }
    }

    private var filesRequest: WorkspaceFileTreeRequest? {
        guard let workspace = workspaceManager.selectedWorkspace else { return nil }
        return WorkspaceFileTreeRequest(
            workspaceId: workspace.id,
            rootPath: workspace.currentDirectory
        )
    }

    private var changesCount: Int? {
        guard case .loaded(let summary) = gitStatusViewModel.state else { return nil }
        return summary.totalFileCount
    }

    private func refreshSelectedPanel() async {
        switch selectedPanel {
        case .files:
            await refreshFiles()
        case .changes:
            await refreshChanges()
        }
    }

    private func refreshFiles() async {
        guard let filesRequest else {
            filesViewModel.reset()
            return
        }
        await filesViewModel.refresh(request: filesRequest)
    }

    private func refreshChanges() async {
        guard let workspace = workspaceManager.selectedWorkspace else { return }
        let context = gitStatusContext(
            workspace: workspace,
            project: workspaceManager.project(for: workspace.id)
        )
        await gitStatusViewModel.refresh(workspaceId: workspace.id, context: context)
    }
}

struct WorkspaceFileTreeEntry: Equatable, Sendable {
    let path: String
    let isDirectory: Bool
}

struct WorkspaceFileTreeRequest: Hashable, Sendable {
    let workspaceId: UUID
    let rootPath: String

    init(workspaceId: UUID, rootPath: String) {
        self.workspaceId = workspaceId
        self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    }
}

struct WorkspaceFileTreeNode: Identifiable, Equatable, Sendable {
    enum Content: Equatable, Sendable {
        case directory(children: [WorkspaceFileTreeNode])
        case file
    }

    let id: String
    let name: String
    let path: String
    let content: Content

    var children: [WorkspaceFileTreeNode] {
        guard case .directory(let children) = content else { return [] }
        return children
    }

    var idPrefix: String {
        switch content {
        case .directory:
            return "directory"
        case .file:
            return "file"
        }
    }

    func replacingChildren(_ children: [WorkspaceFileTreeNode]) -> WorkspaceFileTreeNode {
        guard case .directory = content else { return self }
        return WorkspaceFileTreeNode(
            id: id,
            name: name,
            path: path,
            content: .directory(children: children)
        )
    }
}

struct WorkspaceFileTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case directory(WorkspaceFileTreeNode)
        case file(WorkspaceFileTreeNode)
    }

    let id: String
    let name: String
    let depth: Int
    let content: Content
}

struct WorkspaceFileTreeSnapshot: Equatable, Sendable {
    static let displayedEntryLimit = 2_500

    let request: WorkspaceFileTreeRequest?
    let rootPath: String
    let nodes: [WorkspaceFileTreeNode]
    let fileCount: Int
    let directoryCount: Int
    let totalEntryCount: Int
    let omittedEntryCount: Int
    let isCapped: Bool
    let loadedDirectoryPaths: Set<String>

    init(
        request: WorkspaceFileTreeRequest? = nil,
        rootPath: String,
        nodes: [WorkspaceFileTreeNode],
        fileCount: Int,
        directoryCount: Int,
        totalEntryCount: Int? = nil,
        omittedEntryCount: Int = 0,
        isCapped: Bool,
        loadedDirectoryPaths: Set<String>
    ) {
        self.request = request
        self.rootPath = rootPath
        self.nodes = nodes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.totalEntryCount = totalEntryCount ?? fileCount + directoryCount + omittedEntryCount
        self.omittedEntryCount = omittedEntryCount
        self.isCapped = isCapped
        self.loadedDirectoryPaths = loadedDirectoryPaths
    }

    var displayedEntryCount: Int { fileCount + directoryCount }
}

struct WorkspaceFileTreeDirectorySnapshot: Equatable, Sendable {
    let rootPath: String
    let directoryPath: String
    let nodes: [WorkspaceFileTreeNode]
    let totalEntryCount: Int
    let omittedEntryCount: Int
    let isCapped: Bool

    init(
        rootPath: String,
        directoryPath: String,
        nodes: [WorkspaceFileTreeNode],
        totalEntryCount: Int? = nil,
        omittedEntryCount: Int = 0,
        isCapped: Bool
    ) {
        let counts = WorkspaceFileTree.countEntries(nodes: nodes)
        self.rootPath = rootPath
        self.directoryPath = directoryPath
        self.nodes = nodes
        self.totalEntryCount = totalEntryCount ?? counts.files + counts.directories + omittedEntryCount
        self.omittedEntryCount = omittedEntryCount
        self.isCapped = isCapped
    }
}

struct WorkspaceFileTreeDirectoryError: Equatable, Sendable {
    let path: String
    let message: String
}

enum WorkspaceFileTreeLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(WorkspaceFileTreeSnapshot)
    case missingDirectory(path: String)
    case error(path: String, message: String)
}

enum WorkspaceFileTreeDirectoryLoadState: Equatable, Sendable {
    case loaded(WorkspaceFileTreeDirectorySnapshot)
    case missingDirectory(path: String)
    case error(path: String, message: String)
}

enum WorkspaceFileOperationError: LocalizedError {
    case invalidPath
    case fileNotFound
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "The file path is outside the workspace."
        case .fileNotFound:
            return "The item does not exist."
        case .invalidName:
            return "Enter a valid file name."
        }
    }
}

@MainActor
protocol WorkspaceFileOperating: AnyObject {
    func copyFile(rootPath: String, path: String) throws
    func deleteFile(rootPath: String, path: String) async throws
    func renameFile(rootPath: String, path: String, newName: String) async throws -> String
}

@MainActor
final class FileManagerWorkspaceFileOperator: WorkspaceFileOperating {
    func copyFile(rootPath: String, path: String) throws {
        let url = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.path, forType: .string)
    }

    func deleteFile(rootPath: String, path: String) async throws {
        let url = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: url)
        }.value
    }

    func renameFile(rootPath: String, path: String, newName: String) async throws -> String {
        let sourceURL = try Self.resolvedItemURL(rootPath: rootPath, path: path)
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              trimmedName != ".",
              trimmedName != ".."
        else {
            throw WorkspaceFileOperationError.invalidName
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        let newRelativePath = parentPath.isEmpty || parentPath == "."
            ? trimmedName
            : "\(parentPath)/\(trimmedName)"
        let destinationURL = try Self.resolvedDestinationURL(
            rootPath: rootPath,
            path: newRelativePath
        )

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }.value
        return newRelativePath
    }

    private static func resolvedItemURL(rootPath: String, path: String) throws -> URL {
        let url = try resolvedDestinationURL(rootPath: rootPath, path: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceFileOperationError.fileNotFound
        }
        return url
    }

    private static func resolvedDestinationURL(rootPath: String, path: String) throws -> URL {
        guard !path.isEmpty else { throw WorkspaceFileOperationError.invalidPath }
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let targetURL = rootURL
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard targetURL.path.hasPrefix(rootPathWithSlash) else {
            throw WorkspaceFileOperationError.invalidPath
        }
        return targetURL
    }
}

@MainActor
protocol WorkspaceFileOperationPrompting: AnyObject {
    func confirmDelete(path: String) -> Bool
    func promptRename(currentName: String) -> String?
    func showFailure(title: String, message: String)
}

@MainActor
final class AlertWorkspaceFileOperationPrompter: WorkspaceFileOperationPrompting {
    func confirmDelete(path: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete Item?"
        alert.informativeText = "This will permanently delete \(path) from disk."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func promptRename(currentName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Rename Item"
        alert.informativeText = "Enter a new file name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: currentName)
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let renamed = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return renamed.isEmpty ? nil : renamed
    }

    func showFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum WorkspaceFileTree {
    static func makeNodes(entries: [WorkspaceFileTreeEntry]) -> [WorkspaceFileTreeNode] {
        var root = DirectoryBuilder()
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            if entry.isDirectory {
                root.insertDirectory(components: components[...])
            } else {
                root.insertFile(components: components[...])
            }
        }
        return root.nodes(prefix: "")
    }

    static func makeImmediateNodes(entries: [WorkspaceFileTreeEntry]) -> [WorkspaceFileTreeNode] {
        let directoryNodes = entries
            .filter(\.isDirectory)
            .sorted { localizedLessThan($0.path, $1.path) }
            .map { entry in
                WorkspaceFileTreeNode(
                    id: "directory:\(entry.path)",
                    name: displayName(for: entry.path),
                    path: entry.path,
                    content: .directory(children: [])
                )
            }
        let fileNodes = entries
            .filter { !$0.isDirectory }
            .sorted { localizedLessThan($0.path, $1.path) }
            .map { entry in
                WorkspaceFileTreeNode(
                    id: "file:\(entry.path)",
                    name: displayName(for: entry.path),
                    path: entry.path,
                    content: .file
                )
            }

        return directoryNodes + fileNodes
    }

    static func visibleRows(
        nodes: [WorkspaceFileTreeNode],
        expandedDirectoryIds: Set<String>
    ) -> [WorkspaceFileTreeRow] {
        rows(nodes: nodes, depth: 0, expandedDirectoryIds: expandedDirectoryIds)
    }

    static func replacingChildren(
        in nodes: [WorkspaceFileTreeNode],
        directoryPath: String,
        with children: [WorkspaceFileTreeNode]
    ) -> [WorkspaceFileTreeNode] {
        nodes.map { node in
            guard case .directory(let existingChildren) = node.content else { return node }
            if node.path == directoryPath {
                return node.replacingChildren(children)
            }
            return node.replacingChildren(
                replacingChildren(in: existingChildren, directoryPath: directoryPath, with: children)
            )
        }
    }

    static func countEntries(nodes: [WorkspaceFileTreeNode]) -> (files: Int, directories: Int) {
        nodes.reduce(into: (files: 0, directories: 0)) { partial, node in
            switch node.content {
            case .directory(let children):
                partial.directories += 1
                let childCounts = countEntries(nodes: children)
                partial.files += childCounts.files
                partial.directories += childCounts.directories
            case .file:
                partial.files += 1
            }
        }
    }

    static func containsDirectory(path: String, in nodes: [WorkspaceFileTreeNode]) -> Bool {
        nodes.contains { node in
            guard case .directory(let children) = node.content else { return false }
            return node.path == path || containsDirectory(path: path, in: children)
        }
    }

    private static func rows(
        nodes: [WorkspaceFileTreeNode],
        depth: Int,
        expandedDirectoryIds: Set<String>
    ) -> [WorkspaceFileTreeRow] {
        nodes.flatMap { node in
            switch node.content {
            case .directory(let children):
                let directoryRow = WorkspaceFileTreeRow(
                    id: node.id,
                    name: node.name,
                    depth: depth,
                    content: .directory(node)
                )
                guard expandedDirectoryIds.contains(node.id) else { return [directoryRow] }
                return [directoryRow] + rows(
                    nodes: children,
                    depth: depth + 1,
                    expandedDirectoryIds: expandedDirectoryIds
                )
            case .file:
                return [
                    WorkspaceFileTreeRow(
                        id: node.id,
                        name: node.name,
                        depth: depth,
                        content: .file(node)
                    )
                ]
            }
        }
    }

    private static func displayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func localizedLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private struct DirectoryBuilder {
        var directories: [String: DirectoryBuilder] = [:]
        var files: Set<String> = []

        mutating func insertDirectory(components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                if directories[component] == nil {
                    directories[component] = DirectoryBuilder()
                }
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insertDirectory(components: components.dropFirst())
            directories[component] = directory
        }

        mutating func insertFile(components: ArraySlice<String>) {
            guard let component = components.first else { return }
            guard components.count > 1 else {
                files.insert(component)
                return
            }

            var directory = directories[component, default: DirectoryBuilder()]
            directory.insertFile(components: components.dropFirst())
            directories[component] = directory
        }

        func nodes(prefix: String) -> [WorkspaceFileTreeNode] {
            let directoryNodes = directories.keys.sorted(by: localizedLessThan).map { directoryName in
                let path = prefix.isEmpty ? directoryName : "\(prefix)/\(directoryName)"
                return WorkspaceFileTreeNode(
                    id: "directory:\(path)",
                    name: directoryName,
                    path: path,
                    content: .directory(
                        children: directories[directoryName]!.nodes(prefix: path)
                    )
                )
            }

            let fileNodes = files.sorted(by: localizedLessThan).map { fileName in
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                return WorkspaceFileTreeNode(
                    id: "file:\(path)",
                    name: fileName,
                    path: path,
                    content: .file
                )
            }

            return directoryNodes + fileNodes
        }

        private func localizedLessThan(_ lhs: String, _ rhs: String) -> Bool {
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}

protocol WorkspaceFileTreeProviding: Sendable {
    func loadTree(rootPath: String) async -> WorkspaceFileTreeLoadState
    func loadChildren(rootPath: String, directoryPath: String) async -> WorkspaceFileTreeDirectoryLoadState
}

struct FileManagerWorkspaceFileTreeProvider: WorkspaceFileTreeProviding {
    func loadTree(rootPath: String) async -> WorkspaceFileTreeLoadState {
        let task = Task.detached(priority: .userInitiated) {
            WorkspaceFileTreeLoader.load(rootPath: rootPath)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadChildren(rootPath: String, directoryPath: String) async -> WorkspaceFileTreeDirectoryLoadState {
        let task = Task.detached(priority: .userInitiated) {
            WorkspaceFileTreeLoader.loadChildren(rootPath: rootPath, directoryPath: directoryPath)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private enum WorkspaceFileTreeLoader {
    static func load(rootPath: String) -> WorkspaceFileTreeLoadState {
        switch loadDirectory(rootPath: rootPath, directoryPath: "") {
        case .loaded(let directory):
            let counts = WorkspaceFileTree.countEntries(nodes: directory.nodes)
            return .loaded(WorkspaceFileTreeSnapshot(
                rootPath: directory.rootPath,
                nodes: directory.nodes,
                fileCount: counts.files,
                directoryCount: counts.directories,
                totalEntryCount: directory.totalEntryCount,
                omittedEntryCount: directory.omittedEntryCount,
                isCapped: directory.isCapped,
                loadedDirectoryPaths: [""]
            ))
        case .missingDirectory(let path):
            return .missingDirectory(path: path)
        case .error(let path, let message):
            return .error(path: path, message: message)
        }
    }

    static func loadChildren(rootPath: String, directoryPath: String) -> WorkspaceFileTreeDirectoryLoadState {
        loadDirectory(rootPath: rootPath, directoryPath: directoryPath)
    }

    private static func loadDirectory(
        rootPath: String,
        directoryPath: String
    ) -> WorkspaceFileTreeDirectoryLoadState {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let directoryURL = directoryPath.isEmpty
            ? rootURL
            : rootURL.appendingPathComponent(directoryPath, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)

        if Task.isCancelled {
            return .error(path: directoryURL.path, message: "Loading cancelled")
        }

        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .missingDirectory(path: rootURL.path)
        }

        let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : "\(rootURL.path)/"
        guard directoryURL.path == rootURL.path || directoryURL.path.hasPrefix(rootPathWithSlash) else {
            return .error(path: directoryURL.path, message: "Refusing to read outside the workspace root")
        }

        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return .missingDirectory(path: directoryURL.path)
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ]

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants]
            )
            var entries: [WorkspaceFileTreeEntry] = []
            var totalEntryCount = 0

            for url in urls {
                if Task.isCancelled {
                    return .error(path: directoryURL.path, message: "Loading cancelled")
                }

                let values = try? url.resourceValues(forKeys: Set(resourceKeys))
                let name = url.lastPathComponent
                let isEntryDirectory = values?.isDirectory == true && values?.isSymbolicLink != true

                if name == ".git" {
                    continue
                }

                let entryURL = url.standardizedFileURL
                guard entryURL.path.hasPrefix(rootPathWithSlash) else { continue }
                let relativePath = String(entryURL.path.dropFirst(rootPathWithSlash.count))
                guard !relativePath.isEmpty else { continue }

                totalEntryCount += 1
                if entries.count < WorkspaceFileTreeSnapshot.displayedEntryLimit {
                    entries.append(WorkspaceFileTreeEntry(
                        path: relativePath,
                        isDirectory: isEntryDirectory
                    ))
                }
            }

            let omittedEntryCount = max(0, totalEntryCount - entries.count)

            return .loaded(WorkspaceFileTreeDirectorySnapshot(
                rootPath: rootURL.path,
                directoryPath: directoryPath,
                nodes: WorkspaceFileTree.makeImmediateNodes(entries: entries),
                totalEntryCount: totalEntryCount,
                omittedEntryCount: omittedEntryCount,
                isCapped: omittedEntryCount > 0
            ))
        } catch {
            return .error(path: directoryURL.path, message: error.localizedDescription)
        }
    }
}

@MainActor
final class WorkspaceFilesViewModel: ObservableObject {
    @Published private(set) var state: WorkspaceFileTreeLoadState = .idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadingDirectoryPaths: Set<String> = []
    @Published private(set) var directoryErrors: [String: WorkspaceFileTreeDirectoryError] = [:]

    private let provider: any WorkspaceFileTreeProviding
    private let fileOperator: any WorkspaceFileOperating
    private let filePrompter: any WorkspaceFileOperationPrompting
    private var activeRequest: WorkspaceFileTreeRequest?
    private var requestGeneration: UInt64 = 0
    private var directoryLoadGenerations: [String: UInt64] = [:]

    init(
        provider: any WorkspaceFileTreeProviding = FileManagerWorkspaceFileTreeProvider(),
        fileOperator: any WorkspaceFileOperating = FileManagerWorkspaceFileOperator(),
        filePrompter: any WorkspaceFileOperationPrompting = AlertWorkspaceFileOperationPrompter()
    ) {
        self.provider = provider
        self.fileOperator = fileOperator
        self.filePrompter = filePrompter
    }

    func reset() {
        activate(request: nil)
    }

    func activate(request: WorkspaceFileTreeRequest?) {
        guard activeRequest != request else { return }
        invalidateRequests()
        activeRequest = request
        state = request == nil ? .idle : .loading
        isRefreshing = false
        loadingDirectoryPaths = []
        directoryLoadGenerations = [:]
        directoryErrors = [:]
    }

    func refresh(request: WorkspaceFileTreeRequest) async {
        guard !(isRefreshing && activeRequest == request) else { return }

        let directoryPathsToReload = reloadableDirectoryPaths(for: request)
        invalidateRequests()
        let generation = requestGeneration
        let previousRequest = activeRequest
        activeRequest = request
        isRefreshing = true
        loadingDirectoryPaths = []
        directoryLoadGenerations = [:]
        if case .loaded(let snapshot) = state, snapshot.request == request, previousRequest == request {
            // Keep the previous tree visible during quick refreshes.
        } else {
            state = .loading
        }
        defer {
            if requestGeneration == generation, activeRequest == request {
                isRefreshing = false
            }
        }

        let result = await provider.loadTree(rootPath: request.rootPath)
        guard !Task.isCancelled,
              requestGeneration == generation,
              activeRequest == request
        else {
            return
        }

        switch result {
        case .loaded(let snapshot):
            guard snapshot.rootPath == request.rootPath else {
                state = .error(path: snapshot.rootPath, message: "Workspace root changed while loading")
                return
            }
            var rebuiltSnapshot = WorkspaceFileTreeSnapshot(
                request: request,
                rootPath: snapshot.rootPath,
                nodes: snapshot.nodes,
                fileCount: snapshot.fileCount,
                directoryCount: snapshot.directoryCount,
                totalEntryCount: snapshot.totalEntryCount,
                omittedEntryCount: snapshot.omittedEntryCount,
                isCapped: snapshot.isCapped,
                loadedDirectoryPaths: snapshot.loadedDirectoryPaths
            )
            var refreshedDirectoryErrors: [String: WorkspaceFileTreeDirectoryError] = [:]

            for directoryPath in directoryPathsToReload {
                let directoryResult = await provider.loadChildren(
                    rootPath: request.rootPath,
                    directoryPath: directoryPath
                )
                guard !Task.isCancelled,
                      requestGeneration == generation,
                      activeRequest == request
                else {
                    return
                }

                switch directoryResult {
                case .loaded(let directory):
                    if let merged = mergedSnapshot(
                        directory: directory,
                        into: rebuiltSnapshot,
                        request: request
                    ) {
                        rebuiltSnapshot = merged
                    }
                case .missingDirectory:
                    break
                case .error(let path, let message):
                    if WorkspaceFileTree.containsDirectory(
                        path: directoryPath,
                        in: rebuiltSnapshot.nodes
                    ) {
                        refreshedDirectoryErrors[directoryPath] = WorkspaceFileTreeDirectoryError(
                            path: path,
                            message: message
                        )
                    }
                }
            }

            state = .loaded(rebuiltSnapshot)
            directoryErrors = refreshedDirectoryErrors
        case .missingDirectory(let path):
            state = .missingDirectory(path: path)
        case .error(let path, let message):
            state = .error(path: path, message: message)
        case .idle, .loading:
            state = result
        }
    }

    func loadChildren(request: WorkspaceFileTreeRequest, directoryPath: String) async {
        guard case .loaded(let snapshot) = state,
              snapshot.request == request,
              activeRequest == request,
              !snapshot.loadedDirectoryPaths.contains(directoryPath),
              !loadingDirectoryPaths.contains(directoryPath)
        else {
            return
        }

        let generation = requestGeneration
        loadingDirectoryPaths.insert(directoryPath)
        directoryLoadGenerations[directoryPath] = generation
        defer { finishDirectoryLoad(directoryPath: directoryPath, generation: generation) }

        let result = await provider.loadChildren(
            rootPath: request.rootPath,
            directoryPath: directoryPath
        )
        guard !Task.isCancelled,
              requestGeneration == generation,
              activeRequest == request
        else {
            return
        }

        switch result {
        case .loaded(let directory):
            guard case .loaded(let current) = state,
                  current.request == request,
                  current.rootPath == directory.rootPath
            else {
                return
            }

            guard let merged = mergedSnapshot(
                directory: directory,
                into: current,
                request: request
            ) else { return }
            state = .loaded(merged)
            directoryErrors[directoryPath] = nil
        case .missingDirectory(let path):
            directoryErrors[directoryPath] = WorkspaceFileTreeDirectoryError(
                path: path,
                message: "Directory not found"
            )
        case .error(let path, let message):
            directoryErrors[directoryPath] = WorkspaceFileTreeDirectoryError(
                path: path,
                message: message
            )
        }
    }

    func copyFile(rootPath: String, path: String) {
        do {
            try fileOperator.copyFile(rootPath: rootPath, path: path)
        } catch {
            filePrompter.showFailure(
                title: "Copy Failed",
                message: error.localizedDescription
            )
        }
    }

    func deleteFileWithConfirmation(request: WorkspaceFileTreeRequest, path: String) async -> Bool {
        guard filePrompter.confirmDelete(path: path) else { return false }
        do {
            try await fileOperator.deleteFile(rootPath: request.rootPath, path: path)
            guard activeRequest == request else { return true }
            await refresh(request: request)
            return true
        } catch {
            filePrompter.showFailure(
                title: "Delete Failed",
                message: error.localizedDescription
            )
            return false
        }
    }

    func renameFileWithPrompt(request: WorkspaceFileTreeRequest, path: String) async -> String? {
        let currentName = (path as NSString).lastPathComponent
        guard let newName = filePrompter.promptRename(currentName: currentName) else { return nil }
        do {
            let newPath = try await fileOperator.renameFile(
                rootPath: request.rootPath,
                path: path,
                newName: newName
            )
            guard activeRequest == request else { return newPath }
            await refresh(request: request)
            return newPath
        } catch {
            filePrompter.showFailure(
                title: "Rename Failed",
                message: error.localizedDescription
            )
            return nil
        }
    }

    func isCurrent(_ request: WorkspaceFileTreeRequest) -> Bool {
        activeRequest == request
    }

    private func invalidateRequests() {
        requestGeneration &+= 1
    }

    private func reloadableDirectoryPaths(for request: WorkspaceFileTreeRequest) -> [String] {
        guard case .loaded(let snapshot) = state,
              snapshot.request == request,
              activeRequest == request
        else {
            return []
        }

        return snapshot.loadedDirectoryPaths
            .union(loadingDirectoryPaths)
            .union(directoryErrors.keys)
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                let lhsDepth = lhs.split(separator: "/").count
                let rhsDepth = rhs.split(separator: "/").count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
    }

    private func mergedSnapshot(
        directory: WorkspaceFileTreeDirectorySnapshot,
        into current: WorkspaceFileTreeSnapshot,
        request: WorkspaceFileTreeRequest
    ) -> WorkspaceFileTreeSnapshot? {
        guard current.request == request,
              current.rootPath == directory.rootPath,
              WorkspaceFileTree.containsDirectory(
                  path: directory.directoryPath,
                  in: current.nodes
              )
        else {
            return nil
        }

        let remainingBudget = max(
            0,
            WorkspaceFileTreeSnapshot.displayedEntryLimit - current.displayedEntryCount
        )
        let displayedNodes = Array(directory.nodes.prefix(remainingBudget))
        let displayedDirectoryCounts = WorkspaceFileTree.countEntries(nodes: displayedNodes)
        let displayedDirectoryEntryCount = displayedDirectoryCounts.files
            + displayedDirectoryCounts.directories
        let omittedDirectoryEntryCount = max(
            directory.omittedEntryCount,
            directory.totalEntryCount - displayedDirectoryEntryCount
        )
        let updatedNodes = WorkspaceFileTree.replacingChildren(
            in: current.nodes,
            directoryPath: directory.directoryPath,
            with: displayedNodes
        )
        let counts = WorkspaceFileTree.countEntries(nodes: updatedNodes)
        let omittedEntryCount = current.omittedEntryCount + omittedDirectoryEntryCount
        return WorkspaceFileTreeSnapshot(
            request: request,
            rootPath: current.rootPath,
            nodes: updatedNodes,
            fileCount: counts.files,
            directoryCount: counts.directories,
            totalEntryCount: current.totalEntryCount + directory.totalEntryCount,
            omittedEntryCount: omittedEntryCount,
            isCapped: omittedEntryCount > 0,
            loadedDirectoryPaths: current.loadedDirectoryPaths.union([directory.directoryPath])
        )
    }

    private func finishDirectoryLoad(directoryPath: String, generation: UInt64) {
        guard directoryLoadGenerations[directoryPath] == generation else { return }
        directoryLoadGenerations[directoryPath] = nil
        loadingDirectoryPaths.remove(directoryPath)
    }
}

struct WorkspaceFilesView: View {
    @ObservedObject var viewModel: WorkspaceFilesViewModel
    let workspaceId: UUID?
    let rootPath: String?
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var autoRefreshController = WorkspaceFilesAutoRefreshController()
    @State private var expandedDirectoryIds: Set<String> = []
    @State private var selectedItemId: String?
    @State private var selectedItemPath: String?
    @State private var hoveredItemId: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(request)
            .task(id: request) {
                expandedDirectoryIds = []
                selectedItemId = nil
                selectedItemPath = nil
                hoveredItemId = nil
                guard let request else {
                    autoRefreshController.stop()
                    viewModel.reset()
                    return
                }
                autoRefreshController.start(rootPath: request.rootPath) {
                    await viewModel.refresh(request: request)
                }
                await viewModel.refresh(request: request)
            }
            .onDisappear {
                autoRefreshController.stop()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            emptyMessage("Select a workspace", systemImage: "folder")
        case .loading:
            loadingMessage
        case .loaded(let snapshot):
            if snapshot.request == request {
                fileTreeContent(snapshot)
            } else {
                loadingMessage
            }
        case .missingDirectory(let path):
            fileTreeError(title: "Directory not found", path: path, message: nil)
        case .error(let path, let message):
            fileTreeError(title: "Files unavailable", path: path, message: message)
        }
    }

    private var request: WorkspaceFileTreeRequest? {
        guard let workspaceId, let rootPath else { return nil }
        return WorkspaceFileTreeRequest(workspaceId: workspaceId, rootPath: rootPath)
    }

    private var loadingMessage: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading files...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private func fileTreeContent(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileTreeRootBar(snapshot)

            if snapshot.isCapped {
                Text(
                    "Showing \(snapshot.displayedEntryCount) of \(snapshot.totalEntryCount) loaded entries "
                        + "(\(snapshot.omittedEntryCount) omitted)"
                )
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if snapshot.nodes.isEmpty {
                emptyMessage("Directory empty", systemImage: "folder")
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(
                            WorkspaceFileTree.visibleRows(
                                nodes: snapshot.nodes,
                                expandedDirectoryIds: expandedDirectoryIds
                            )
                        ) { row in
                            switch row.content {
                            case .directory(let directory):
                                VStack(spacing: 0) {
                                    workspaceDirectoryRow(
                                        directory,
                                        depth: row.depth,
                                        rootPath: snapshot.rootPath
                                    )
                                    if expandedDirectoryIds.contains(directory.id),
                                       let error = viewModel.directoryErrors[directory.path] {
                                        directoryLoadError(
                                            error,
                                            directory: directory,
                                            depth: row.depth,
                                            rootPath: snapshot.rootPath
                                        )
                                    }
                                }
                            case .file(let file):
                                workspaceFileRow(
                                    file,
                                    depth: row.depth,
                                    rootPath: snapshot.rootPath
                                )
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func fileTreeRootBar(_ snapshot: WorkspaceFileTreeSnapshot) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
            Text((snapshot.rootPath as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("\(snapshot.totalEntryCount) \(snapshot.totalEntryCount == 1 ? "item" : "items")")
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
        .help(snapshot.rootPath)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private func workspaceDirectoryRow(
        _ directory: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isExpanded = expandedDirectoryIds.contains(directory.id)
        let isLoading = viewModel.loadingDirectoryPaths.contains(directory.path)
        let isSelected = selectedItemId == directory.id
        let isHovered = hoveredItemId == directory.id

        return Button {
            selectDirectory(directory)
            toggleWorkspaceDirectory(directory, rootPath: rootPath)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 12)
                ZStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isSelected ? .accentColor : .secondary)
                    }
                }
                .frame(width: 14)
                Text(directory.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth))
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected
                    ? Color.accentColor.opacity(0.16)
                    : (isHovered ? ChromeColors.hoveredTabFill : Color.clear))
        }
        .onHover { isHovering in
            if isHovering {
                hoveredItemId = directory.id
            } else if hoveredItemId == directory.id {
                hoveredItemId = nil
            }
        }
        .cursor(.pointingHand)
        .contextMenu {
            Button("Open Folder") {
                openWorkspaceDirectory(directory, rootPath: rootPath)
            }
            Button("Copy Folder") {
                copyWorkspaceItem(directory, rootPath: rootPath)
            }
            Button("Delete Folder", role: .destructive) {
                guard let initiatingRequest = request else { return }
                Task {
                    await deleteWorkspaceItem(
                        directory,
                        rootPath: rootPath,
                        initiatingRequest: initiatingRequest
                    )
                }
            }
            Button("Rename Folder") {
                guard let initiatingRequest = request else { return }
                Task {
                    await renameWorkspaceItem(
                        directory,
                        rootPath: rootPath,
                        initiatingRequest: initiatingRequest
                    )
                }
            }
        }
        .help(directory.path)
        .accessibilityLabel("\(directory.name) folder")
        .accessibilityValue(
            [isSelected ? "Selected" : nil, isExpanded ? "Expanded" : "Collapsed"]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func workspaceFileRow(
        _ file: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isSelected = selectedItemId == file.id
        let isHovered = hoveredItemId == file.id

        return Button {
            selectFile(file)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 14)
                Text(file.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth) + 19)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected
                    ? Color.accentColor.opacity(0.16)
                    : (isHovered ? ChromeColors.hoveredTabFill : Color.clear))
        }
        .onHover { isHovering in
            if isHovering {
                hoveredItemId = file.id
            } else if hoveredItemId == file.id {
                hoveredItemId = nil
            }
        }
        .cursor(.pointingHand)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            openWorkspaceFile(file, rootPath: rootPath)
        })
        .contextMenu {
            Button("Open File") {
                openWorkspaceFile(file, rootPath: rootPath)
            }
            Button("Copy File") {
                copyWorkspaceItem(file, rootPath: rootPath)
            }
            Button("Delete File", role: .destructive) {
                guard let initiatingRequest = request else { return }
                Task {
                    await deleteWorkspaceItem(
                        file,
                        rootPath: rootPath,
                        initiatingRequest: initiatingRequest
                    )
                }
            }
            Button("Rename File") {
                guard let initiatingRequest = request else { return }
                Task {
                    await renameWorkspaceItem(
                        file,
                        rootPath: rootPath,
                        initiatingRequest: initiatingRequest
                    )
                }
            }
        }
        .help(file.path)
        .accessibilityLabel(file.path)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func workspaceTreeRowLeadingPadding(depth: Int) -> CGFloat {
        12 + CGFloat(depth * 16)
    }

    private func selectWorkspaceItem(_ item: WorkspaceFileTreeNode) {
        selectedItemId = item.id
        selectedItemPath = item.path
    }

    private func selectDirectory(_ directory: WorkspaceFileTreeNode) {
        selectWorkspaceItem(directory)
    }

    private func selectFile(_ file: WorkspaceFileTreeNode) {
        selectWorkspaceItem(file)
    }

    private func toggleWorkspaceDirectory(_ directory: WorkspaceFileTreeNode, rootPath: String) {
        if expandedDirectoryIds.contains(directory.id) {
            expandedDirectoryIds.remove(directory.id)
        } else {
            openWorkspaceDirectory(directory, rootPath: rootPath)
        }
    }

    private func openWorkspaceDirectory(_ directory: WorkspaceFileTreeNode, rootPath: String) {
        guard let initiatingRequest = request,
              initiatingRequest.rootPath == rootPath
        else {
            return
        }
        selectDirectory(directory)
        guard !expandedDirectoryIds.contains(directory.id) else { return }
        expandedDirectoryIds.insert(directory.id)
        Task {
            await viewModel.loadChildren(request: initiatingRequest, directoryPath: directory.path)
        }
    }

    private func openWorkspaceFile(_ file: WorkspaceFileTreeNode, rootPath: String) {
        guard let initiatingRequest = request,
              initiatingRequest.rootPath == rootPath
        else {
            return
        }
        selectFile(file)
        guard let sourceWorkspace = workspaceManager.workspaces.first(where: {
            $0.id == initiatingRequest.workspaceId
        }) else {
            return
        }
        sourceWorkspace.openFilePanel(
            rootPath: rootPath,
            relativePath: file.path
        )
    }

    private func copyWorkspaceItem(_ item: WorkspaceFileTreeNode, rootPath: String) {
        selectWorkspaceItem(item)
        viewModel.copyFile(rootPath: rootPath, path: item.path)
    }

    private func deleteWorkspaceItem(
        _ item: WorkspaceFileTreeNode,
        rootPath: String,
        initiatingRequest: WorkspaceFileTreeRequest
    ) async {
        guard initiatingRequest.rootPath == rootPath else { return }
        selectWorkspaceItem(item)
        let deleted = await viewModel.deleteFileWithConfirmation(
            request: initiatingRequest,
            path: item.path
        )
        guard deleted,
              request == initiatingRequest,
              viewModel.isCurrent(initiatingRequest)
        else {
            return
        }
        if selectedItemPath == item.path {
            selectedItemId = nil
            selectedItemPath = nil
        }
        expandedDirectoryIds = []
    }

    private func renameWorkspaceItem(
        _ item: WorkspaceFileTreeNode,
        rootPath: String,
        initiatingRequest: WorkspaceFileTreeRequest
    ) async {
        guard initiatingRequest.rootPath == rootPath else { return }
        selectWorkspaceItem(item)
        guard let newPath = await viewModel.renameFileWithPrompt(
            request: initiatingRequest,
            path: item.path
        ) else {
            return
        }
        if case .file = item.content,
           let sourceWorkspace = workspaceManager.workspaces.first(where: {
               $0.id == initiatingRequest.workspaceId
           }) {
            sourceWorkspace.updateOpenFilePanel(
                rootPath: rootPath,
                oldPath: item.path,
                newPath: newPath
            )
        }
        guard request == initiatingRequest,
              viewModel.isCurrent(initiatingRequest)
        else {
            return
        }
        selectedItemId = "\(item.idPrefix):\(newPath)"
        selectedItemPath = newPath
        expandedDirectoryIds = []
    }

    private func fileTreeError(title: String, path: String, message: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text(path)
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
            Button("Retry Files") {
                Task { await refresh() }
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isRefreshing || request == nil)
            .cursor(viewModel.isRefreshing || request == nil ? .arrow : .pointingHand)
            .help("Retry loading files")
            .accessibilityValue(viewModel.isRefreshing ? "Loading" : "")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func directoryLoadError(
        _ error: WorkspaceFileTreeDirectoryError,
        directory: WorkspaceFileTreeNode,
        depth: Int,
        rootPath: String
    ) -> some View {
        let isLoading = viewModel.loadingDirectoryPaths.contains(directory.path)

        return HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            Text(error.message)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button("Retry Folder") {
                guard let initiatingRequest = request,
                      initiatingRequest.rootPath == rootPath
                else {
                    return
                }
                Task {
                    await viewModel.loadChildren(
                        request: initiatingRequest,
                        directoryPath: directory.path
                    )
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .cursor(isLoading ? .arrow : .pointingHand)
            .help("Retry loading \(directory.name)")
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.leading, workspaceTreeRowLeadingPadding(depth: depth + 1) + 19)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(error.path): \(error.message)")
        .accessibilityLabel("Could not load \(directory.name) folder")
        .accessibilityValue(error.message)
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
        guard let request else {
            viewModel.reset()
            return
        }
        await viewModel.refresh(request: request)
    }
}

@MainActor
func gitStatusContext(workspace: Workspace, project: Project?) -> GitStatusRootContext {
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
