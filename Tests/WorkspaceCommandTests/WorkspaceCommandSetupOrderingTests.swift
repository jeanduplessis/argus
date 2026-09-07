import Foundation
import Testing

@testable import Argus

@MainActor
@Suite(.serialized)
struct WorkspaceCommandSetupOrderingTests {
    @Test(arguments: [false, true])
    func cliSettlesParentRecordingBeforeLaunchingRealSetup(recordingFails: Bool) async throws {
        let fixture = try WorkspaceCommandFixture()
        defer { fixture.cleanup() }
        let command =
            recordingFails
            ? "printf 'setup after warning'"
            : "/usr/bin/git config --get branch.ordered.base; "
                + "/usr/bin/git config --local branch.ordered.base setup-parent"
        try fixture.manager.setWorktreeSetupCommand(command, for: fixture.project.id)
        if recordingFails { try Data().write(to: fixture.repository.appendingPathComponent(".git/config.lock")) }
        let selected = fixture.manager.selectedWorkspaceId
        let result = try WorkspaceCommandCreateTests.created(
            await fixture.runtime.receive(
                .create(
                    fixture.createParameters(
                        base: fixture.mainCheckout.id.uuidString, branch: "ordered"))))
        let workspace = try #require(fixture.workspace(branch: "ordered"))
        let panel = try #require(fixture.manager.setupPanel(in: workspace))
        try await waitForSetupCompletion(panel)
        #expect(panel.outcome == .succeeded)
        #expect(result.recordedBaseBranch == !recordingFails)
        #expect(
            panel.output.trimmingCharacters(in: .whitespacesAndNewlines)
                == (recordingFails ? "setup after warning" : "main"))
        if !recordingFails {
            #expect(try fixture.gitOutput(["config", "--get", "branch.ordered.base"]) == "setup-parent")
        }
        #expect(fixture.manager.selectedWorkspaceId == selected)
        #expect(await fixture.manager.stopAllWorktreeSetups())
    }

    @Test(arguments: ["unchanged", "consent", "reservation", "close"])
    func suspendedPreparationRetainsPendingPanelAndRevalidatesBeforeRunnerLaunch(change: String) async throws {
        let fixture = try await SetupManagerFixture.make()
        let manager = fixture.manager
        let gate = SetupPreparationGate()
        defer { gate.release() }
        let creation = Task {
            await manager.addWorkspaceToProject(
                fixture.project.id, branchName: "ordered", selectsNewWorkspace: false,
                beforeAutomaticSetup: { workspace in
                    await gate.wait(in: workspace)
                    try? await manager.worktreeService.recordBaseBranch(
                        "main", forBranch: "ordered", repositoryPath: fixture.repository.path)
                })
        }
        await waitForStackState { gate.workspace != nil }
        let workspace = try #require(gate.workspace)
        let panel = try #require(manager.setupPanel(in: workspace))
        #expect(panel.isRunning)
        #expect(panel.owner?.workspaceID == workspace.id)
        let snapshot = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
        #expect(snapshot.workspaces.contains { $0.id == workspace.id })
        // Selecting and opening content during metadata work must not be undone at settlement.
        manager.selectWorkspace(workspace.id)
        let terminal = try #require(workspace.addTerminalPanel())
        #expect(await fixture.runner.requests.isEmpty)
        let closing = try prepareChange(change, fixture: fixture, workspace: workspace)
        if closing != nil { await waitForStackState { panel.isStopping } }
        #expect(await fixture.runner.requests.isEmpty)
        gate.release()
        #expect(await creation.value === workspace)
        try await fixture.waitForFinish(panel)
        if let closing { #expect(await closing.value) }
        #expect(await fixture.runner.requests.count == (change == "unchanged" ? 1 : 0))
        if change != "close" {
            #expect(manager.selectedWorkspaceId == workspace.id)
            #expect(workspace.activeTabId == terminal.id)
            #expect(workspace.activePanelId == terminal.id)
        }
        manager.worktreeDeletionRoots.removeAll()
        await fixture.remove()
    }

    private func waitForSetupCompletion(_ panel: WorktreeSetupPanel) async throws {
        // Match the setup fixture's bounded suspension-turn convention. A wall-
        // clock deadline can expire while MainActor prevents setup publication.
        // These 200 ten-millisecond turns are not a hard wall-clock timeout.
        do {
            for _ in 0..<200 {
                if !panel.isRunning { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            #expect(await panel.stop())
            throw error
        }
        #expect(!panel.isRunning)
    }

    private func prepareChange(
        _ change: String, fixture: SetupManagerFixture, workspace: Workspace
    ) throws -> Task<Bool, Never>? {
        let manager = fixture.manager
        switch change {
        case "consent": try manager.setWorktreeSetupCommand("", for: fixture.project.id)
        case "reservation": manager.worktreeDeletionRoots.insert(manager.canonicalPath(workspace.currentDirectory))
        case "close": return Task { await manager.removeWorkspace(workspace.id, deletingWorktree: false) }
        default: break
        }
        return nil
    }
}

@MainActor
private final class SetupPreparationGate {
    private(set) var workspace: Workspace?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(in workspace: Workspace) async {
        self.workspace = workspace
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
