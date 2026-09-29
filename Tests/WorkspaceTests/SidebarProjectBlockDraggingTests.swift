import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Argus

@Suite
@MainActor
struct SidebarProjectBlockDraggingTests {
    @Test(arguments: [false, true])
    func projectBlocksReorderInterleavedMembersWithinTheirSection(grouped: Bool) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let sectionId = grouped ? try #require(manager.createCollection(name: "Work")).id : nil
        let elsewhere = try #require(manager.createCollection(name: "Elsewhere"))
        manager.moveWorkspace(fixture.ordinary.id, toCollection: elsewhere.id)
        let others = try interleavedMembers(in: fixture, sectionId: sectionId)
        let first = others.first
        let last = others.last
        let standalone = others.standalone
        let projectId = fixture.project.id
        let members = [fixture.child.id, fixture.parent.id]
        let associations = manager.workspaces.map(\.projectId)
        let target = SidebarNavigationDrop.project(try #require(first.projectId), collectionId: sectionId)
        let drag = manager.projectBlockDrag(projectId, in: sectionId)
        if case .projectBlock(let source) = drag {
            #expect(!manager.canDropProjectBlock(source, to: target, after: false))
            #expect(manager.canDropProjectBlock(source, to: target, after: true))
            let otherSection = SidebarNavigationDrop.project(projectId, collectionId: elsewhere.id)
            #expect(!manager.canDropProjectBlock(source, to: otherSection, after: true))
        }
        #expect(manager.applyNavigationDrop(drag, to: target, after: true))
        #expect(manager.manualWorkspaceIds(in: sectionId) == [first.id] + members + [standalone.id, last.id])
        #expect(!manager.applyNavigationDrop(drag, to: .workspace(standalone.id), after: true))
        let freshDrag = manager.projectBlockDrag(projectId, in: sectionId)
        #expect(manager.applyNavigationDrop(freshDrag, to: .workspace(standalone.id), after: true))
        #expect(manager.manualWorkspaceIds(in: sectionId) == [first.id, standalone.id] + members + [last.id])
        #expect(!manager.canMoveProjectBlock(projectId, in: sectionId, offset: 1))
        #expect(manager.moveProjectBlock(projectId, in: sectionId, offset: -1))
        #expect(manager.moveProjectBlock(projectId, in: sectionId, offset: -1))
        #expect(!manager.canMoveProjectBlock(projectId, in: sectionId, offset: -1))
        #expect(manager.moveProjectBlock(projectId, in: sectionId, offset: 1))
        let finalDrag = manager.projectBlockDrag(projectId, in: sectionId)
        #expect(manager.applyNavigationDrop(finalDrag, to: target, after: false))
        #expect(manager.manualWorkspaceIds(in: sectionId) == members + [first.id, standalone.id, last.id])
        #expect(manager.manualWorkspaceIds(in: elsewhere.id) == [fixture.ordinary.id])
        #expect(manager.workspaces.map(\.projectId) == associations)
    }

    @Test(arguments: [false, true])
    func projectBlockMovementCheckpointsOrderAndPreservesDisclosureAttentionAndContent(grouped: Bool) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let sectionId = grouped ? try #require(manager.createCollection(name: "Work")).id : nil
        _ = try interleavedMembers(in: fixture, sectionId: sectionId)
        let terminal = try #require(fixture.child.addTerminalPanel())
        let attention = TurnCompletionAttentionStore()
        let target = TurnCompletionAttentionTarget(workspaceId: fixture.child.id, tabId: terminal.id)
        _ = attention.record(agentKey: "test", eventId: "done", target: target, isViewed: false)
        manager.setTurnCompletionRuntime(
            TurnCompletionRuntime(
                workspaceManager: manager, attentionStore: attention, isMainWindowKey: { false }))
        manager.selectWorkspace(fixture.child.id)
        manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id, collectionId: sectionId)
        manager.toggleRepository(fixture.project.id, in: sectionId)
        let disclosure = manager.repositoryDisclosure(for: fixture.project.id, in: sectionId)
        let projectOrder = manager.projects.map(\.id)
        let workspaceOrder = manager.workspaces.map(\.id)
        #expect(manager.moveProjectBlock(fixture.project.id, in: sectionId, offset: 1))
        #expect(manager.projects.map(\.id) == projectOrder)
        #expect(manager.workspaces.map(\.id) == workspaceOrder)
        #expect(manager.repositoryDisclosure(for: fixture.project.id, in: sectionId) == disclosure)
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.child.activeTabId == terminal.id)
        #expect(fixture.child.activePanelId == terminal.id)
        #expect(fixture.child.panels[terminal.id] === terminal)
        #expect(attention.attentionTargets == [target])
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshot)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        let savedOrder =
            sectionId.flatMap { id in saved.collections?.first { $0.id == id }?.workspaceIds }
            ?? saved.ungroupedWorkspaceIds
        #expect(savedOrder == manager.manualWorkspaceIds(in: sectionId))
        #expect(manager.restoreSession(from: saved))
        #expect(manager.manualWorkspaceIds(in: sectionId) == savedOrder)
        #expect(manager.repositoryDisclosure(for: fixture.project.id, in: sectionId) == disclosure)
    }

    private struct InterleavedMembers {
        let first: Workspace
        let last: Workspace
        let standalone: Workspace
    }

    private func interleavedMembers(
        in fixture: WorkspaceStackTestFixture, sectionId: UUID?
    ) throws -> InterleavedMembers {
        let manager = fixture.manager
        let otherProject = Project(
            repositoryPath: fixture.root.appendingPathComponent("other").path, mainBranch: "main")
        manager.projects.append(otherProject)
        let first = fixture.makeWorkspace(branch: "other-first")
        let last = fixture.makeWorkspace(branch: "other-last")
        for workspace in [first, last] {
            workspace.projectId = otherProject.id
            manager.workspaces.append(workspace)
            manager.appendPlacement(workspace.id, to: sectionId)
        }
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        for id in [fixture.child.id, fixture.parent.id, standalone.id] {
            manager.moveWorkspace(id, toCollection: sectionId)
        }
        let members = [fixture.child.id, first.id, standalone.id, fixture.parent.id, last.id]
        let remaining = manager.manualWorkspaceIds(in: sectionId).filter { !members.contains($0) }
        manager.setManualWorkspaceIds(members + remaining, in: sectionId)
        return InterleavedMembers(first: first, last: last, standalone: standalone)
    }

    @Test
    func projectBlockDropsRejectCrossSectionDescendantSelfMissingAndChangedMembership() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let section = try #require(manager.createCollection(name: "Work"))
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        manager.moveWorkspace(fixture.ordinary.id, toCollection: section.id)
        let drag = manager.projectBlockDrag(fixture.project.id, in: nil)
        let original = manager.ungroupedWorkspaceIds
        for target in [
            SidebarNavigationDrop.project(fixture.project.id, collectionId: section.id),
            .project(fixture.project.id, collectionId: nil), .project(UUID(), collectionId: nil),
            .workspace(fixture.parent.id), .workspace(UUID()), .collection(section.id), .ungrouped
        ] {
            #expect(!manager.applyNavigationDrop(drag, to: target, after: true))
        }
        #expect(manager.ungroupedWorkspaceIds == original)
        fixture.parent.projectId = nil
        #expect(!manager.applyNavigationDrop(drag, to: .workspace(standalone.id), after: true))
        fixture.parent.projectId = fixture.project.id
        manager.moveWorkspace(fixture.ordinary.id, toCollection: nil)
        #expect(!manager.applyNavigationDrop(drag, to: .workspace(standalone.id), after: true))
        #expect(!manager.moveProjectBlock(fixture.project.id, in: nil, offset: 2))
        #expect(!manager.moveProjectBlock(fixture.project.id, in: UUID(), offset: 1))
    }

    @Test
    func projectBlockProvidersAreDistinctAndShowInsertionInsteadOfWorkspaceAppend() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let drag = manager.projectBlockDrag(fixture.project.id, in: nil)
        let heading = SidebarNavigationDrop.project(fixture.project.id, collectionId: nil)
        let declarations = try #require(
            Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        #expect(declarations.contains { $0["UTTypeIdentifier"] as? String == drag.typeIdentifier })
        #expect(try #require(UTType(drag.typeIdentifier)).conforms(to: .item))
        #expect(SidebarNavigationDropValidation.provider(from: [drag.itemProvider], target: heading) != nil)
        for after in [false, true] {
            #expect(
                SidebarNavigationDropPlacement(typeIdentifier: drag.typeIdentifier, target: heading, after: after)
                    == (after ? .after : .before))
            #expect(
                SidebarNavigationDropPlacement(
                    typeIdentifier: manager.workspaceDrag(fixture.child.id).typeIdentifier, target: heading,
                    after: after) == .append)
        }
        for other in [manager.workspaceDrag(fixture.child.id), manager.collectionDrag(UUID())] {
            #expect(
                SidebarNavigationDropValidation.provider(from: [drag.itemProvider, other.itemProvider], target: heading)
                    == nil)
            let mixed = drag.itemProvider
            let type = other.typeIdentifier
            mixed.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { completion in
                completion(Data(), nil)
                return nil
            }
            #expect(SidebarNavigationDropValidation.provider(from: [mixed], target: heading) == nil)
        }
        #expect(
            SidebarNavigationDropValidation.typeIdentifier(
                hasWorkspace: false, hasCollection: false, hasText: true, hasProjectBlock: true, target: heading) == nil
        )
        #expect(SidebarNavigationDropValidation.provider(from: [drag.itemProvider], target: .ungrouped) == nil)
        let feedback = SidebarNavigationDropFeedback()
        feedback.beginProjectBlockDrag(drag)
        #expect(feedback.projectBlockDrag != nil)
        let region = UUID()
        feedback.enter(region, placement: .after)
        feedback.exit(region)
        #expect(feedback.projectBlockDrag != nil)
        feedback.end()
        #expect(feedback.projectBlockDrag == nil)
        #expect(feedback.destination == nil)
    }

    @Test
    func projectHeadingsWireSectionScopedDragAndExplicitMovement() throws {
        let source = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        source.contains(
            ".modifier(SidebarNavigationDropTarget(target: .project(project.id, collectionId: collectionId)))",
            "Project drop targets retain section identity")
        source.contains(
            "workspaceManager.projectBlockDrag(project.id, in: collectionId)",
            "Project heading drags capture section-local membership")
        source.contains(
            "dropFeedback.beginProjectBlockDrag(drag)",
            "hover validates the local Project payload without decoding providers")
        for offset in [-1, 1] {
            source.contains(
                "workspaceManager.moveProjectBlock(project.id, in: collectionId, offset: \(offset))",
                "explicit movement remains section-local")
            source.contains(
                ".disabled(!workspaceManager.canMoveProjectBlock(project.id, in: collectionId, offset: \(offset)))",
                "section boundaries disable movement")
        }
    }
}
