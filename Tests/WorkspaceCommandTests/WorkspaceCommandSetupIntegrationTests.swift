import Foundation
import Testing

@testable import Argus

@MainActor
@Suite(.serialized)
struct WorkspaceCommandSetupIntegrationTests {
    @Test
    func creationCheckpointsUngroupedPlacementAndRunsSetupWithoutNavigating() async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let selected = try #require(manager.selectedWorkspace)
        let tab = selected.activeTabId
        let pane = selected.activePanelId
        let collection = try #require(manager.createCollection(name: "Working"))
        #expect(manager.moveWorkspace(selected.id, toCollection: collection.id))
        let runtime = WorkspaceCommandRuntime(workspaceManager: manager)
        let result = try WorkspaceCommandCreateTests.created(
            await runtime.receive(.create(.init(base: selected.id.uuidString, branch: "cli-setup"))))
        let workspace = try #require(manager.workspaces.first { $0.id.uuidString == result.workspace.id })
        try await fixture.waitForRuns(1)
        let panel = try #require(manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        #expect(result.recordedBaseBranch)
        #expect(manager.collection(containing: workspace.id) == nil)
        #expect(manager.ungroupedWorkspaceIds.contains(workspace.id))
        #expect(manager.selectedWorkspaceId == selected.id)
        #expect(selected.activeTabId == tab)
        #expect(selected.activePanelId == pane)
        let snapshot = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(snapshot.workspaces.contains { $0.id == workspace.id && $0.projectId == fixture.project.id })
        #expect(snapshot.ungroupedWorkspaceIds.contains(workspace.id))
        #expect(await fixture.runner.requests.count == 1)
        let reused = try #require(
            await manager.addWorkspaceToProject(
                fixture.project.id, branchName: "cli-setup", createNewBranch: false, selectsNewWorkspace: false))
        #expect(manager.setupPanel(in: reused) == nil)
        #expect(await fixture.runner.requests.count == 1)
        #expect(manager.selectedWorkspaceId == selected.id)
        await fixture.remove()
    }

    @Test
    func changedConsentDuringCLICreationPreventsSetupExecution() async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let gate = try BoundedGitHookGate(
            root: fixture.directory.url, repository: fixture.repository, name: "cli-consent")
        defer { gate.release() }
        let runtime = WorkspaceCommandRuntime(workspaceManager: manager)
        let creation = Task {
            await runtime.receive(.create(.init(project: fixture.project.id.uuidString, branch: "cli-consent")))
        }
        try await gate.waitUntilStarted()
        try manager.setWorktreeSetupCommand("", for: fixture.project.id)
        gate.release()
        let result = try WorkspaceCommandCreateTests.created(await creation.value)
        let workspace = try #require(manager.workspaces.first { $0.id.uuidString == result.workspace.id })
        if let panel = manager.setupPanel(in: workspace) { try await fixture.waitForFinish(panel) }
        #expect(!gate.didTimeOut)
        #expect(await fixture.runner.requests.isEmpty)
        await fixture.remove()
    }

    @Test(arguments: [false, true])
    func staleCLICreationCleansOnlyUnclaimedRoots(claimed: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let project = fixture.project
        let gate = try BoundedGitHookGate(
            root: fixture.directory.url, repository: fixture.repository, name: "cli-stale")
        defer { gate.release() }
        let runtime = WorkspaceCommandRuntime(workspaceManager: manager)
        let creation = Task {
            await runtime.receive(.create(.init(project: project.id.uuidString, branch: "cli-stale")))
        }
        try await gate.waitUntilStarted()
        let path = manager.worktreeService.managedWorktreeBaseURL
            .appendingPathComponent(project.id.uuidString).appendingPathComponent("cli-stale").path
        let peer = claimed ? manager.addWorkspace(workingDirectory: path) : nil
        let selected = manager.selectedWorkspaceId
        // Model the initiating repository becoming unavailable while Git is suspended.
        manager.closingSetupProjectIDs.insert(project.id)
        gate.release()
        let rejection = WorkspaceCommandRejectionTests.rejection(await creation.value)
        #expect(rejection?.code == .workspaceCreationFailed)
        #expect(FileManager.default.fileExists(atPath: path) == claimed)
        #expect(manager.workspaces.allSatisfy { $0.branchName != "cli-stale" })
        if let peer { #expect(manager.workspaces.contains { $0 === peer }) }
        #expect(manager.selectedWorkspaceId == selected)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        #expect(await fixture.runner.requests.isEmpty)
        #expect(!gate.didTimeOut)
        manager.closingSetupProjectIDs.remove(project.id)
        await fixture.remove()
    }

    @Test
    func reservedPreparedRootRefusesCLIClaimWithoutDeletingOrRunningSetup() async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let selected = manager.selectedWorkspaceId
        let gate = try BoundedGitHookGate(
            root: fixture.directory.url, repository: fixture.repository, name: "cli-reserved")
        defer { gate.release() }
        let runtime = WorkspaceCommandRuntime(workspaceManager: manager)
        let creation = Task {
            await runtime.receive(.create(.init(project: fixture.project.id.uuidString, branch: "cli-reserved")))
        }
        try await gate.waitUntilStarted()
        let path = manager.worktreeService.managedWorktreeBaseURL
            .appendingPathComponent(fixture.project.id.uuidString).appendingPathComponent("cli-reserved").path
        let root = manager.canonicalPath(path)
        manager.worktreeDeletionRoots.insert(root)
        gate.release()
        let rejection = try #require(WorkspaceCommandRejectionTests.rejection(await creation.value))
        #expect(rejection.code == .workspaceCreationFailed)
        #expect(rejection.message.contains("being deleted"))
        #expect(manager.worktreeDeletionRoots == [root])
        #expect(manager.workspaces.allSatisfy { $0.branchName != "cli-reserved" })
        #expect(manager.selectedWorkspaceId == selected)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await fixture.runner.requests.isEmpty)
        #expect(!gate.didTimeOut)
        manager.worktreeDeletionRoots.remove(root)
        await fixture.remove()
    }
}
