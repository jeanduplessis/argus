import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    // Keep these types declared in project.yml's generated Info.plist so the
    // drop delegate's generic .item query can discover their providers.
    fileprivate static let argusWorkspace = UTType(exportedAs: "com.argus.sidebar-workspace", conformingTo: .data)
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

enum SidebarNavigationDrag: Codable, Equatable, Sendable {
    case workspace(SidebarWorkspaceDrag)
    case collection(SidebarCollectionDrag)

    var typeIdentifier: String {
        switch self {
        case .workspace: UTType.argusWorkspace.identifier
        case .collection: UTType.argusCollection.identifier
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
    case collection(UUID)
    case ungrouped
}

struct SidebarNavigationDropContext: Equatable, Sendable {
    let target: SidebarNavigationDrop
    let collectionId: UUID?
    let workspaceOrder: [UUID]
    let collectionOrder: [UUID]
}

extension WorkspaceManager {
    func navigationDropContext(for target: SidebarNavigationDrop) -> SidebarNavigationDropContext? {
        let collectionId: UUID?
        switch target {
        case .workspace(let workspaceId):
            guard workspaces.contains(where: { $0.id == workspaceId }) else { return nil }
            collectionId = collection(containing: workspaceId)?.id
        case .collection(let id):
            guard collections.contains(where: { $0.id == id }) else { return nil }
            collectionId = id
        case .ungrouped:
            collectionId = nil
        }
        return SidebarNavigationDropContext(
            target: target, collectionId: collectionId,
            workspaceOrder: manualWorkspaceIds(in: collectionId), collectionOrder: collections.map(\.id))
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

    /// Validate against live identity and source order at drop time. A stale or
    /// mixed drag cannot silently move a different block or change resource ownership.
    @discardableResult
    func applyNavigationDrop(_ drag: SidebarNavigationDrag, to target: SidebarNavigationDrop, after: Bool) -> Bool {
        switch drag {
        case .workspace(let source):
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
            case .collection(let collectionId):
                return moveWorkspace(source.workspaceId, toCollection: collectionId)
            case .ungrouped:
                return moveWorkspace(source.workspaceId, toCollection: nil)
            }
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
}

struct SidebarNavigationDropTarget: ViewModifier {
    let target: SidebarNavigationDrop
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var placement: SidebarNavigationDropPlacement?
    @State private var targetHeight: CGFloat = 28

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
                of: [.argusWorkspace, .argusCollection],
                delegate: SidebarNavigationDropDelegate(
                    manager: workspaceManager, target: target, targetHeight: targetHeight, placement: $placement)
            )
    }
}

private struct SidebarNavigationDropDelegate: DropDelegate {
    let manager: WorkspaceManager
    let target: SidebarNavigationDrop
    let targetHeight: CGFloat
    @Binding var placement: SidebarNavigationDropPlacement?

    func validateDrop(info: DropInfo) -> Bool { provider(in: info) != nil }

    func dropEntered(info: DropInfo) { updatePlacement(info: info) }
    func dropExited(info: DropInfo) { placement = nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePlacement(info: info)
        return DropProposal(operation: placement != nil ? .move : .forbidden)
    }

    private func updatePlacement(info: DropInfo) {
        placement = provider(in: info).map { _, type in
            SidebarNavigationDropPlacement(
                typeIdentifier: type, target: target, after: info.location.y > targetHeight / 2)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        placement = nil
        guard let (provider, type) = provider(in: info),
            let context = manager.navigationDropContext(for: target)
        else { return false }
        let after = info.location.y > targetHeight / 2
        Task { @MainActor in
            await manager.loadNavigationDrop(from: provider, typeIdentifier: type, context: context, after: after)
        }
        return true
    }

    private func provider(in info: DropInfo) -> (NSItemProvider, String)? {
        let providers = info.itemProviders(for: [.item])
        return SidebarNavigationDropValidation.provider(from: providers, target: target)
    }
}

enum SidebarNavigationDropValidation {
    static func provider(from providers: [NSItemProvider], target: SidebarNavigationDrop) -> (NSItemProvider, String)? {
        guard providers.count == 1, let provider = providers.first else { return nil }
        let types = [UTType.argusWorkspace.identifier, UTType.argusCollection.identifier]
            .filter { provider.hasItemConformingToTypeIdentifier($0) }
        guard types.count == 1, let type = types.first,
            !provider.hasItemConformingToTypeIdentifier(UTType.text.identifier)
        else { return nil }
        if type == UTType.argusCollection.identifier, case .collection = target { return (provider, type) }
        return type == UTType.argusWorkspace.identifier ? (provider, type) : nil
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
            case .collection, .ungrouped:
                self = .append
                return
            case .workspace:
                break
            }
        }
        self = after ? .after : .before
    }
}
