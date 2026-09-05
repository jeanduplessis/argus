import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ProjectCollectionTests {
    @Test
    func mixedPlacementRepeatsRepositoryHeadingsWithoutDuplicatingContent() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let other = addWorkspaces(to: fixture)[0]
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let first = try #require(manager.createCollection(name: "  Client Work  "))
        let second = try #require(manager.createCollection(name: "Personal"))
        #expect(first.name == "Client Work")
        #expect(manager.moveWorkspace(fixture.child.id, toCollection: first.id))
        #expect(manager.moveWorkspace(other.id, toCollection: first.id))
        #expect(manager.moveWorkspace(standalone.id, toCollection: first.id))
        #expect(manager.moveWorkspace(fixture.parent.id, toCollection: second.id))
        let sections = manager.navigationSections
        #expect(sections[0].blocks.map(\.project?.id) == [fixture.project.id, other.projectId, nil])
        #expect(sections[1].blocks.first?.project === fixture.project)
        #expect(Set(sections.flatMap(\.workspaceIds)).count == manager.workspaces.count)
        #expect(sections.flatMap(\.workspaceIds).count == manager.workspaces.count)
        #expect(standalone.projectId == nil)
        #expect(manager.project(for: fixture.child.id) === fixture.project)
        #expect(manager.renameCollection(first.id, name: "Client aPI"))
        #expect(manager.moveCollection(second.id, offset: -1))
        let oldUngrouped = manager.ungroupedWorkspaceIds
        manager.removeCollection(first.id)
        #expect(manager.ungroupedWorkspaceIds == oldUngrouped + [fixture.child.id, other.id, standalone.id])
        #expect(manager.collections.first?.id == second.id)
        #expect(manager.workspaces.contains { $0 === standalone })
    }

    @Test
    func organizationPreservesSelectionPanelsAttentionFilesAndSharedRuntime() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let terminal = try #require(fixture.child.addTerminalPanel(workingDirectory: fixture.root.path))
        let selected = manager.selectedWorkspaceId
        let workspaceIds = manager.workspaces.map(\.id)
        let path = fixture.root.appendingPathComponent("uncommitted.txt")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("Uncommitted work".utf8).write(to: path)
        let attention = TurnCompletionAttentionStore()
        let target = TurnCompletionAttentionTarget(workspaceId: fixture.child.id, tabId: terminal.id)
        _ = attention.record(agentKey: "test", eventId: "done", target: target, isViewed: false)
        manager.setTurnCompletionRuntime(
            TurnCompletionRuntime(
                workspaceManager: manager, attentionStore: attention, isMainWindowKey: { false }))
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        manager.moveWorkspace(fixture.child.id, toCollection: first.id)
        manager.toggleCollection(first.id)
        manager.renameCollection(first.id, name: "Renamed")
        manager.moveWorkspace(fixture.child.id, toCollection: second.id)
        manager.removeCollection(first.id)
        manager.removeCollection(second.id)
        #expect(manager.selectedWorkspaceId == selected)
        #expect(manager.workspaces.map(\.id) == workspaceIds)
        #expect(fixture.child.activePanelId == terminal.id)
        #expect(fixture.child.panels[terminal.id] === terminal)
        #expect(attention.attentionTargets == [target])
        #expect(try Data(contentsOf: path) == Data("Uncommitted work".utf8))
        #expect(manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshot)
        #expect(manager.project(for: fixture.child.id) === fixture.project)
    }

    @Test
    func invalidActionsAndLimitsLeavePlacementUnchanged() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let original = fixture.manualOrder
        let collection = try #require(manager.createCollection(name: "Work"))
        #expect(!manager.moveWorkspace(UUID(), toCollection: collection.id))
        #expect(!manager.moveWorkspace(fixture.child.id, toCollection: UUID()))
        #expect(!manager.moveWorkspace(fixture.child.id, toCollection: collection.id, at: -1))
        #expect(!manager.moveCollection(collection.id, offset: -1))
        #expect(!manager.renameCollection(collection.id, name: " \n"))
        #expect(manager.createCollection(name: String(repeating: "x", count: 4097)) == nil)
        for index in 1..<128 { #expect(manager.createCollection(name: "Empty \(index)") != nil) }
        #expect(manager.createCollection(name: "Too many") == nil)
        #expect(manager.collections.count == 128)
        #expect(manager.ungroupedWorkspaceIds == original)
    }

    @Test
    func splitStackKeepsLocalHeadersReferencesParentAndIndependentDisclosure() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        manager.moveWorkspace(fixture.parent.id, toCollection: first.id)
        manager.moveWorkspace(fixture.child.id, toCollection: second.id)
        let parentGroup = try #require(manager.stackGroup(for: fixture.parent.id, in: fixture.project.id))
        let childGroup = try #require(manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        #expect(parentGroup.id == childGroup.id)
        #expect(parentGroup.workspaceIds == [fixture.parent.id])
        #expect(childGroup.workspaceIds == [fixture.child.id])
        #expect(childGroup.rows.first?.workspaceIsElsewhere == true)
        #expect(childGroup.rows.first?.workspaceId == nil)
        #expect(parentGroup.newWorkspaceParentBranch == "feature/parent")
        #expect(childGroup.newWorkspaceParentBranch == "feature/child")
        let order = fixture.orderedIds
        manager.toggleWorkspaceStack(parentGroup.id, in: fixture.project.id, collectionId: first.id)
        manager.toggleWorkspaceStack(childGroup.id, in: fixture.project.id, collectionId: second.id)
        manager.toggleRepository(fixture.project.id, in: first.id)
        manager.toggleRepository(fixture.project.id, in: second.id)
        manager.toggleCollection(first.id)
        manager.toggleCollection(second.id)
        #expect(fixture.orderedIds == order)
        manager.selectWorkspace(fixture.child.id)
        manager.selectWorkspace(fixture.child.id)
        #expect(manager.collections[0].isExpanded == false)
        #expect(manager.collections[1].isExpanded)
        #expect(!manager.repositoryDisclosure(for: fixture.project.id, in: first.id).isExpanded)
        #expect(manager.repositoryDisclosure(for: fixture.project.id, in: second.id).isExpanded)
        #expect(
            manager.repositoryDisclosure(for: fixture.project.id, in: first.id).collapsedStackIds == [parentGroup.id])
        #expect(manager.repositoryDisclosure(for: fixture.project.id, in: second.id).collapsedStackIds.isEmpty)
        manager.handleWorkspaceShortcut(number: 1)
        #expect(manager.selectedWorkspaceId == fixture.parent.id)
        manager.selectNextWorkspace()
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        manager.removeWorkspace(fixture.child.id)
        #expect(manager.selectedWorkspaceId == fixture.ordinary.id)
        #expect(manager.collections[1].workspaceIds.isEmpty)
    }

    @Test
    func collapsingCollectionCancelsDelayedRevealButNotDiscovery() async throws {
        let reader = ControlledWorkspaceStackReader()
        let fixture = try WorkspaceStackTestFixture(reader: reader)
        defer {
            fixture.cleanup()
            reader.cancelAll()
        }
        let manager = fixture.manager
        await reader.startAndLoad(fixture)
        let collection = try #require(manager.createCollection(name: "Work"))
        let workspace = try fixture.adoptGapWorkspace(collectionId: collection.id)
        await waitForStackState { reader.requests.count == 3 }
        let revision = manager.workspaceRevealRevision
        manager.toggleCollection(collection.id)
        #expect(manager.pendingWorkspaceStackReveal == nil)
        reader.complete(2, with: .success(fixture.snapshotIncludingGap))
        await waitForStackState { manager.workspaceStackSnapshots[fixture.project.id] == fixture.snapshotIncludingGap }
        #expect(manager.collections.first?.isExpanded == false)
        #expect(manager.selectedWorkspaceId == workspace.id)
        #expect(manager.workspaceRevealRevision == revision)
        #expect(manager.isObservingWorkspaceStacks)
    }
}

extension ProjectCollectionTests {
    @Test
    func projectCreationAppendsToCollapsedCollectionAndPersistsSelectionAndReveal() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let members = addWorkspaces(to: fixture)
        let repository = try makeRepository(in: fixture)
        let other = try #require(manager.createCollection(name: "Client"))
        let destination = try #require(manager.createCollection(name: "Client"))
        manager.moveWorkspace(members[1].id, toCollection: other.id)
        manager.moveWorkspace(members[2].id, toCollection: destination.id)
        manager.moveWorkspace(members[0].id, toCollection: destination.id)
        manager.toggleCollection(destination.id)
        let previousWorkspaceCount = manager.workspaces.count
        let revision = manager.workspaceRevealRevision

        let project = try #require(
            await manager.createProject(
                repositoryPath: repository.path, displayName: "New Client", collectionId: destination.id))
        let workspace = try #require(manager.selectedWorkspace)
        let memberIds = [members[2].id, members[0].id, workspace.id]
        #expect(manager.manualWorkspaceIds(in: destination.id) == memberIds)
        #expect(manager.manualWorkspaceIds(in: other.id) == [members[1].id])
        #expect(!manager.ungroupedWorkspaceIds.contains(workspace.id))
        #expect(manager.collections.last?.isExpanded == true)
        #expect(manager.repositoryDisclosure(for: project.id, in: destination.id).isExpanded)
        #expect(project.displayName == "New Client")
        #expect(project.mainBranch == "main")
        #expect(manager.workspaces.count == previousWorkspaceCount + 1)
        #expect(workspace.workspaceType == .mainCheckout)
        #expect(workspace.projectId == project.id)
        #expect(workspace.currentDirectory == repository.resolvingSymlinksInPath().path)
        #expect(manager.workspaceIds(for: project) == [workspace.id])
        #expect(workspace.panels.count == 1)
        #expect(workspace.panelOrder.count == 1)
        #expect(manager.workspaceRevealRevision == revision + 1)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(saved.collections?.last?.workspaceIds == memberIds)
        #expect(saved.collections?.last?.isExpanded == true)
        #expect(saved.selectedWorkspaceId == workspace.id)
        #expect(manager.restoreSession(from: saved))
        #expect(manager.collections.last?.workspaceIds == memberIds)
        #expect(manager.collections.last?.isExpanded == true)
        #expect(manager.selectedWorkspaceId == workspace.id)
    }

    @Test(arguments: [false, true])
    func projectCreationWithNilDestinationRemainsUngrouped(hasCollection: Bool) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let repository = try makeRepository(in: fixture)
        if hasCollection {
            let collection = try #require(manager.createCollection(name: "Work"))
            manager.moveWorkspace(fixture.child.id, toCollection: collection.id)
            manager.toggleCollection(collection.id)
        }
        let collections = manager.collections
        let project = try #require(await manager.createProject(repositoryPath: repository.path, collectionId: nil))
        #expect(manager.selectedWorkspace.map { manager.ungroupedWorkspaceIds.contains($0.id) } == true)
        #expect(manager.collection(containing: manager.selectedWorkspaceId!) == nil)
        #expect(manager.selectedWorkspace?.projectId == project.id)
        #expect(manager.collections == collections)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(saved.collections ?? [] == collections)
    }

    @Test(arguments: [false, true])
    func projectCreationRejectsUnknownOrRemovedDestination(wasRemoved: Bool) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let repository = try makeRepository(in: fixture)
        let collection = try #require(manager.createCollection(name: "Work"))
        let destinationId = wasRemoved ? collection.id : UUID()
        if wasRemoved {
            manager.removeCollection(collection.id)
            #expect(manager.createCollection(name: "Work") != nil)
        }
        let projectIds = manager.projects.map(\.id)
        let workspaceIds = manager.workspaces.map(\.id)
        let selection = manager.selectedWorkspaceId
        let collections = manager.collections
        let saved = try Data(contentsOf: manager.sessionSnapshotURL)

        #expect(await manager.createProject(repositoryPath: repository.path, collectionId: destinationId) == nil)
        #expect(manager.projects.map(\.id) == projectIds)
        #expect(manager.workspaces.map(\.id) == workspaceIds)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.collections == collections)
        #expect(try Data(contentsOf: manager.sessionSnapshotURL) == saved)
    }

    @Test
    func destinationRemovedDuringGitReadsDoesNotCreateAnUngroupedProject() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let repository = try makeRepository(in: fixture)
        let collection = try #require(manager.createCollection(name: "Work"))
        let projectIds = manager.projects.map(\.id)
        let workspaceIds = manager.workspaces.map(\.id)
        let selection = manager.selectedWorkspaceId
        // This MainActor task cannot run until creation suspends for its Git reads.
        let removal = Task { @MainActor in
            manager.removeCollection(collection.id)
            manager.createCollection(name: "Work")
        }
        let project = await manager.createProject(repositoryPath: repository.path, collectionId: collection.id)
        await removal.value
        #expect(project == nil)
        #expect(manager.projects.map(\.id) == projectIds)
        #expect(manager.workspaces.map(\.id) == workspaceIds)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.collections.first?.id != collection.id)
        #expect(manager.collections.first?.workspaceIds.isEmpty == true)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(saved.projects.map(\.id) == projectIds)
        #expect(saved.workspaces.map(\.id) == workspaceIds)
    }

    @Test
    func collectionDestinationPreservesDuplicateAndNonRepositoryRejection() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let repository = try makeRepository(in: fixture)
        let project = try #require(await manager.createProject(repositoryPath: repository.path))
        let collection = try #require(manager.createCollection(name: "Work"))
        let childDirectory = repository.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let projectIds = manager.projects.map(\.id)
        let workspaceIds = manager.workspaces.map(\.id)
        let saved = try Data(contentsOf: manager.sessionSnapshotURL)
        for path in [childDirectory.path, fixture.root.path] {
            #expect(await manager.createProject(repositoryPath: path, collectionId: collection.id) == nil)
        }
        #expect(manager.projects.map(\.id) == projectIds)
        #expect(manager.workspaces.map(\.id) == workspaceIds)
        #expect(manager.selectedWorkspace?.projectId == project.id)
        #expect(manager.collections.first?.workspaceIds.isEmpty == true)
        #expect(try Data(contentsOf: manager.sessionSnapshotURL) == saved)
    }

    private func makeRepository(in fixture: WorkspaceStackTestFixture) throws -> URL {
        let repository = fixture.root.appendingPathComponent("new-repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repository)
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "initial"
            ], in: repository, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        return repository
    }

    private func addWorkspaces(to fixture: WorkspaceStackTestFixture) -> [Workspace] {
        (1...3).map { index in
            let project = Project(
                repositoryPath: fixture.root.appendingPathComponent("project-\(index)").path,
                mainBranch: "main")
            let workspace = Workspace(
                snapshot: WorkspaceSnapshot(
                    id: UUID(), projectId: project.id,
                    branchName: "main", workspaceType: .mainCheckout, worktreePath: nil,
                    title: "Project \(index)", customTitle: nil, currentDirectory: project.repositoryPath, panelCount: 0
                ))
            fixture.manager.projects.append(project)
            fixture.manager.workspaces.append(workspace)
            fixture.manager.appendPlacement(workspace.id, to: nil)
            return workspace
        }
    }
}
