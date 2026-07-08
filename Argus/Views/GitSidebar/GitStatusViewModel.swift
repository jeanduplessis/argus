import AppKit
import Foundation
import SwiftUI

protocol GitStatusPathCopying: AnyObject {
    func copyPath(_ path: String)
}

final class PasteboardGitStatusPathClipboard: GitStatusPathCopying {
    func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

protocol GitStatusFileOperationConfirming: AnyObject {
    @MainActor
    func confirm(operation: GitStatusFileOperation, paths: [String]) -> Bool

    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool
}

extension GitStatusFileOperationConfirming {
    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        confirm(operation: operation, paths: Array(repeating: "", count: pathCount))
    }
}

final class AlertGitStatusFileOperationConfirmer: GitStatusFileOperationConfirming {
    @MainActor
    func confirm(operation: GitStatusFileOperation, paths: [String]) -> Bool {
        confirm(operation: operation, pathCount: paths.count)
    }

    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        guard operation.requiresConfirmation else { return true }
        let alert = NSAlert()
        alert.messageText = operation.confirmationTitle
        alert.informativeText = operation.confirmationMessage(pathCount: pathCount)
        alert.alertStyle = .warning
        alert.addButton(withTitle: operation.confirmationButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor
final class GitStatusViewModel: ObservableObject {
    @Published private(set) var state: GitStatusLoadState = .idle
    @Published private(set) var stateWorkspaceId: UUID?
    @Published private(set) var isRefreshing = false

    private let service: any GitStatusProviding
    private let resolver: GitStatusRootResolver
    private let pathClipboard: any GitStatusPathCopying
    private let fileOperationConfirmer: any GitStatusFileOperationConfirming
    private let previewService: any GitPreviewProviding
    private let previewPresenter: any GitPreviewPresenting

    init(
        service: any GitStatusProviding = GitStatusService(),
        resolver: GitStatusRootResolver = GitStatusRootResolver(),
        pathClipboard: any GitStatusPathCopying = PasteboardGitStatusPathClipboard(),
        fileOperationConfirmer: any GitStatusFileOperationConfirming = AlertGitStatusFileOperationConfirmer(),
        previewService: any GitPreviewProviding = GitPreviewService(),
        previewPresenter: any GitPreviewPresenting = AppKitGitPreviewPresenter()
    ) {
        self.service = service
        self.resolver = resolver
        self.pathClipboard = pathClipboard
        self.fileOperationConfirmer = fileOperationConfirmer
        self.previewService = previewService
        self.previewPresenter = previewPresenter
    }

    func rootPath(for context: GitStatusRootContext) -> String {
        resolver.root(for: context)
    }

    func refresh(context: GitStatusRootContext) async {
        await refresh(workspaceId: nil, context: context)
    }

    func refresh(workspaceId: UUID?, context: GitStatusRootContext) async {
        let isSameWorkspace = stateWorkspaceId == workspaceId
        stateWorkspaceId = workspaceId
        beginRefresh(preservingLoadedState: isSameWorkspace)
        defer { isRefreshing = false }
        let rootPath = resolver.root(for: context)
        state = await service.status(rootPath: rootPath)
    }

    func titlebarGitContext(for workspaceId: UUID) -> TitlebarGitContext? {
        guard stateWorkspaceId == workspaceId else { return nil }
        return TitlebarGitContextFormatter.context(from: state)
    }

    func initializeRepository(context: GitStatusRootContext) async {
        beginRefresh()
        defer { isRefreshing = false }
        let rootPath = resolver.root(for: context)
        state = await service.initializeRepository(rootPath: rootPath)
    }

    func copyPath(_ path: String) {
        pathClipboard.copyPath(path)
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        context: GitStatusRootContext
    ) async {
        beginRefresh()
        defer { isRefreshing = false }
        let rootPath = resolver.root(for: context)
        state = await service.performFileOperation(operation, rootPath: rootPath, path: path)
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        context: GitStatusRootContext
    ) async {
        beginRefresh()
        defer { isRefreshing = false }
        let rootPath = resolver.root(for: context)
        state = await service.performBulkFileOperation(operation, rootPath: rootPath, paths: paths)
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        context: GitStatusRootContext
    ) async {
        beginRefresh()
        defer { isRefreshing = false }
        let rootPath = resolver.root(for: context)
        state = await service.performSectionFileOperation(operation, rootPath: rootPath, sectionKey: sectionKey)
    }

    private func beginRefresh(preservingLoadedState: Bool = true) {
        isRefreshing = true
        if preservingLoadedState, case .loaded = state { return }
        state = .loading
    }

    func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        context: GitStatusRootContext
    ) async {
        guard !operation.requiresConfirmation || fileOperationConfirmer.confirm(operation: operation, paths: paths) else {
            return
        }
        await performBulkFileOperation(operation, paths: paths, context: context)
    }

    func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        context: GitStatusRootContext
    ) async {
        guard !operation.requiresConfirmation || fileOperationConfirmer.confirm(operation: operation, pathCount: pathCount) else {
            return
        }
        await performSectionFileOperation(operation, sectionKey: sectionKey, context: context)
    }

    func showPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        context: GitStatusRootContext,
        parentWindow: NSWindow?
    ) async {
        let rootPath = resolver.root(for: context)
        let result = await previewService.preview(kind: kind, rootPath: rootPath, file: file)
        switch result {
        case .loaded(let preview):
            previewPresenter.show(preview: preview, parentWindow: parentWindow)
        case .failed(let kind, let path, let message):
            previewPresenter.showFailure(kind: kind, path: path, message: message, parentWindow: parentWindow)
        }
    }
}
