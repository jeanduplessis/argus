import Foundation
import Testing

@testable import Argus

@Suite @MainActor
struct WorktreeSetupManagerTests {
    @Test(arguments: ["new", "existing", "stack"])
    func actuallyNewWorktreesRunOnceAfterCheckpoint(_ source: String) async throws {
        let fixture = try await SetupManagerFixture.make()
        if source == "existing" { try TestGit.run(["branch", "feature"], in: fixture.repository) }
        let workspace = try await fixture.workspace(
            newBranch: source != "existing", parent: source == "stack" ? "main" : nil)
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        try await fixture.waitForFinish(panel)
        #expect(await fixture.runner.requests.count == 1)
        #expect(workspace.panelOrder.count == 2)
        #expect(workspace.panels[workspace.panelOrder[0]] is TerminalPanel)
        #expect(workspace.activeTabId == panel.id)
        let snapshot = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: fixture.manager.sessionSnapshotURL))
        #expect(snapshot.workspaces.contains { $0.id == workspace.id })
        #expect(panel.outcome == .succeeded)
        fixture.manager.selectWorkspace(workspace.id)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.remove()
    }

    @Test
    func reuseMainAdoptionRestoreAndFailedCreationNeverRunAutomatically() async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        #expect(await fixture.runner.requests.isEmpty)
        let path = try await manager.worktreeService.createWorktree(
            projectId: fixture.project.id, repositoryPath: fixture.repository.path, branchName: "existing"
        )
        let workspace = try await fixture.workspace(branch: "existing", newBranch: false)
        #expect(manager.setupPanel(in: workspace) == nil)
        let resolution = try await manager.worktreeService.prepareWorktree(
            projectId: fixture.project.id, repositoryPath: fixture.repository.path, branchName: "existing",
            createNewBranch: false
        )
        #expect(resolution.reusedExistingWorktree)
        #expect(manager.canonicalPath(resolution.path) == manager.canonicalPath(path))
        let duplicate = try await fixture.workspace(branch: "existing", newBranch: false)
        #expect(manager.setupPanel(in: duplicate) == nil)
        let main = try #require(manager.workspaces.first { $0.workspaceType == .mainCheckout })
        manager.runWorktreeSetupAgain(in: main)
        if let panel = manager.setupPanel(in: main) { try await fixture.waitForFinish(panel) }
        let orphan = OrphanedWorktreeInfo(path: path, branchName: "existing", projectId: fixture.project.id)
        let adopted = try #require(manager.adoptOrphanedWorktree(orphan))
        #expect(manager.setupPanel(in: adopted) == nil)
        #expect(await manager.addWorkspaceToProject(fixture.project.id, branchName: "existing") == nil)
        #expect(manager.restoreSession(from: manager.makeSessionSnapshot()))
        #expect(manager.workspaces.allSatisfy { manager.setupPanel(in: $0) == nil })
        #expect(await fixture.runner.requests.isEmpty)
        await fixture.remove()
    }

    @Test(arguments: ["reused", "adopted", "restored"])
    func explicitRetryCanRunWithoutAutomaticExecution(_ source: String) async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let path = try await manager.worktreeService.createWorktree(
            projectId: fixture.project.id, repositoryPath: fixture.repository.path, branchName: "existing"
        )
        var workspace: Workspace
        if source == "adopted" {
            workspace = try #require(
                manager.adoptOrphanedWorktree(
                    .init(path: path, branchName: "existing", projectId: fixture.project.id)
                ))
        } else {
            workspace = try await fixture.workspace(branch: "existing", newBranch: false)
        }
        if source == "restored" {
            let id = workspace.id
            #expect(manager.restoreSession(from: manager.makeSessionSnapshot()))
            workspace = try #require(manager.workspaces.first { $0.id == id })
        }
        manager.showWorktreeSetup(in: workspace)
        #expect(await fixture.runner.requests.isEmpty)
        manager.runWorktreeSetupAgain(in: workspace)
        let panel = try #require(manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        #expect(panel.outcome == .succeeded)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.remove()
    }

    @Test(arguments: [WorktreeSetupOutcome.exited(9), .failedLaunch("fixture spawn failure"), .timedOut, .cancelled])
    func setupFailureRetainsWorkspaceAndOutput(_ outcome: WorktreeSetupOutcome) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(outcome: outcome)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        #expect(panel.outcome == outcome)
        #expect(panel.output == "fixture output")
        #expect(fixture.manager.workspaces.contains { $0 === workspace })
        #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory))
        await fixture.remove()
    }

    @Test
    func retryUsesCurrentCommandRejectsDuplicatesAndDoesNotRedirectSelection() async throws {
        let fixture = try await SetupManagerFixture.make()
        let workspace = try await fixture.workspace()
        let manager = fixture.manager
        let panel = try #require(manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        try manager.setWorktreeSetupCommand("printf changed", for: fixture.project.id)
        await fixture.runner.configure(hold: true)
        manager.runWorktreeSetupAgain(in: workspace)
        let generation = panel.generation
        manager.runWorktreeSetupAgain(in: workspace)
        try await fixture.waitForRuns(2)
        #expect(await fixture.runner.requests.map(\.command) == ["printf fixture", "printf changed"])
        #expect(panel.command == "printf changed")
        #expect(panel.generation == generation)
        let other = try #require(manager.addWorkspace())
        let otherTab = other.activeTabId
        await fixture.runner.emit("live update")
        await fixture.runner.configure()
        try await fixture.waitForFinish(panel)
        #expect(panel.output == "live update")
        #expect(manager.selectedWorkspaceId == other.id)
        #expect(other.activeTabId == otherTab)
        panel.publish(.init(text: "stale", truncated: false), generation: UUID())
        #expect(panel.output == "live update")
        await fixture.remove()
    }

    @Test(arguments: ["disable", "change", "root", "project"])
    func pendingRunRevalidatesConsentAndOwnership(_ change: String) async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let workspace = try await fixture.workspace()
        let manager = fixture.manager
        try manager.setWorktreeSetupCommand("printf captured", for: fixture.project.id)
        manager.runWorktreeSetupAgain(in: workspace)
        let panel = try #require(manager.setupPanel(in: workspace))
        switch change {
        case "disable": try manager.setWorktreeSetupCommand("", for: fixture.project.id)
        case "change": try manager.setWorktreeSetupCommand("printf different", for: fixture.project.id)
        case "root": workspace.currentDirectory = fixture.repository.path
        default: fixture.project.removeWorkspace(workspace.id)
        }
        try await fixture.waitForFinish(panel)
        #expect(await fixture.runner.requests.isEmpty)
        #expect(panel.outcome != .succeeded)
        await fixture.remove()
    }

    @Test
    func removedOwnershipDiscardsOutputAndUnregisteredRetryCannotLaunch() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        fixture.project.removeWorkspace(workspace.id)
        await fixture.runner.emit("stale owner output")
        #expect(panel.output != "stale owner output")
        #expect(await panel.stop())
        #expect(panel.outcome == .ownershipChanged)
        fixture.project.addWorkspace(workspace.id)
        try await fixture.manager.worktreeService.removeWorktree(
            repositoryPath: fixture.repository.path, worktreePath: workspace.currentDirectory
        )
        fixture.manager.runWorktreeSetupAgain(in: workspace)
        try await fixture.waitForFinish(panel)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.remove()
    }

    @Test
    func projectCommandRoundTripsAndRuntimeNeverPersists() async throws {
        let fixture = try await SetupManagerFixture.make(command: "  printf 'kept exactly'\n")
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        let snapshot = fixture.manager.makeSessionSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: data).reconciledForRestore()
        #expect(
            decoded.projects.first(where: { $0.id == fixture.project.id })?.worktreeSetupCommand
                == "  printf 'kept exactly'\n")
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("fixture output"))
        #expect(!json.contains(panel.id.uuidString))
        #expect(fixture.manager.restoreSession(from: decoded))
        #expect(fixture.manager.workspaces.allSatisfy { fixture.manager.setupPanel(in: $0) == nil })
        var legacy = fixture.project.snapshot()
        legacy.worktreeSetupCommand = nil
        let restored = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(legacy))
        #expect(restored.worktreeSetupCommand == nil)
        var catchAll = fixture.manager.catchAllProject.snapshot()
        catchAll.worktreeSetupCommand = "never"
        #expect(Project(snapshot: catchAll).worktreeSetupCommand == nil)
        let mixed = ArgusSessionSnapshot(
            selectedWorkspaceId: decoded.selectedWorkspaceId,
            projects: decoded.projects.filter { !$0.isCatchAll } + [catchAll], workspaces: decoded.workspaces
        ).reconciledForRestore()
        #expect(mixed.projects.first(where: \.isCatchAll)?.worktreeSetupCommand == nil)
        try fixture.manager.setWorktreeSetupCommand(" \n", for: fixture.project.id)
        let saved = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: fixture.manager.sessionSnapshotURL))
        #expect(saved.projects.first(where: { $0.id == fixture.project.id })?.worktreeSetupCommand == nil)
        await fixture.remove()
    }

    @Test
    func checkpointFailurePreventsExecutionAndSettingMutation() async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let manager = fixture.manager
        try FileManager.default.removeItem(at: manager.sessionSnapshotURL)
        try FileManager.default.createDirectory(at: manager.sessionSnapshotURL, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try manager.setWorktreeSetupCommand("printf not-run", for: fixture.project.id)
        }
        #expect(fixture.project.worktreeSetupCommand == nil)
        fixture.project.worktreeSetupCommand = "printf not-run"
        let workspace = try await fixture.workspace()
        #expect(manager.workspaces.contains { $0 === workspace })
        #expect(manager.setupPanel(in: workspace)?.outcome != nil)
        #expect(await fixture.runner.requests.isEmpty)
        await fixture.remove()
    }
}
