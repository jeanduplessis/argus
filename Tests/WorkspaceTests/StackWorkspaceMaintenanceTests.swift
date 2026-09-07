import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct StackWorkspaceMaintenanceTests {
    @Test
    func inspectionAndEditingUseActualBranchWithoutChangingSelectionOrTabs() async throws {
        let fixture = try StackWorkspaceFixture()
        let manager = fixture.manager
        manager.selectWorkspace(fixture.mainWorkspace.id)
        let selected = manager.selectedWorkspaceId
        let active = fixture.mainWorkspace.activeTabId
        let context = try await manager.inspectStackParent(for: fixture.parentWorkspace.id)
        #expect(context.branchName == fixture.repository.parentBranch)
        #expect(context.headCommitID == fixture.repository.parentCommit)
        #expect(fixture.parentWorkspace.branchName == "stale-label")
        let updated = try await manager.setStackParent("main", for: fixture.parentWorkspace.id, expected: context)
        #expect(updated.recordedParent == "main")
        #expect(manager.selectedWorkspaceId == selected)
        #expect(fixture.mainWorkspace.activeTabId == active)
        #expect(try await manager.inspectStackParent(for: fixture.parentWorkspace.id) == updated)
    }

    @Test
    func dependentCreationAttachesOneFreshWorkspaceAndCheckpointsItsSnapshot() async throws {
        let fixture = try StackWorkspaceFixture()
        try fixture.repository.makeDirtyParent()
        let manager = fixture.manager
        let expected = try await manager.inspectStackParent(for: fixture.parentWorkspace.id)
        let workspace = try await manager.addDependentWorkspace(
            to: fixture.project.id, parentWorkspaceID: fixture.parentWorkspace.id,
            newBranch: "feature/dependent", expectedParent: expected)
        #expect(workspace.workspaceType == .worktree)
        #expect(workspace.projectId == fixture.project.id)
        #expect(workspace.panelCount == 1)
        #expect(workspace.branchName == "feature/dependent")
        #expect(manager.workspaceIds(for: fixture.project).contains(workspace.id))
        #expect(manager.selectedWorkspaceId == workspace.id)
        let context = try await manager.inspectStackParent(for: workspace.id)
        #expect(context.headCommitID == fixture.repository.parentCommit)
        #expect(context.recordedParent == fixture.repository.parentBranch)
        let snapshot = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(snapshot.selectedWorkspaceId == workspace.id)
        #expect(snapshot.workspaces.contains { $0.id == workspace.id && $0.panelCount == 1 })
        #expect(snapshot.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))
    }

    @Test(arguments: [false, true])
    func selectionChangesDuringCreationArePreservedEvenWhenTheUserReturns(_ returnToParent: Bool) async throws {
        let gate = StackCommandGate()
        defer { gate.release() }
        let fixture = try StackWorkspaceFixture(runner: gatedAddRunner(gate))
        let manager = fixture.manager
        let expected = try await manager.inspectStackParent(for: fixture.parentWorkspace.id)
        let task = Task {
            try await manager.addDependentWorkspace(
                to: fixture.project.id, parentWorkspaceID: fixture.parentWorkspace.id,
                newBranch: "feature/dependent", expectedParent: expected)
        }
        try await gate.wait()
        manager.selectWorkspace(fixture.mainWorkspace.id)
        if returnToParent { manager.selectWorkspace(fixture.parentWorkspace.id) }
        let selected = manager.selectedWorkspaceId
        let active = manager.selectedWorkspace?.activeTabId
        gate.release()
        let created = try await task.value
        #expect(manager.workspaces.contains { $0.id == created.id })
        #expect(manager.selectedWorkspaceId == selected)
        #expect(manager.selectedWorkspace?.activeTabId == active)
        let snapshot = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(snapshot.selectedWorkspaceId == selected)
    }

    @Test(arguments: ["removed-project", "replaced-project", "removed-parent", "changed-root", "capacity"])
    func staleAttachmentRollsBackWithoutUsingForcedProjectCleanup(_ change: String) async throws {
        let gate = StackCommandGate()
        defer { gate.release() }
        let fixture = try StackWorkspaceFixture(runner: gatedAddRunner(gate))
        let manager = fixture.manager
        let expected = try await manager.inspectStackParent(for: fixture.parentWorkspace.id)
        let configuration = try Data(contentsOf: fixture.repository.configurationURL)
        let task = Task {
            try await manager.addDependentWorkspace(
                to: fixture.project.id, parentWorkspaceID: fixture.parentWorkspace.id,
                newBranch: "feature/dependent", expectedParent: expected)
        }
        try await gate.wait()
        switch change {
        case "removed-project": manager.projects.removeAll { $0.id == fixture.project.id }
        case "replaced-project":
            let replacement = Project(snapshot: fixture.project.snapshot())
            manager.projects = manager.projects.map { $0.id == fixture.project.id ? replacement : $0 }
        case "removed-parent": manager.removeWorkspaceFromState(fixture.parentWorkspace.id)
        case "changed-root": fixture.parentWorkspace.currentDirectory = fixture.repository.root.path
        default:
            while manager.workspaces.count < WorkspaceManager.maxWorkspaces {
                let workspace = Workspace(title: "Existing", workingDirectory: fixture.repository.root.path)
                manager.workspaces.append(workspace)
                manager.appendPlacement(workspace.id, to: nil)
            }
        }
        let count = manager.workspaces.count
        gate.release()
        await #expect(throws: StackParentError.self) { try await task.value }
        #expect(manager.workspaces.count == count)
        try fixture.repository.expectNoDependent()
        #expect(try Data(contentsOf: fixture.repository.configurationURL) == configuration)
        #expect(FileManager.default.fileExists(atPath: fixture.repository.parent.path))
        #expect(fixture.repository.branchExists(fixture.repository.parentBranch))
    }

    @Test
    func refusesStandaloneAndCrossWorkspaceExpectedContexts() async throws {
        let fixture = try StackWorkspaceFixture()
        let manager = fixture.manager
        let standalone = try #require(manager.workspaces.first { $0.workspaceType == .external })
        await #expect(throws: StackParentError.workspaceUnavailable) {
            try await manager.inspectStackParent(for: standalone.id)
        }
        let expected = try await manager.inspectStackParent(for: fixture.mainWorkspace.id)
        await #expect(throws: StackParentError.contextChanged) {
            try await manager.addDependentWorkspace(
                to: fixture.project.id, parentWorkspaceID: fixture.parentWorkspace.id,
                newBranch: "feature/dependent", expectedParent: expected)
        }
        try fixture.repository.expectNoDependent()
    }

    private func gatedAddRunner(_ gate: StackCommandGate) -> StackGitTestRunner {
        let once = StackTestOneShot()
        return StackGitTestRunner { arguments, _, phase in
            guard phase == .before, arguments.contains("worktree"), arguments.contains("add"), once.take() else {
                return nil
            }
            try gate.stop()
            return nil
        }
    }
}

@MainActor
private final class StackWorkspaceFixture {
    let repository: StackMaintenanceFixture
    let manager: WorkspaceManager
    let project: Project
    let parentWorkspace: Workspace
    let mainWorkspace: Workspace
    let defaults: UserDefaults
    let suiteName: String

    init(runner: any StackGitCommandRunning = StackGitProcessRunner()) throws {
        let repository = try StackMaintenanceFixture()
        self.repository = repository
        suiteName = "ArgusTests.StackWorkspace.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let settings = AppSettings(defaults: defaults)
        settings.defaultStandaloneWorkspaceDirectory = repository.root.path
        manager = WorkspaceManager(
            settings: settings, sessionSnapshotURL: repository.root.appendingPathComponent("session.json"),
            environment: ["ARGUS_UNDER_TEST": "1"], worktreeService: repository.worktreeService(runner: runner))
        project = Project(repositoryPath: repository.repository.path, mainBranch: "main")
        mainWorkspace = Workspace(
            title: "Main", workingDirectory: repository.repository.path,
            projectId: project.id, branchName: "main", workspaceType: .mainCheckout)
        parentWorkspace = Workspace(
            title: "Parent", workingDirectory: repository.parent.path,
            projectId: project.id, branchName: "stale-label", workspaceType: .worktree,
            worktreePath: repository.parent.path)
        manager.projects.insert(project, at: 0)
        manager.workspaces.append(contentsOf: [mainWorkspace, parentWorkspace])
        manager.appendPlacement(mainWorkspace.id, to: nil)
        manager.appendPlacement(parentWorkspace.id, to: nil)
        manager.selectWorkspace(parentWorkspace.id)
    }

    deinit { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
}
