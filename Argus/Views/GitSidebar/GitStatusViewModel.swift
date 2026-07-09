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
        guard operation.requiresConfirmation else { return true }
        return runAlert(
            operation: operation,
            informativeText: operation.confirmationMessage(paths: paths)
        )
    }

    @MainActor
    func confirm(operation: GitStatusFileOperation, pathCount: Int) -> Bool {
        guard operation.requiresConfirmation else { return true }
        return runAlert(
            operation: operation,
            informativeText: operation.confirmationMessage(pathCount: pathCount)
        )
    }

    @MainActor
    private func runAlert(operation: GitStatusFileOperation, informativeText: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = operation.confirmationTitle
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        let destructiveButton = alert.addButton(withTitle: operation.confirmationButtonTitle)
        destructiveButton.hasDestructiveAction = operation.requiresConfirmation
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct GitStatusSnapshotOwner: Equatable, Hashable, Sendable {
    let workspaceId: UUID
    let rootPath: String
}

@MainActor
final class GitStatusViewModel: ObservableObject {
    @Published private(set) var state: GitStatusLoadState = .idle
    @Published private(set) var stateWorkspaceId: UUID?
    @Published private(set) var stateRootPath: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMutationInProgress = false

    private let service: any GitStatusProviding
    private let resolver: GitStatusRootResolver
    private let pathClipboard: any GitStatusPathCopying
    private let fileOperationConfirmer: any GitStatusFileOperationConfirming
    private let previewService: any GitPreviewProviding

    private static let legacyWorkspaceId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private var snapshotOwner: GitStatusSnapshotOwner?
    private var requestGeneration: UInt64 = 0
    private var activeRequestIds: Set<UInt64> = []
    private var activeRefreshRequests: [GitStatusSnapshotOwner: UInt64] = [:]
    private var activeMutationRequest: (id: UInt64, owner: GitStatusSnapshotOwner)?
    private var pendingRefreshOwners: Set<GitStatusSnapshotOwner> = []

    init(
        service: any GitStatusProviding = GitStatusService(),
        resolver: GitStatusRootResolver = GitStatusRootResolver(),
        pathClipboard: any GitStatusPathCopying = PasteboardGitStatusPathClipboard(),
        fileOperationConfirmer: any GitStatusFileOperationConfirming = AlertGitStatusFileOperationConfirmer(),
        previewService: any GitPreviewProviding = GitPreviewService()
    ) {
        self.service = service
        self.resolver = resolver
        self.pathClipboard = pathClipboard
        self.fileOperationConfirmer = fileOperationConfirmer
        self.previewService = previewService
    }

    func rootPath(for context: GitStatusRootContext) -> String {
        resolver.root(for: context)
    }

    func owner(workspaceId: UUID, context: GitStatusRootContext) -> GitStatusSnapshotOwner {
        GitStatusSnapshotOwner(workspaceId: workspaceId, rootPath: resolver.root(for: context))
    }

    func ownsSnapshot(_ owner: GitStatusSnapshotOwner) -> Bool {
        snapshotOwner == owner
    }

    func canPerformActions(for owner: GitStatusSnapshotOwner) -> Bool {
        ownsSnapshot(owner) && !isRefreshing
    }

    func activate(_ owner: GitStatusSnapshotOwner) {
        guard snapshotOwner != owner else { return }
        requestGeneration &+= 1
        snapshotOwner = owner
        stateWorkspaceId = owner.workspaceId
        stateRootPath = owner.rootPath
        state = .loading
        updateProgressState()
    }

    func clearSelection() {
        requestGeneration &+= 1
        snapshotOwner = nil
        stateWorkspaceId = nil
        stateRootPath = nil
        state = .idle
        updateProgressState()
    }

    func refresh(context: GitStatusRootContext) async {
        await refresh(owner: legacyOwner(context: context), exposesWorkspaceId: false)
    }

    func refresh(workspaceId: UUID?, context: GitStatusRootContext) async {
        guard let workspaceId else {
            await refresh(context: context)
            return
        }
        await refresh(owner: owner(workspaceId: workspaceId, context: context))
    }

    func refresh(owner: GitStatusSnapshotOwner) async {
        await refresh(owner: owner, exposesWorkspaceId: true)
    }

    func titlebarGitContext(for workspaceId: UUID) -> TitlebarGitContext? {
        guard stateWorkspaceId == workspaceId, snapshotOwner?.workspaceId == workspaceId else { return nil }
        return TitlebarGitContextFormatter.context(from: state)
    }

    func initializeRepository(context: GitStatusRootContext) async {
        await initializeRepository(owner: legacyOwner(context: context), exposesWorkspaceId: false)
    }

    func initializeRepository(owner: GitStatusSnapshotOwner) async {
        await initializeRepository(owner: owner, exposesWorkspaceId: true)
    }

    func copyPath(_ path: String) {
        pathClipboard.copyPath(path)
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        context: GitStatusRootContext
    ) async {
        await performFileOperation(
            operation,
            path: path,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        owner: GitStatusSnapshotOwner
    ) async {
        await performFileOperation(operation, path: path, owner: owner, exposesWorkspaceId: true)
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        context: GitStatusRootContext
    ) async {
        await performBulkFileOperation(
            operation,
            paths: paths,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        await performBulkFileOperation(operation, paths: paths, owner: owner, exposesWorkspaceId: true)
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        context: GitStatusRootContext
    ) async {
        await performSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            owner: legacyOwner(context: context),
            exposesWorkspaceId: false
        )
    }

    func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        owner: GitStatusSnapshotOwner
    ) async {
        await performSectionFileOperation(
            operation,
            sectionKey: sectionKey,
            owner: owner,
            exposesWorkspaceId: true
        )
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

    func confirmAndPerformFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner
    ) async {
        guard canPerformActions(for: owner) else { return }
        guard !operation.requiresConfirmation || fileOperationConfirmer.confirm(operation: operation, paths: paths) else {
            return
        }
        await performBulkFileOperation(operation, paths: paths, owner: owner)
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

    func confirmAndPerformSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        pathCount: Int,
        owner: GitStatusSnapshotOwner
    ) async {
        guard canPerformActions(for: owner) else { return }
        guard !operation.requiresConfirmation || fileOperationConfirmer.confirm(operation: operation, pathCount: pathCount) else {
            return
        }
        await performSectionFileOperation(operation, sectionKey: sectionKey, owner: owner)
    }

    func loadPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        context: GitStatusRootContext
    ) async -> GitPreviewLoadState {
        let rootPath = resolver.root(for: context)
        return await previewService.preview(kind: kind, rootPath: rootPath, file: file)
    }

    func loadPreview(
        kind: GitPreviewKind,
        file: GitFileChange,
        owner: GitStatusSnapshotOwner
    ) async -> GitPreviewLoadState {
        guard ownsSnapshot(owner) else {
            return .failed(kind: kind, path: file.path, message: "Git status changed before preview opened.")
        }
        return await previewService.preview(kind: kind, rootPath: owner.rootPath, file: file)
    }

    private func refresh(owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) async {
        activate(owner, exposesWorkspaceId: exposesWorkspaceId)
        if activeRefreshRequests[owner] == requestGeneration { return }
        if activeMutationRequest?.owner == owner {
            pendingRefreshOwners.insert(owner)
            return
        }

        let requestId = beginRequest(owner: owner)
        pendingRefreshOwners.remove(owner)
        activeRefreshRequests[owner] = requestId
        let result = await service.status(rootPath: owner.rootPath)
        publish(result, owner: owner, requestId: requestId)
        if activeRefreshRequests[owner] == requestId {
            activeRefreshRequests[owner] = nil
        }
        finishRequest(requestId)
    }

    private func initializeRepository(owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.initializeRepository(rootPath: owner.rootPath)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    private func performFileOperation(
        _ operation: GitStatusFileOperation,
        path: String,
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performFileOperation(operation, rootPath: owner.rootPath, path: path)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    private func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        paths: [String],
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performBulkFileOperation(operation, rootPath: owner.rootPath, paths: paths)
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    private func performSectionFileOperation(
        _ operation: GitStatusFileOperation,
        sectionKey: String,
        owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) async {
        guard prepareMutationOwner(owner, exposesWorkspaceId: exposesWorkspaceId) else { return }
        guard let requestId = beginMutation(owner: owner) else { return }
        let result = await service.performSectionFileOperation(
            operation,
            rootPath: owner.rootPath,
            sectionKey: sectionKey
        )
        publish(result, owner: owner, requestId: requestId)
        finishMutation(requestId)
    }

    private func activate(_ owner: GitStatusSnapshotOwner, exposesWorkspaceId: Bool) {
        guard snapshotOwner != owner else { return }
        requestGeneration &+= 1
        snapshotOwner = owner
        stateWorkspaceId = exposesWorkspaceId ? owner.workspaceId : nil
        stateRootPath = owner.rootPath
        state = .loading
        updateProgressState()
    }

    private func prepareMutationOwner(
        _ owner: GitStatusSnapshotOwner,
        exposesWorkspaceId: Bool
    ) -> Bool {
        if exposesWorkspaceId {
            return ownsSnapshot(owner)
        }
        activate(owner, exposesWorkspaceId: false)
        return true
    }

    private func beginMutation(owner: GitStatusSnapshotOwner) -> UInt64? {
        guard activeMutationRequest == nil, activeRefreshRequests[owner] == nil else { return nil }
        let requestId = beginRequest(owner: owner)
        activeMutationRequest = (requestId, owner)
        isMutationInProgress = true
        return requestId
    }

    private func finishMutation(_ requestId: UInt64) {
        let completedOwner = activeMutationRequest?.id == requestId
            ? activeMutationRequest?.owner
            : nil
        if completedOwner != nil {
            activeMutationRequest = nil
            isMutationInProgress = false
        }
        finishRequest(requestId)

        guard let completedOwner,
              pendingRefreshOwners.remove(completedOwner) != nil,
              snapshotOwner == completedOwner
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self, self.snapshotOwner == completedOwner else { return }
            await self.refresh(owner: completedOwner, exposesWorkspaceId: true)
        }
    }

    private func beginRequest(owner: GitStatusSnapshotOwner) -> UInt64 {
        requestGeneration &+= 1
        let requestId = requestGeneration
        activeRequestIds.insert(requestId)
        isRefreshing = true
        if snapshotOwner != owner || !isLoadedState {
            state = .loading
        }
        return requestId
    }

    private func finishRequest(_ requestId: UInt64) {
        activeRequestIds.remove(requestId)
        updateProgressState()
    }

    private func updateProgressState() {
        let currentRefreshIsActive = snapshotOwner.flatMap { activeRefreshRequests[$0] } != nil
        isRefreshing = currentRefreshIsActive || activeMutationRequest != nil
    }

    private func publish(
        _ result: GitStatusLoadState,
        owner: GitStatusSnapshotOwner,
        requestId: UInt64
    ) {
        guard requestId == requestGeneration, snapshotOwner == owner else { return }
        state = result
    }

    private var isLoadedState: Bool {
        if case .loaded = state { return true }
        return false
    }

    private func legacyOwner(context: GitStatusRootContext) -> GitStatusSnapshotOwner {
        GitStatusSnapshotOwner(
            workspaceId: Self.legacyWorkspaceId,
            rootPath: resolver.root(for: context)
        )
    }
}
