import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    // Keep these types declared in project.yml's generated Info.plist so the
    // drop delegate's generic .item query can discover their providers.
    fileprivate static let argusWorkspace = UTType(exportedAs: "com.argus.sidebar-workspace", conformingTo: .data)
    fileprivate static let argusProjectBlock = UTType(
        exportedAs: "com.argus.sidebar-project-block", conformingTo: .data)
    fileprivate static let argusCollection = UTType(exportedAs: "com.argus.sidebar-collection", conformingTo: .data)
}

struct SidebarWorkspaceDrag: Codable, Equatable, Sendable {
    let workspaceId: UUID
    let sourceCollectionId: UUID?
    let sourceOrder: [UUID]
}

struct SidebarCollectionDrag: Codable, Equatable, Sendable {
    let collectionId: UUID
    let sourceOrder: [UUID]
}

struct SidebarProjectBlockDrag: Codable, Equatable, Sendable {
    let projectId: UUID
    let sourceCollectionId: UUID?
    let sourceOrder: [UUID]
    let sourceProjectIds: [UUID?]
}

enum SidebarNavigationDrag: Codable, Equatable, Sendable {
    case workspace(SidebarWorkspaceDrag)
    case collection(SidebarCollectionDrag)
    case projectBlock(SidebarProjectBlockDrag)

    var typeIdentifier: String {
        switch self {
        case .workspace: UTType.argusWorkspace.identifier
        case .collection: UTType.argusCollection.identifier
        case .projectBlock: UTType.argusProjectBlock.identifier
        }
    }

    var itemProvider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

enum SidebarNavigationDrop: Equatable, Sendable {
    case workspace(UUID)
    case project(UUID, collectionId: UUID?)
    case collection(UUID)
    case ungrouped
}

struct SidebarNavigationDropContext: Equatable, Sendable {
    let target: SidebarNavigationDrop
    let collectionId: UUID?
    let workspaceOrder: [UUID]
    let workspaceProjectIds: [UUID?]
    let collectionOrder: [UUID]
}

extension WorkspaceManager {
    func navigationDropContext(for target: SidebarNavigationDrop) -> SidebarNavigationDropContext? {
        let collectionId: UUID?
        switch target {
        case .workspace(let workspaceId):
            guard workspaces.contains(where: { $0.id == workspaceId }) else { return nil }
            collectionId = collection(containing: workspaceId)?.id
        case .project(let projectId, let sectionId):
            guard projects.contains(where: { $0.id == projectId }),
                sectionId == nil || collections.contains(where: { $0.id == sectionId }),
                manualWorkspaceIds(in: sectionId).contains(where: { project(for: $0)?.id == projectId })
            else { return nil }
            collectionId = sectionId
        case .collection(let id):
            guard collections.contains(where: { $0.id == id }) else { return nil }
            collectionId = id
        case .ungrouped:
            collectionId = nil
        }
        return SidebarNavigationDropContext(
            target: target, collectionId: collectionId,
            workspaceOrder: manualWorkspaceIds(in: collectionId),
            workspaceProjectIds: manualWorkspaceIds(in: collectionId).map { id in
                workspaces.first { $0.id == id }?.projectId
            },
            collectionOrder: collections.map(\.id))
    }

    /// Capture the destination before the asynchronous provider read. Completion
    /// must not redirect a drop to a target's newly changed Collection or position.
    func loadNavigationDrop(
        from provider: NSItemProvider, typeIdentifier: String,
        context: SidebarNavigationDropContext, after: Bool
    ) async -> Bool {
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, data.count <= 32_768,
            let drag = try? JSONDecoder().decode(SidebarNavigationDrag.self, from: data),
            drag.typeIdentifier == typeIdentifier,
            navigationDropContext(for: context.target) == context
        else { return false }
        return applyNavigationDrop(drag, to: context.target, after: after)
    }

    func workspaceDrag(_ workspaceId: UUID) -> SidebarNavigationDrag {
        let collectionId = collection(containing: workspaceId)?.id
        return .workspace(
            SidebarWorkspaceDrag(
                workspaceId: workspaceId, sourceCollectionId: collectionId,
                sourceOrder: manualWorkspaceIds(in: collectionId)))
    }

    func collectionDrag(_ collectionId: UUID) -> SidebarNavigationDrag {
        .collection(SidebarCollectionDrag(collectionId: collectionId, sourceOrder: collections.map(\.id)))
    }

    func projectBlockDrag(_ projectId: UUID, in collectionId: UUID?) -> SidebarNavigationDrag {
        let order = manualWorkspaceIds(in: collectionId)
        return .projectBlock(
            SidebarProjectBlockDrag(
                projectId: projectId, sourceCollectionId: collectionId, sourceOrder: order,
                sourceProjectIds: order.map { id in workspaces.first { $0.id == id }?.projectId }))
    }

    func projectBlockDropTarget(
        _ source: SidebarProjectBlockDrag, to target: SidebarNavigationDrop
    ) -> WorkspaceNavigationBlock.Identifier? {
        guard let context = navigationDropContext(for: target),
            context.collectionId == source.sourceCollectionId,
            context.workspaceOrder == source.sourceOrder,
            context.workspaceProjectIds == source.sourceProjectIds
        else { return nil }
        switch target {
        case .project(let projectId, _): return .repository(projectId)
        case .workspace(let id):
            guard workspaces.first(where: { $0.id == id })?.projectId == nil else { return nil }
            return .workspace(id)
        case .collection, .ungrouped: return nil
        }
    }

    func canDropProjectBlock(_ source: SidebarProjectBlockDrag, to target: SidebarNavigationDrop, after: Bool) -> Bool {
        guard let block = projectBlockDropTarget(source, to: target) else { return false }
        return reorderedProjectBlockIds(
            source.projectId, in: source.sourceCollectionId, relativeTo: block, after: after) != nil
    }

    /// Validate against live identity and source order at drop time. A stale or
    /// mixed drag cannot silently move a different block or change resource ownership.
    @discardableResult
    func applyNavigationDrop(_ drag: SidebarNavigationDrag, to target: SidebarNavigationDrop, after: Bool) -> Bool {
        switch drag {
        case .workspace(let source):
            return applyWorkspaceDrop(source, to: target, after: after)
        case .projectBlock(let source):
            guard let block = projectBlockDropTarget(source, to: target) else { return false }
            return reorderProjectBlock(
                source.projectId, in: source.sourceCollectionId, relativeTo: block, after: after)
        case .collection(let source):
            guard source.sourceOrder == collections.map(\.id),
                let sourceIndex = collections.firstIndex(where: { $0.id == source.collectionId }),
                case .collection(let targetId) = target,
                targetId != source.collectionId,
                let targetIndex = collections.firstIndex(where: { $0.id == targetId })
            else { return false }
            let index = targetIndex - (sourceIndex < targetIndex ? 1 : 0) + (after ? 1 : 0)
            return reorderCollection(source.collectionId, to: index)
        }
    }

    private func applyWorkspaceDrop(
        _ source: SidebarWorkspaceDrag, to target: SidebarNavigationDrop, after: Bool
    ) -> Bool {
        guard workspaces.contains(where: { $0.id == source.workspaceId }),
            collection(containing: source.workspaceId)?.id == source.sourceCollectionId,
            manualWorkspaceIds(in: source.sourceCollectionId) == source.sourceOrder
        else { return false }
        switch target {
        case .workspace(let targetId):
            guard targetId != source.workspaceId, workspaces.contains(where: { $0.id == targetId }) else {
                return false
            }
            let destinationId = collection(containing: targetId)?.id
            let siblings = manualWorkspaceIds(in: destinationId).filter { $0 != source.workspaceId }
            guard let index = siblings.firstIndex(of: targetId) else { return false }
            return moveWorkspace(source.workspaceId, toCollection: destinationId, at: index + (after ? 1 : 0))
        case .project(_, let collectionId):
            guard navigationDropContext(for: target) != nil else { return false }
            return moveWorkspace(source.workspaceId, toCollection: collectionId)
        case .collection(let collectionId):
            return moveWorkspace(source.workspaceId, toCollection: collectionId)
        case .ungrouped:
            return moveWorkspace(source.workspaceId, toCollection: nil)
        }
    }
}

struct SidebarNavigationDropTarget: ViewModifier {
    let target: SidebarNavigationDrop
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var feedback: SidebarNavigationDropFeedback

    @State var feedbackId = UUID()
    @State private var targetHeight: CGFloat = 28

    private var placement: SidebarNavigationDropPlacement? {
        feedback.placement(for: feedbackId)
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                targetHeight = $0
            }
            .overlay {
                if placement == .append {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1) }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: placement == .after ? .bottom : .top) {
                if placement == .before || placement == .after {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onDrop(
                of: [.argusWorkspace, .argusCollection, .argusProjectBlock],
                delegate: SidebarNavigationDropDelegate(
                    manager: workspaceManager, target: target, targetHeight: targetHeight, feedback: feedback,
                    feedbackId: feedbackId)
            )
    }
}

private struct SidebarNavigationDropDelegate: DropDelegate {
    let manager: WorkspaceManager
    let target: SidebarNavigationDrop
    let targetHeight: CGFloat
    let feedback: SidebarNavigationDropFeedback
    let feedbackId: UUID

    func validateDrop(info: DropInfo) -> Bool {
        guard let type = typeIdentifier(in: info) else { return false }
        guard type == UTType.argusProjectBlock.identifier else { return true }
        guard let source = feedback.projectBlockDrag else { return false }
        // Keep both halves reachable even when one half would be a no-op.
        return manager.canDropProjectBlock(source, to: target, after: false)
            || manager.canDropProjectBlock(source, to: target, after: true)
    }

    func dropEntered(info: DropInfo) {
        feedback.enter(feedbackId, placement: placement(in: info))
    }
    func dropExited(info: DropInfo) {
        feedback.exit(feedbackId)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        feedback.update(feedbackId, placement: placement(in: info))
        return DropProposal(operation: feedback.placement(for: feedbackId) != nil ? .move : .forbidden)
    }

    private func placement(in info: DropInfo) -> SidebarNavigationDropPlacement? {
        guard let type = typeIdentifier(in: info) else { return nil }
        let after = info.location.y > targetHeight / 2
        if type == UTType.argusProjectBlock.identifier {
            guard let source = feedback.projectBlockDrag,
                manager.canDropProjectBlock(source, to: target, after: after)
            else { return nil }
        }
        return SidebarNavigationDropPlacement(typeIdentifier: type, target: target, after: after)
    }

    func performDrop(info: DropInfo) -> Bool {
        feedback.end()
        guard
            let (provider, type) = SidebarNavigationDropValidation.provider(
                from: info.itemProviders(for: [.item]), target: target),
            let context = manager.navigationDropContext(for: target)
        else { return false }
        let after = info.location.y > targetHeight / 2
        Task { @MainActor in
            await manager.loadNavigationDrop(from: provider, typeIdentifier: type, context: context, after: after)
        }
        return true
    }

    private func typeIdentifier(in info: DropInfo) -> String? {
        // Enumerating generic item providers can start a file-promise read.
        // AppKit permits that only at drop time, not during validation or hover.
        SidebarNavigationDropValidation.typeIdentifier(
            hasWorkspace: info.hasItemsConforming(to: [.argusWorkspace]),
            hasCollection: info.hasItemsConforming(to: [.argusCollection]),
            hasText: info.hasItemsConforming(to: [.text]),
            hasProjectBlock: info.hasItemsConforming(to: [.argusProjectBlock]), target: target)
    }
}

enum SidebarNavigationDropValidation {
    static func provider(from providers: [NSItemProvider], target: SidebarNavigationDrop) -> (NSItemProvider, String)? {
        guard providers.count == 1, let provider = providers.first else { return nil }
        guard
            let type = typeIdentifier(
                hasWorkspace: provider.hasItemConformingToTypeIdentifier(UTType.argusWorkspace.identifier),
                hasCollection: provider.hasItemConformingToTypeIdentifier(UTType.argusCollection.identifier),
                hasText: provider.hasItemConformingToTypeIdentifier(UTType.text.identifier),
                hasProjectBlock: provider.hasItemConformingToTypeIdentifier(UTType.argusProjectBlock.identifier),
                target: target)
        else { return nil }
        return (provider, type)
    }

    static func typeIdentifier(
        hasWorkspace: Bool, hasCollection: Bool, hasText: Bool, hasProjectBlock: Bool = false,
        target: SidebarNavigationDrop
    ) -> String? {
        guard [hasWorkspace, hasCollection, hasProjectBlock].filter({ $0 }).count == 1, !hasText else { return nil }
        if hasProjectBlock {
            switch target {
            case .project, .workspace: return UTType.argusProjectBlock.identifier
            case .collection, .ungrouped: return nil
            }
        }
        if hasWorkspace { return UTType.argusWorkspace.identifier }
        if case .collection = target { return UTType.argusCollection.identifier }
        return nil
    }
}

enum SidebarNavigationDropPlacement: Equatable {
    case before
    case after
    case append

    init(typeIdentifier: String, target: SidebarNavigationDrop, after: Bool) {
        if typeIdentifier == UTType.argusWorkspace.identifier {
            // Workspace drops append when the destination is a section rather than another Workspace.
            switch target {
            case .project, .collection, .ungrouped:
                self = .append
                return
            case .workspace:
                break
            }
        }
        self = after ? .after : .before
    }
}
