import AppKit
import Testing

@testable import Argus

@Suite
@MainActor
struct SidebarNavigationDropDeliveryTests {
    enum DestinationChange: CaseIterable, Sendable {
        case none, membership, workspaceOrder, sourceOrder, collectionOrder, removeWorkspace, removeCollection
    }

    @Test(arguments: DestinationChange.allCases)
    func asynchronousDeliveryRejectsChangedDestinationWithoutRedirectingSource(change: DestinationChange) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let target = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let sibling = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        manager.selectWorkspace(fixture.child.id)
        manager.moveWorkspace(target.id, toCollection: first.id)
        manager.moveWorkspace(sibling.id, toCollection: first.id)
        let drag = manager.workspaceDrag(fixture.child.id)
        let context = try #require(manager.navigationDropContext(for: .workspace(target.id)))
        let delayed = DelayedNavigationProvider(typeIdentifier: drag.typeIdentifier)
        let delivery = Task {
            await manager.loadNavigationDrop(
                from: delayed.provider, typeIdentifier: drag.typeIdentifier, context: context, after: true)
        }
        await waitForStackState { delayed.isRequested }
        switch change {
        case .none: break
        case .membership: manager.moveWorkspace(target.id, toCollection: second.id)
        case .sourceOrder: manager.moveWorkspace(fixture.parent.id, toCollection: nil, at: 0)
        case .workspaceOrder: manager.moveWorkspace(target.id, toCollection: first.id, at: 1)
        case .collectionOrder: manager.moveCollection(first.id, offset: 1)
        case .removeWorkspace: manager.removeWorkspace(target.id)
        case .removeCollection: manager.removeCollection(first.id)
        }
        delayed.complete(with: try JSONEncoder().encode(drag))
        #expect(await delivery.value == (change == .none))
        #expect(manager.collection(containing: fixture.child.id)?.id == (change == .none ? first.id : nil))
        if change == .none {
            #expect(manager.manualWorkspaceIds(in: first.id) == [target.id, fixture.child.id, sibling.id])
        }
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }
}

/// Holds the real NSItemProvider callback until the test changes the destination.
private final class DelayedNavigationProvider: @unchecked Sendable {
    let provider = NSItemProvider()
    private let lock = NSLock()
    private var completion: (@Sendable (Data?, (any Error)?) -> Void)?

    var isRequested: Bool { lock.withLock { completion != nil } }

    init(typeIdentifier: String) {
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { [weak self] in
            self?.setCompletion($0)
            return nil
        }
    }

    private func setCompletion(_ completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        lock.withLock { self.completion = completion }
    }

    func complete(with data: Data) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(data, nil)
    }
}
