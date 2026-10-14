import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceNotesPersistenceTests {
    @Test
    func workspaceNotesRoundTripAndEmptyNotesAreOmitted() throws {
        let noted = workspaceSnapshot(notes: "# Plan\n- [ ] ship")
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(noted))
        #expect(decoded.notes == "# Plan\n- [ ] ship")
        #expect(Workspace(snapshot: decoded).notes == "# Plan\n- [ ] ship")

        let empty = try JSONEncoder().encode(workspaceSnapshot(notes: ""))
        let emptyObject = try #require(JSONSerialization.jsonObject(with: empty) as? [String: Any])
        #expect(emptyObject["notes"] == nil)
    }

    @Test
    func legacyWorkspaceSnapshotWithoutNotesRestoresEmptyNotes() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(workspaceSnapshot(notes: "x"))) as? [String: Any]
        )
        object.removeValue(forKey: "notes")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacy)

        #expect(decoded.notes == nil)
        #expect(Workspace(snapshot: decoded).notes.isEmpty)
    }

    @Test
    func oversizedOrInvalidNotesAreIsolatedWithoutRejectingTheSnapshot() throws {
        let oversizedId = UUID()
        let invalidId = UUID()
        let keptId = UUID()
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: keptId,
            projects: [],
            workspaces: [
                workspaceSnapshot(id: oversizedId, notes: ""),
                workspaceSnapshot(id: invalidId, notes: ""),
                workspaceSnapshot(id: keptId, notes: "kept")
            ],
            ungroupedWorkspaceIds: [oversizedId, invalidId, keptId]
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        workspaces[0]["notes"] = String(repeating: "a", count: WorkspaceNotes.maximumUTF8ByteCount + 1)
        workspaces[1]["notes"] = 42
        object["workspaces"] = workspaces

        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.isValidForRestore(maxWorkspaces: WorkspaceManager.maxWorkspaces))
        #expect(decoded.workspaces.map(\.id) == [oversizedId, invalidId, keptId])
        #expect(decoded.workspaces.map(\.notes) == [nil, nil, "kept"])
        #expect(decoded.reconciledForRestore().workspaces.map(\.notes) == [nil, nil, "kept"])
    }

    @Test
    func managerRejectsNotesOverTheLimit() throws {
        let fixture = try ManagerFixture()
        defer { fixture.remove() }
        let manager = fixture.makeManager(environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"])
        let workspace = try #require(manager.selectedWorkspace)

        let oversized = String(repeating: "a", count: WorkspaceNotes.maximumUTF8ByteCount + 1)

        #expect(!manager.setWorkspaceNotes(oversized, for: workspace.id))
        #expect(workspace.notes.isEmpty)
        #expect(!manager.hasPendingWorkspaceNotesCheckpoint)
    }

    @Test
    func notesEditCheckpointsAfterTheDebounceDelay() async throws {
        let fixture = try ManagerFixture()
        defer { fixture.remove() }
        let manager = fixture.makeManager(environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"])
        manager.workspaceNotesCheckpointDelay = .milliseconds(20)
        let workspaceId = try #require(manager.selectedWorkspaceId)

        #expect(manager.setWorkspaceNotes("first", for: workspaceId))
        #expect(manager.setWorkspaceNotes("first draft", for: workspaceId))
        #expect(manager.hasPendingWorkspaceNotesCheckpoint)
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshotURL.path))

        for _ in 0..<200 where manager.hasPendingWorkspaceNotesCheckpoint {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!manager.hasPendingWorkspaceNotesCheckpoint)
        let restored = fixture.makeManager(environment: [:])
        #expect(restored.selectedWorkspace?.notes == "first draft")
    }

    @Test
    func changingSelectedWorkspaceFlushesNotesForTheirOwnWorkspace() throws {
        let fixture = try ManagerFixture()
        defer { fixture.remove() }
        let manager = fixture.makeManager(environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"])
        manager.workspaceNotesCheckpointDelay = .seconds(60)
        let firstId = try #require(manager.selectedWorkspaceId)
        let secondId = try #require(manager.addWorkspace()?.id)
        manager.selectWorkspace(firstId)

        manager.setWorkspaceNotes("first notes", for: firstId)
        #expect(manager.hasPendingWorkspaceNotesCheckpoint)
        manager.selectWorkspace(secondId)

        #expect(!manager.hasPendingWorkspaceNotesCheckpoint)
        let restored = fixture.makeManager(environment: [:])
        #expect(restored.workspaces.first { $0.id == firstId }?.notes == "first notes")
        #expect(restored.workspaces.first { $0.id == secondId }?.notes.isEmpty == true)
    }

    @Test
    func explicitFlushRestoresNotesOnAnEmptyWorkspace() throws {
        let fixture = try ManagerFixture()
        defer { fixture.remove() }
        fixture.settings.keepWorkspaceOpenAfterLastTerminalCloses = true
        let manager = fixture.makeManager(environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"])
        manager.workspaceNotesCheckpointDelay = .seconds(60)
        let workspace = try #require(manager.selectedWorkspace)
        manager.requestCloseTab(try #require(workspace.activePanelId), in: workspace.id)
        #expect(workspace.panelOrder.isEmpty)

        manager.setWorkspaceNotes("empty workspace notes", for: workspace.id)
        manager.flushWorkspaceNotesCheckpoint()

        #expect(!manager.hasPendingWorkspaceNotesCheckpoint)
        let restored = try #require(fixture.makeManager(environment: [:]).selectedWorkspace)
        #expect(restored.id == workspace.id)
        #expect(restored.panelOrder.isEmpty)
        #expect(restored.notes == "empty workspace notes")
    }

    private func workspaceSnapshot(id: UUID = UUID(), notes: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            id: id,
            projectId: nil,
            branchName: nil,
            workspaceType: .external,
            worktreePath: nil,
            title: "Notes",
            customTitle: nil,
            currentDirectory: "/tmp",
            panelCount: 1,
            notes: notes
        )
    }
}

@MainActor
private struct ManagerFixture {
    let suiteName = "ArgusTests.WorkspaceNotes.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: AppSettings
    let snapshotURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("argus-notes-session-\(UUID().uuidString).json")

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        settings = AppSettings(defaults: defaults)
    }

    func makeManager(environment: [String: String]) -> WorkspaceManager {
        WorkspaceManager(settings: settings, sessionSnapshotURL: snapshotURL, environment: environment)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: snapshotURL)
    }
}
