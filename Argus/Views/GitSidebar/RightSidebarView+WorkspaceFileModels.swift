import AppKit
import Foundation

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
        let newRelativePath =
            parentPath.isEmpty || parentPath == "."
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
        let targetURL =
            rootURL
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
