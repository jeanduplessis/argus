import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Argus

@Suite
@MainActor
struct SidebarNavigationDraggingTests {
    @Test
    func exportedNavigationTypesReachTheGenericItemDropQuery() throws {
        let workspaceId = UUID()
        let collectionId = UUID()
        let drags: [SidebarNavigationDrag] = [
            .workspace(
                SidebarWorkspaceDrag(workspaceId: workspaceId, sourceCollectionId: nil, sourceOrder: [workspaceId])),
            .collection(SidebarCollectionDrag(collectionId: collectionId, sourceOrder: [collectionId]))
        ]
        let declarations = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        for drag in drags {
            #expect(declarations.contains { $0["UTTypeIdentifier"] as? String == drag.typeIdentifier })
            let type = try #require(UTType(drag.typeIdentifier))
            #expect(type.conforms(to: .data))
            #expect(type.conforms(to: .item))
            // DropInfo.itemProviders(for: [.item]) uses this conformance, not just exact type matching.
            let providers = [drag.itemProvider].filter {
                $0.hasItemConformingToTypeIdentifier(UTType.item.identifier)
            }
            #expect(providers.count == 1)
            #expect(SidebarNavigationDropValidation.provider(from: providers, target: .collection(collectionId)) != nil)
        }
    }

    @Test
    func typedWorkspaceDropsMoveIndividualsWithoutChangingSelectionAndRejectStaleSources() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let other = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        manager.selectWorkspace(fixture.child.id)
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let selection = manager.selectedWorkspaceId
        let workspaceOrder = manager.workspaceIds(for: fixture.project)
        let drag = manager.workspaceDrag(fixture.child.id)
        #expect(manager.applyNavigationDrop(drag, to: .collection(first.id), after: false))
        #expect(!manager.applyNavigationDrop(drag, to: .collection(second.id), after: false))
        #expect(manager.collection(containing: fixture.child.id)?.id == first.id)
        #expect(
            manager.applyNavigationDrop(manager.workspaceDrag(other.id), to: .workspace(fixture.child.id), after: true))
        #expect(manager.manualWorkspaceIds(in: first.id) == [fixture.child.id, other.id])
        #expect(
            manager.applyNavigationDrop(manager.workspaceDrag(other.id), to: .workspace(fixture.child.id), after: false)
        )
        #expect(manager.manualWorkspaceIds(in: first.id) == [other.id, fixture.child.id])
        #expect(manager.applyNavigationDrop(manager.workspaceDrag(other.id), to: .collection(second.id), after: false))
        #expect(manager.applyNavigationDrop(manager.workspaceDrag(fixture.child.id), to: .ungrouped, after: false))
        #expect(Array(manager.ungroupedWorkspaceIds.suffix(1)) == [fixture.child.id])
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceIds(for: fixture.project) == workspaceOrder)
        #expect(
            !manager.applyNavigationDrop(
                manager.workspaceDrag(fixture.child.id), to: .workspace(fixture.child.id), after: true))
        #expect(
            !manager.applyNavigationDrop(
                manager.workspaceDrag(UUID()), to: .collection(first.id), after: false))
        #expect(
            !manager.applyNavigationDrop(
                manager.workspaceDrag(fixture.child.id), to: .workspace(UUID()), after: false))
        #expect(!manager.applyNavigationDrop(manager.workspaceDrag(UUID()), to: .collection(first.id), after: false))
        #expect(
            !manager.applyNavigationDrop(manager.workspaceDrag(fixture.child.id), to: .collection(UUID()), after: false)
        )
    }

    @Test
    func collectionDropsReorderBothDirectionsAndRejectWrongOrStaleTargets() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        let third = try #require(manager.createCollection(name: "Third"))
        let drag = manager.collectionDrag(first.id)
        #expect(manager.applyNavigationDrop(drag, to: .collection(third.id), after: true))
        #expect(manager.collections.map(\.id) == [second.id, third.id, first.id])
        #expect(!manager.applyNavigationDrop(drag, to: .collection(second.id), after: false))
        #expect(manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .collection(second.id), after: false))
        #expect(manager.collections.map(\.id) == [first.id, second.id, third.id])
        #expect(
            !manager.applyNavigationDrop(
                manager.collectionDrag(first.id), to: .workspace(fixture.child.id), after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .ungrouped, after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(first.id), to: .collection(first.id), after: false))
        #expect(!manager.applyNavigationDrop(manager.collectionDrag(UUID()), to: .collection(first.id), after: false))
    }

    @Test
    func dropFeedbackDistinguishesInsertionFromSectionAppend() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        let projectType = manager.workspaceDrag(fixture.child.id).typeIdentifier
        let collectionType = manager.collectionDrag(collection.id).typeIdentifier
        for after in [false, true] {
            let insertion = after ? SidebarNavigationDropPlacement.after : .before
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .workspace(fixture.child.id), after: after) == insertion)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: collectionType, target: .collection(collection.id), after: after) == insertion)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .collection(collection.id), after: after) == .append)
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: projectType, target: .ungrouped, after: after) == .append)
        }
    }

    @Test
    func mixedMultipleAndLegacyTextProvidersCannotEnterNavigationDrops() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Work"))
        let projectDrag = manager.workspaceDrag(fixture.child.id)
        let collectionDrag = manager.collectionDrag(collection.id)
        let project = projectDrag.itemProvider
        let organizer = collectionDrag.itemProvider
        let workspace = NSItemProvider(object: fixture.child.id.uuidString as NSString)
        let target = SidebarNavigationDrop.collection(collection.id)
        #expect(SidebarNavigationDropValidation.provider(from: [project], target: target) != nil)
        #expect(SidebarNavigationDropValidation.provider(from: [organizer], target: target) != nil)
        #expect(SidebarNavigationDropValidation.provider(from: [workspace], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, organizer], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, workspace], target: target) == nil)
        #expect(SidebarNavigationDropValidation.provider(from: [project, project], target: target) == nil)
        #expect(
            SidebarNavigationDropValidation.provider(from: [organizer], target: .workspace(fixture.child.id)) == nil)
        let mixed = NSItemProvider()
        for type in [projectDrag.typeIdentifier, collectionDrag.typeIdentifier] {
            mixed.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(Data(), nil)
                return nil
            }
        }
        #expect(SidebarNavigationDropValidation.provider(from: [mixed], target: target) == nil)
        #expect(projectDrag.typeIdentifier != collectionDrag.typeIdentifier)
    }
}
