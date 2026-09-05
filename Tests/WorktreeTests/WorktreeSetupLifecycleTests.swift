// Keep close-scope and shared-root integration coverage together.
// swiftlint:disable file_length
import Foundation
import Testing

@testable import Argus

@Suite @MainActor
struct WorktreeSetupLifecycleTests {
    @Test(arguments: [false, true])
    func sharedRootDeletionRefusesRunningPeer(_ useAlias: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let duplicate = try await fixture.workspace(newBranch: false)
        if useAlias {
            let alias = fixture.directory.url.appendingPathComponent("worktree-alias")
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: owner.currentDirectory)
            duplicate.worktreePath = alias.path
            duplicate.currentDirectory = alias.path
            fixture.manager.runWorktreeSetupAgain(in: duplicate)
            try await fixture.waitForRuns(2)
        }
        let manager = fixture.manager
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        manager.moveWorkspace(owner.id, toCollection: first.id)
        manager.moveWorkspace(duplicate.id, toCollection: second.id)
        #expect(await !manager.removeWorkspace(duplicate.id, deletingWorktree: true))
        #expect(FileManager.default.fileExists(atPath: owner.currentDirectory))
        #expect(manager.workspaces.contains { $0 === duplicate })
        #expect(owner.worktreeSetupPanel?.isRunning == true)
        #expect(await !fixture.runner.rootExistedAtStop)
        #expect(await fixture.runner.stopRequests == 0)
        #expect(manager.lastWorkspaceDeletionError?.localizedDescription.contains("Stop Worktree Setup") == true)
        await fixture.remove()
    }

    @Test
    func tabCloseConfirmsAndCancelPreservesRunThenConfirmedCloseAwaitsStop() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        let recorder = SetupCloseRecorder()
        fixture.manager.requestCloseTab(panel.id, in: workspace.id)
        #expect(recorder.request?.scope == .tab(workspaceId: workspace.id, tabId: panel.id))
        #expect(recorder.request?.includesWorktreeSetup == true)
        // Dismissing the confirmation makes no manager call.
        #expect(panel.isRunning)
        #expect(workspace.activeTabId == panel.id)
        #expect(workspace.runningProcessCount == 0)
        #expect(workspace.runningSetupCount == 1)
        workspace.closeTab(panel.id)  // Lower-level teardown cannot abandon a live task either.
        #expect(workspace.panels[panel.id] != nil)
        fixture.manager.requestCloseTab(panel.id, in: workspace.id, confirmingRunningProcess: true)
        for _ in 0..<300 where workspace.panels[panel.id] != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(workspace.panels[panel.id] == nil)
        #expect(workspace.worktreeSetupPanel === panel)
        #expect(!panel.isRunning)
        #expect(workspace.panelOrder.count == 1)
        #expect(await fixture.runner.rootExistedAtStop)
        #expect(fixture.manager.workspaces.contains { $0 === workspace })
        await fixture.remove()
    }

    @Test
    func closedLogReopensWithoutRerunAndIsReleasedWithWorkspace() async throws {
        let fixture = try await SetupManagerFixture.make()
        let workspace = try await fixture.workspace()
        let manager = fixture.manager
        let panel = try #require(manager.setupPanel(in: workspace))
        try await fixture.waitForFinish(panel)
        manager.requestCloseTab(panel.id, in: workspace.id)
        #expect(workspace.panels[panel.id] == nil)
        #expect(workspace.worktreeSetupPanel === panel)
        #expect(!panel.isRunning)
        #expect(panel.output == "fixture output")
        manager.showWorktreeSetup(in: workspace)
        manager.showWorktreeSetup(in: workspace)
        #expect(workspace.panels[panel.id] as? WorktreeSetupPanel === panel)
        #expect(workspace.panelOrder.filter { $0 == panel.id }.count == 1)
        #expect(panel.outcome == .succeeded)
        #expect(await fixture.runner.requests.count == 1)
        let data = try JSONEncoder().encode(manager.makeSessionSnapshot())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("fixture output"))
        #expect(!json.contains(panel.id.uuidString))
        #expect(await manager.removeWorkspace(workspace.id, deletingWorktree: false))
        #expect(workspace.worktreeSetupPanel == nil)
        await fixture.remove()
    }

    @Test(arguments: [false, true])
    func workspaceCloseCombinesConfirmationAndStopsBeforeDeletion(_ deleting: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        let recorder = SetupCloseRecorder()
        fixture.manager.requestCloseWorkspace(workspace.id)
        #expect(recorder.workspaceID == workspace.id)
        #expect(fixture.manager.shouldConfirmRunningProcessBeforeClosingWorkspace(workspace.id))
        #expect(panel.isRunning)
        #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory))
        #expect(await fixture.manager.removeWorkspace(workspace.id, deletingWorktree: deleting))
        #expect(await fixture.runner.rootExistedAtStop)
        #expect(!panel.isRunning)
        #expect(!fixture.manager.workspaces.contains { $0 === workspace })
        #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory) == !deleting)
        await fixture.remove()
    }

    @Test
    func failedStopRetainsTaskAndDirectoryAndCanRetryCleanup() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true, failsStop: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        #expect(await !fixture.manager.removeWorkspace(workspace.id, deletingWorktree: true))
        #expect(fixture.manager.worktreeDeletionRoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory))
        #expect(fixture.manager.workspaces.contains { $0 === workspace })
        #expect(panel.isRunning)
        #expect(!panel.terminationConfirmed)
        fixture.manager.runWorktreeSetupAgain(in: workspace)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.runner.configure()
        #expect(await fixture.manager.removeWorkspace(workspace.id, deletingWorktree: true))
        #expect(!FileManager.default.fileExists(atPath: workspace.currentDirectory))
        #expect(!panel.isRunning)
        await fixture.remove()
    }

    @Test
    func duplicateRetryCannotPublishCheckpointFailureOverARunningTask() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        try FileManager.default.removeItem(at: fixture.manager.sessionSnapshotURL)
        try FileManager.default.createDirectory(
            at: fixture.manager.sessionSnapshotURL, withIntermediateDirectories: true)
        fixture.manager.runWorktreeSetupAgain(in: workspace)
        #expect(panel.isRunning)
        #expect(panel.outcome == nil)
        #expect(await fixture.runner.requests.count == 1)
        #expect(await fixture.manager.removeWorkspace(workspace.id, deletingWorktree: true))
        #expect(await fixture.runner.rootExistedAtStop)
        await fixture.remove()
    }

    @Test
    func projectRemovalStopsEverySetupBeforeDeletingAnyWorktree() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        await fixture.manager.removeProject(fixture.project.id)
        #expect(await fixture.runner.rootExistedAtStop)
        #expect(!panel.isRunning)
        #expect(!FileManager.default.fileExists(atPath: workspace.currentDirectory))
        #expect(fixture.manager.namedProjects.isEmpty)
        await fixture.remove()
    }

    @Test
    func failedProjectStopRetainsEveryWorkspaceAndWorktree() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true, failsStop: true)
        let first = try await fixture.workspace(branch: "first")
        let second = try await fixture.workspace(branch: "second")
        try await fixture.waitForRuns(2)
        let projectID = fixture.project.id
        await fixture.manager.removeProject(projectID)
        #expect(fixture.manager.worktreeDeletionRoots.isEmpty)
        #expect(fixture.manager.projects.contains { $0.id == projectID })
        for workspace in [first, second] {
            #expect(fixture.manager.workspaces.contains { $0 === workspace })
            #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory))
        }
        await fixture.remove()
    }

    @Test
    func applicationStopUsesSeparateCountsLocationsAndDisablesNewRuns() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let workspace = try await fixture.workspace()
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await fixture.waitForRuns(1)
        #expect(fixture.manager.totalRunningProcessCount == 0)
        #expect(fixture.manager.totalRunningSetupCount == 1)
        let locations = fixture.manager.runningProcessLocations()
        #expect(locations.count == 1)
        #expect(locations.first?.workspaceId == workspace.id)
        #expect(locations.first?.label.contains(fixture.project.displayName) == true)
        #expect(await fixture.manager.stopAllWorktreeSetups())
        #expect(!panel.isRunning)
        #expect(!fixture.manager.canRunWorktreeSetup(in: workspace))
        fixture.manager.runWorktreeSetupAgain(in: workspace)
        #expect(await fixture.runner.requests.count == 1)
        #expect(FileManager.default.fileExists(atPath: workspace.currentDirectory))
        await fixture.remove()
    }

    @Test
    func setupSheetAndQuitPathsUseNativePresentationAndAwaitedTermination() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/WorktreeSetupSheet.swift")
        sheet.containsAll(
            [
                "TextEditor(text: $command)", "fork Pull Requests", "Noninteractive", "Button(\"Cancel\")",
                "Button(\"Save\")"
            ], "explicit local setup consent")
        let view = try SourceContract("Argus/Views/Content/WorktreeSetupPanelView.swift")
        view.containsAll(
            [
                ".textSelection(.enabled)", "ChromeColors.contentBackground", "Button(\"Stop\")",
                "Button(\"Run Setup Again\")"
            ], "in-tab setup controls")
        view.excludes("NSWindow", "No separate setup content window")
        let delegate = try SourceContract("Argus/App/AppDelegate.swift")
        delegate.containsAll(
            [
                "workspaceManager?.totalRunningSetupCount", "await workspaceManager?.stopAllWorktreeSetups()",
                "return .terminateLater", "allowMainWindowClose()"
            ], "application and window close share setup guard")
        let projectMenu = try SourceContract("Argus/Views/Sidebar/SidebarView+Projects.swift")
        projectMenu.excludes("removeProject(", "Local repository headings cannot close global repository scope")
        projectMenu.excludes("confirmProjectRemoval", "Local headings do not authorize global deletion")
    }
}

extension WorktreeSetupLifecycleTests {
    @Test(arguments: [false, true])
    func adoptionDuringProjectOrApplicationStopIsRejected(_ shutdown: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        _ = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let manager = fixture.manager
        let projectID = fixture.project.id
        let orphanPath = try await manager.worktreeService.createWorktree(
            projectId: projectID, repositoryPath: fixture.repository.path, branchName: "orphan"
        )
        await fixture.runner.holdStops()
        let closing = Task {
            if shutdown { _ = await manager.stopAllWorktreeSetups() } else { await manager.removeProject(projectID) }
        }
        try await fixture.waitForStops(1)
        let ids = manager.workspaces.map(\.id)
        let selection = manager.selectedWorkspaceId
        #expect(
            manager.adoptOrphanedWorktree(
                .init(
                    path: orphanPath, branchName: "orphan", projectId: projectID
                )) == nil)
        #expect(manager.workspaces.map(\.id) == ids)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(FileManager.default.fileExists(atPath: orphanPath))
        #expect(await fixture.runner.requests.count == 1)
        await fixture.runner.releaseStops()
        await closing.value
        #expect(FileManager.default.fileExists(atPath: orphanPath))
        await fixture.remove()
    }

    @Test(arguments: [false, true])
    func peerChecksUseCapturedRootIncludingUnconfirmedCleanup(_ unconfirmed: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true, failsStop: unconfirmed)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let duplicate = try await fixture.workspace(newBranch: false)
        let panel = try #require(owner.worktreeSetupPanel)
        let capturedRoot = try #require(panel.owner?.rootPath)
        if unconfirmed { #expect(await !panel.stop()) }
        let stopCount = await fixture.runner.stopRequests
        owner.worktreePath = fixture.repository.path
        owner.currentDirectory = fixture.repository.path
        #expect(await !fixture.manager.removeWorkspace(duplicate.id, deletingWorktree: true))
        #expect(FileManager.default.fileExists(atPath: capturedRoot))
        #expect(await fixture.runner.stopRequests == stopCount)
        #expect(panel.isRunning)
        #expect(fixture.manager.worktreeDeletionRoots.isEmpty)
        await fixture.remove()
    }

    @Test
    func projectDeletionRefusesOutsideProjectPeerBeforeStoppingAnyScopedTask() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let manager = fixture.manager
        let project = try await fixture.addProject(name: "other-project")
        try manager.setWorktreeSetupCommand("printf fixture", for: project.id)
        let scoped = try #require(await manager.addWorkspaceToProject(project.id, branchName: "scoped"))
        _ = try #require(
            manager.adoptOrphanedWorktree(
                .init(
                    path: owner.currentDirectory, branchName: "shared", projectId: project.id
                )))
        try await fixture.waitForRuns(2)
        let ids = manager.workspaces.map(\.id)
        await manager.removeProject(project.id)
        #expect(manager.workspaces.map(\.id) == ids)
        #expect(manager.projects.contains { $0 === project })
        #expect(owner.worktreeSetupPanel?.isRunning == true)
        #expect(scoped.worktreeSetupPanel?.isRunning == true)
        #expect(await fixture.runner.stopRequests == 0)
        #expect(FileManager.default.fileExists(atPath: owner.currentDirectory))
        #expect(FileManager.default.fileExists(atPath: scoped.currentDirectory))
        #expect(manager.lastWorkspaceDeletionError?.localizedDescription.contains("Stop Worktree Setup") == true)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        #expect(manager.closingSetupProjectIDs.isEmpty)
        await fixture.remove()
    }

    @Test
    func closeWithoutDeletionStopsOnlyTargetWhenBothShareRoot() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let duplicate = try await fixture.workspace(newBranch: false)
        fixture.manager.runWorktreeSetupAgain(in: duplicate)
        try await fixture.waitForRuns(2)
        let targetPanel = try #require(duplicate.worktreeSetupPanel)
        #expect(await fixture.manager.removeWorkspace(duplicate.id, deletingWorktree: false))
        #expect(!targetPanel.isRunning)
        #expect(owner.worktreeSetupPanel?.isRunning == true)
        #expect(await fixture.runner.stopRequests == 1)
        #expect(FileManager.default.fileExists(atPath: owner.currentDirectory))
        #expect(fixture.manager.worktreeDeletionRoots.isEmpty)
        await fixture.remove()
    }

    @Test
    func projectScopeStopsBothSharedRootRunsBeforeDeleting() async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let duplicate = try await fixture.workspace(newBranch: false)
        fixture.manager.runWorktreeSetupAgain(in: duplicate)
        try await fixture.waitForRuns(2)
        let manager = fixture.manager
        let projectId = fixture.project.id
        let scopedIds = Set(manager.workspaceIds(for: fixture.project))
        let first = try #require(manager.createCollection(name: "First"))
        let second = try #require(manager.createCollection(name: "Second"))
        manager.moveWorkspace(owner.id, toCollection: first.id)
        manager.moveWorkspace(duplicate.id, toCollection: second.id)
        let peerProject = try await fixture.addProject(name: "unaffected")
        let peer = try #require(manager.selectedWorkspace)
        let peerPanels = peer.panelOrder
        manager.moveWorkspace(peer.id, toCollection: first.id)
        await manager.removeProject(projectId)
        #expect(await fixture.runner.stopRequests == 2)
        #expect(await fixture.runner.rootExistedAtStop)
        #expect(!FileManager.default.fileExists(atPath: owner.currentDirectory))
        #expect(manager.worktreeDeletionRoots.isEmpty)
        #expect(manager.lastWorkspaceDeletionError == nil)
        #expect(!manager.projects.contains { $0.id == projectId })
        #expect(manager.workspaces.allSatisfy { !scopedIds.contains($0.id) })
        #expect(manager.collections[0].workspaceIds == [peer.id])
        #expect(manager.collections[1].workspaceIds.isEmpty)
        #expect(manager.ungroupedWorkspaceIds.allSatisfy { !scopedIds.contains($0) })
        #expect(manager.project(for: peer.id) === peerProject)
        #expect(peer.panelOrder == peerPanels)
        #expect(manager.selectedWorkspaceId == peer.id)
        #expect(FileManager.default.fileExists(atPath: peer.currentDirectory))
        await fixture.remove()
    }

    @Test(arguments: [false, true])
    func deletionGateBlocksDuplicateLaunchAndConflictingCloseUntilRelease(_ failStop: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true, failsStop: failStop)
        let owner = try await fixture.workspace()
        try await fixture.waitForRuns(1)
        let duplicate = try await fixture.workspace(newBranch: false)
        let manager = fixture.manager
        await fixture.runner.holdStops()
        let deletion = Task { await manager.removeWorkspace(owner.id, deletingWorktree: true) }
        try await fixture.waitForStops(1)
        let roots = manager.worktreeDeletionRoots
        #expect(roots == [manager.canonicalPath(owner.currentDirectory)])
        #expect(!manager.canRunWorktreeSetup(in: duplicate))
        manager.runWorktreeSetupAgain(in: duplicate)
        manager.startWorktreeSetup(command: "printf fixture", in: duplicate)
        let ids = manager.workspaces.map(\.id)
        #expect(
            await manager.addWorkspaceToProject(fixture.project.id, branchName: "feature", createNewBranch: false)
                == nil)
        #expect(manager.workspaces.map(\.id) == ids)
        #expect(duplicate.worktreeSetupPanel == nil)
        #expect(await !manager.removeWorkspace(duplicate.id, deletingWorktree: true))
        #expect(manager.worktreeDeletionRoots == roots)
        await manager.removeProject(fixture.project.id)
        #expect(manager.worktreeDeletionRoots == roots)
        #expect(await fixture.runner.requests.count == 1)
        await fixture.runner.releaseStops()
        #expect(await deletion.value == !failStop)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: owner.currentDirectory) == failStop)
        if failStop {
            #expect(manager.workspaces.contains { $0 === owner })
            #expect(manager.canRunWorktreeSetup(in: duplicate))
        }
        await fixture.remove()
    }

    @Test
    func postValidationLaunchRechecksRootGateAndPendingPeerBlocksDeletion() async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let owner = try await fixture.workspace()
        let duplicate = try await fixture.workspace(newBranch: false)
        let manager = fixture.manager
        try manager.setWorktreeSetupCommand("printf fixture", for: fixture.project.id)
        manager.startWorktreeSetup(command: "printf fixture", in: owner)
        let panel = try #require(owner.worktreeSetupPanel)
        // Synchronous acquisition sees the pending run before validation/runner launch.
        #expect(
            manager.acquireWorktreeDeletionRoots([owner.currentDirectory], closingWorkspaceIDs: [duplicate.id]) == nil)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        let roots = try #require(
            manager.acquireWorktreeDeletionRoots([owner.currentDirectory], closingWorkspaceIDs: [owner.id]))
        #expect(
            manager.acquireWorktreeDeletionRoots(
                [fixture.repository.path, owner.currentDirectory], closingWorkspaceIDs: [owner.id]
            ) == nil)
        #expect(manager.worktreeDeletionRoots == roots)
        try await fixture.waitForFinish(panel)
        #expect(await fixture.runner.requests.isEmpty)
        #expect(panel.outcome != .succeeded)
        manager.worktreeDeletionRoots.subtract(roots)
        #expect(manager.canRunWorktreeSetup(in: duplicate))
        await fixture.remove()
    }

    @Test
    func worktreeRemovalErrorReleasesRootGateAndRetainsWorkspace() async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let workspace = try await fixture.workspace()
        workspace.worktreePath = fixture.repository.path  // The removal service refuses a main checkout.
        #expect(await !fixture.manager.removeWorkspace(workspace.id, deletingWorktree: true))
        #expect(fixture.manager.worktreeDeletionRoots.isEmpty)
        #expect(fixture.manager.workspaces.contains { $0 === workspace })
        #expect(FileManager.default.fileExists(atPath: fixture.repository.path))
        await fixture.remove()
    }
}

extension WorktreeSetupLifecycleTests {
    @Test(arguments: [false, true])
    func stalePreparationNeverDeletesAnAdoptedPeerRootOrStopsItsSetup(runSetup: Bool) async throws {
        let fixture = try await SetupManagerFixture.make()
        await fixture.runner.configure(hold: true)
        let manager = fixture.manager
        let project = fixture.project
        let destination = try #require(manager.createCollection(name: "Removed"))
        let gate = try BoundedGitHookGate(root: fixture.directory.url, repository: fixture.repository, name: "prepare")
        defer { gate.release() }
        let creation = Task {
            await manager.addWorkspaceToProject(project.id, branchName: "pending", collectionId: destination.id)
        }
        try await gate.waitUntilStarted()
        let path = manager.worktreeService.managedWorktreeBaseURL
            .appendingPathComponent(project.id.uuidString).appendingPathComponent("pending").path
        let adopted = try #require(
            manager.adoptOrphanedWorktree(.init(path: path, branchName: "pending", projectId: project.id)))
        if runSetup {
            manager.runWorktreeSetupAgain(in: adopted)
            try await fixture.waitForRuns(1)
        }
        let panels = adopted.panelOrder
        manager.removeCollection(destination.id)
        gate.release()
        #expect(await creation.value == nil)
        #expect(!gate.didTimeOut)
        #expect(manager.lastWorkspaceCreationError?.localizedDescription.contains("Collection") == true)
        #expect(manager.workspaces.contains { $0 === adopted })
        #expect(adopted.panelOrder == panels)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(adopted.runningSetupCount == (runSetup ? 1 : 0))
        #expect(await fixture.runner.stopRequests == 0)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        await fixture.remove()
    }

    @Test
    func awaitedUnattachedCleanupReservesRootAgainstEveryNewClaimAndReleasesAfterFailure() async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let manager = fixture.manager
        let project = fixture.project
        let path = try await manager.worktreeService.createWorktree(
            projectId: project.id,
            repositoryPath: fixture.repository.path, branchName: "unattached")
        // Retain a dirty file so cleanup fails unforced, permitting a subsequent claim after release.
        try Data("edited".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("edited.txt"))
        let gate = try BoundedGitHookGate(
            root: fixture.directory.url, repository: fixture.repository,
            name: "cleanup", monitorsStatus: true)
        defer { gate.release() }
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.directory.url.path))
        let before = manager.workspaces.map(\.id)
        let cleanup = Task {
            await manager.cleanupUnattachedWorktree(
                path: path, repositoryPath: project.repositoryPath, reusedExistingWorktree: false)
        }
        try await gate.waitUntilStarted()
        #expect(manager.worktreeDeletionRoots == [manager.canonicalPath(path)])
        #expect(
            manager.adoptOrphanedWorktree(.init(path: path, branchName: "unattached", projectId: project.id)) == nil)
        #expect(manager.addWorkspace(workingDirectory: path) == nil)
        #expect(await manager.createProject(repositoryPath: path, mainBranchOverride: "main") == nil)
        #expect(!manager.setStandaloneWorkspaceRoot(standalone.id, path: path))
        #expect(manager.lastWorkspaceCreationError?.localizedDescription.contains("being deleted") == true)
        #expect(!manager.setStandaloneWorkspaceRoot(standalone.id, path: ""))
        #expect(manager.lastWorkspaceCreationError == nil)
        #expect(
            await manager.addWorkspaceToProject(project.id, branchName: "unattached", createNewBranch: false) == nil)
        #expect(manager.workspaces.map(\.id) == before)
        #expect(manager.worktreeDeletionRoots == [manager.canonicalPath(path)])
        gate.release()
        await cleanup.value
        #expect(!gate.didTimeOut)
        #expect(manager.worktreeDeletionRoots.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(
            manager.adoptOrphanedWorktree(.init(path: path, branchName: "unattached", projectId: project.id)) != nil)
        await fixture.remove()
    }
}

extension WorktreeSetupLifecycleTests {
    @Test
    func automaticLastWorkspaceFallbackAvoidsReservedDefaultAndRefusesWhenHomeIsUnsafe() async throws {
        let fixture = try await SetupManagerFixture.make(command: nil)
        let manager = fixture.manager
        let only = try #require(manager.selectedWorkspace)
        for id in manager.workspaces.map(\.id) where id != only.id { manager.removeWorkspace(id) }
        let preferred = fixture.directory.url.path
        manager.settings.defaultStandaloneWorkspaceDirectory = preferred
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        manager.worktreeDeletionRoots = [manager.canonicalPath(preferred), manager.canonicalPath(home)]
        let panels = only.panelOrder
        #expect(await !manager.removeWorkspace(only.id, deletingWorktree: false))
        #expect(manager.selectedWorkspace === only)
        #expect(only.panelOrder == panels)
        #expect(manager.lastWorkspaceDeletionError != nil)
        manager.worktreeDeletionRoots.remove(manager.canonicalPath(home))
        manager.removeWorkspace(only.id)
        let fallback = try #require(manager.selectedWorkspace)
        #expect(fallback.id != only.id)
        #expect(fallback.currentDirectory == home)
        #expect(manager.settings.defaultStandaloneWorkspaceDirectory == preferred)
        #expect(manager.addWorkspace() == nil)
        #expect(manager.workspaces.count == 1)
        manager.worktreeDeletionRoots.removeAll()
        await fixture.remove()
    }
}
