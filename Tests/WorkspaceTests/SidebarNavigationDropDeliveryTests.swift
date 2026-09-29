import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Argus

@Suite
@MainActor
struct SidebarNavigationDropDeliveryTests {
    @Test(arguments: [true, false], [true, false])
    func workspaceProviderAppendsToEmptyCollectionWithoutChangingContent(
        isExpanded: Bool, sourceIsGrouped: Bool
    ) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let destination = try #require(manager.createCollection(name: "Destination"))
        if !isExpanded { manager.toggleCollection(destination.id) }
        let sourceId: UUID?
        if sourceIsGrouped {
            sourceId = try #require(manager.createCollection(name: "Source")).id
            manager.moveWorkspace(fixture.child.id, toCollection: sourceId)
        } else {
            sourceId = nil
        }
        let panel = try #require(fixture.child.addTerminalPanel())
        let drag = manager.workspaceDrag(fixture.child.id)
        let target = SidebarNavigationDrop.collection(destination.id)
        let providers = [drag.itemProvider].filter {
            $0.hasItemConformingToTypeIdentifier(UTType.item.identifier)
        }
        let (provider, type) = try #require(SidebarNavigationDropValidation.provider(from: providers, target: target))
        #expect(SidebarNavigationDropPlacement(typeIdentifier: type, target: target, after: false) == .append)
        let context = try #require(manager.navigationDropContext(for: target))
        #expect(await manager.loadNavigationDrop(from: provider, typeIdentifier: type, context: context, after: false))
        #expect(manager.manualWorkspaceIds(in: destination.id) == [fixture.child.id])
        #expect(!manager.manualWorkspaceIds(in: sourceId).contains(fixture.child.id))
        #expect(manager.collection(containing: fixture.parent.id) == nil)
        #expect(manager.collections.first?.isExpanded == isExpanded)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.child.projectId == fixture.project.id)
        #expect(fixture.child.activeTabId == panel.id)
        #expect(fixture.child.activePanelId == panel.id)
        #expect(fixture.child.panels[panel.id] as? TerminalPanel === panel)
    }

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

extension SidebarNavigationDropDeliveryTests {
    enum ProjectBlockChange: CaseIterable, Sendable {
        case none, sourceAssociation, targetAssociation, sourceOrder, sourceMembership, targetRemoved,
            sourceProjectRemoved, sectionRemoved, collectionOrder, malformedData, wrongKind, oversizedData
    }

    @Test(arguments: ProjectBlockChange.allCases)
    func projectBlockDeliveryRevalidatesSectionOrderAndAllAssociations(change: ProjectBlockChange) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let section = try #require(manager.createCollection(name: "Work"))
        let elsewhere = try #require(manager.createCollection(name: "Elsewhere"))
        let otherProject = Project(
            repositoryPath: fixture.root.appendingPathComponent("other").path, mainBranch: "main")
        manager.projects.append(otherProject)
        fixture.ordinary.projectId = otherProject.id
        for id in fixture.manualOrder { manager.moveWorkspace(id, toCollection: section.id) }
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        manager.moveWorkspace(standalone.id, toCollection: section.id)
        let drag = manager.projectBlockDrag(fixture.project.id, in: section.id)
        let target = SidebarNavigationDrop.project(otherProject.id, collectionId: section.id)
        let context = try #require(manager.navigationDropContext(for: target))
        let delayed = DelayedNavigationProvider(typeIdentifier: drag.typeIdentifier)
        let delivery = Task {
            await manager.loadNavigationDrop(
                from: delayed.provider, typeIdentifier: drag.typeIdentifier, context: context, after: true)
        }
        await waitForStackState { delayed.isRequested }
        applyProjectBlockChange(
            change, fixture: fixture, sectionId: section.id, elsewhereId: elsewhere.id, otherProjectId: otherProject.id)
        let beforeDelivery = manager.manualWorkspaceIds(in: section.id)
        let ungroupedBeforeDelivery = manager.ungroupedWorkspaceIds
        let savedBeforeDelivery = try Data(contentsOf: manager.sessionSnapshotURL)
        delayed.complete(
            with: try projectBlockData(for: change, drag: drag, manager: manager, workspaceId: fixture.child.id))
        #expect(await delivery.value == (change == .none))
        if change == .none {
            #expect(
                manager.manualWorkspaceIds(in: section.id) == [
                    fixture.ordinary.id, fixture.child.id, fixture.parent.id, standalone.id
                ])
        } else {
            #expect(manager.manualWorkspaceIds(in: section.id) == beforeDelivery)
            #expect(manager.ungroupedWorkspaceIds == ungroupedBeforeDelivery)
            #expect(try Data(contentsOf: manager.sessionSnapshotURL) == savedBeforeDelivery)
        }
    }

    private func applyProjectBlockChange(
        _ change: ProjectBlockChange, fixture: WorkspaceStackTestFixture,
        sectionId: UUID, elsewhereId: UUID, otherProjectId: UUID
    ) {
        let manager = fixture.manager
        switch change {
        case .sourceAssociation: fixture.parent.projectId = otherProjectId
        case .targetAssociation: fixture.ordinary.projectId = nil
        case .sourceOrder: manager.moveWorkspace(fixture.parent.id, toCollection: sectionId, at: 0)
        case .sourceMembership: manager.moveWorkspace(fixture.parent.id, toCollection: elsewhereId)
        case .targetRemoved: manager.removeWorkspace(fixture.ordinary.id)
        case .sourceProjectRemoved: manager.projects.removeAll { $0.id == fixture.project.id }
        case .sectionRemoved: manager.removeCollection(sectionId)
        case .collectionOrder: manager.moveCollection(sectionId, offset: 1)
        default: break
        }
    }

    private func projectBlockData(
        for change: ProjectBlockChange, drag: SidebarNavigationDrag, manager: WorkspaceManager, workspaceId: UUID
    ) throws -> Data {
        switch change {
        case .malformedData: return Data("not JSON".utf8)
        case .wrongKind: return try JSONEncoder().encode(manager.workspaceDrag(workspaceId))
        case .oversizedData: return Data(repeating: 32, count: 32_769)
        default: return try JSONEncoder().encode(drag)
        }
    }

    @Test
    func workspaceProviderStillAppendsThroughAProjectHeading() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let section = try #require(manager.createCollection(name: "Work"))
        manager.moveWorkspace(fixture.parent.id, toCollection: section.id)
        manager.toggleRepository(fixture.project.id, in: section.id)
        let drag = manager.workspaceDrag(fixture.child.id)
        let target = SidebarNavigationDrop.project(fixture.project.id, collectionId: section.id)
        let context = try #require(manager.navigationDropContext(for: target))
        #expect(
            await manager.loadNavigationDrop(
                from: drag.itemProvider, typeIdentifier: drag.typeIdentifier, context: context, after: false))
        #expect(manager.manualWorkspaceIds(in: section.id) == [fixture.parent.id, fixture.child.id])
        #expect(!manager.repositoryDisclosure(for: fixture.project.id, in: section.id).isExpanded)
    }
}
