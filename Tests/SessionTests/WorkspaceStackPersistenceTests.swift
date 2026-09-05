import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct WorkspaceStackPersistenceTests {
    @Test
    func olderProjectSnapshotsDefaultToExpandedStackGroups() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.project.snapshot()
        let legacy = ProjectSnapshot(
            id: original.id, repositoryPath: original.repositoryPath, isCatchAll: false,
            displayName: original.displayName, mainBranch: original.mainBranch,
            workspaceIds: original.workspaceIds, isExpanded: false, color: original.color
        )
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["isExpanded"] = false
        json["workspaceIds"] = original.workspaceIds.map(\.uuidString)
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(json["collapsedStackIds"] == nil)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded.collapsedStackIds == nil)
        let restored = ArgusSessionSnapshot(
            schemaVersion: 1, selectedWorkspaceId: fixture.child.id,
            projects: [decoded], workspaces: fixture.manager.makeSessionSnapshot().workspaces
        ).reconciledForRestore()
        #expect(restored.ungroupedRepositoryDisclosure.first?.collapsedStackIds.isEmpty == true)
        #expect(restored.ungroupedRepositoryDisclosure.first?.isExpanded == false)
    }

    @Test
    func disclosureRoundTripsWithoutSavingLoadedGraphs() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: fixture.project.id))
        fixture.isExpanded = false
        manager.toggleWorkspaceStack(group.id, in: fixture.project.id)
        let data = try Data(contentsOf: manager.sessionSnapshotURL)
        let saved = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        #expect(saved.schemaVersion == 2)
        #expect(saved.ungroupedRepositoryDisclosure.first?.collapsedStackIds == [group.id])
        #expect(saved.ungroupedWorkspaceIds == fixture.manualOrder)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(json.keys) == [
                "schemaVersion", "selectedWorkspaceId", "projects", "workspaces",
                "ungroupedWorkspaceIds", "ungroupedRepositoryDisclosure"
            ])
        let projects = try #require(json["projects"] as? [[String: Any]])
        let runtimeKeys = [
            "stacks", "parents", "trunkBranches", "conflicts", "diagnostics", "worktrees", "gitCommonDirectory"
        ]
        for key in runtimeKeys {
            #expect(projects.allSatisfy { $0[key] == nil })
        }

        let restoredManager = WorkspaceManager(
            settings: AppSettings(defaults: fixture.defaults),
            sessionSnapshotURL: fixture.root.appendingPathComponent("restored-session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        #expect(restoredManager.restoreSession(from: saved))
        let project = try #require(restoredManager.projects.first { $0.id == fixture.project.id })
        #expect(restoredManager.repositoryDisclosure(for: project.id, in: nil).collapsedStackIds == [group.id])
        #expect(!restoredManager.repositoryDisclosure(for: project.id, in: nil).isExpanded)
        #expect(restoredManager.workspaceStackSnapshots.isEmpty)
        #expect(restoredManager.workspaceStackErrors.isEmpty)
        #expect(restoredManager.workspaceRevealRevision == 0)
        restoredManager.workspaceStackSnapshots[project.id] = fixture.snapshot
        #expect(restoredManager.sidebarOrderedWorkspaces.map(\.workspace.id) == fixture.orderedIds)
        restoredManager.toggleWorkspaceStack(group.id, in: project.id)
        let expanded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: Data(contentsOf: restoredManager.sessionSnapshotURL)
        )
        #expect(expanded.ungroupedRepositoryDisclosure.first?.collapsedStackIds == [])
    }

    @Test
    func legacyCollapsedKeySurvivesProviderNeutralForkDiscovery() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.collapsedStackIds = [fixture.stackId]
        let data = try JSONEncoder().encode(fixture.manager.makeSessionSnapshot())
        let saved = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: data)
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: fixture.defaults),
            sessionSnapshotURL: fixture.root.appendingPathComponent("fork-restored-session.json"),
            environment: ["ARGUS_DISABLE_SESSION_RESTORE": "1"]
        )
        #expect(manager.restoreSession(from: saved))
        let restored = try #require(manager.projects.first { $0.id == fixture.project.id })
        #expect(manager.workspaceStackSnapshots.isEmpty)
        manager.workspaceStackSnapshots[restored.id] = WorkspaceStackSnapshot(
            gitCommonDirectory: fixture.snapshot.gitCommonDirectory,
            worktrees: fixture.snapshot.worktrees,
            parents: fixture.snapshot.parents.merging(
                ["unrelated": "feature/parent"], uniquingKeysWith: { _, new in new }
            ), diagnostics: ["Unrelated metadata warning"]
        )
        let group = try #require(manager.stackGroup(for: fixture.child.id, in: restored.id))
        #expect(group.id == fixture.stackId)
        #expect(manager.repositoryDisclosure(for: restored.id, in: nil).collapsedStackIds.contains(group.id))
        #expect(group.laneCount == 2)
        #expect(group.workspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(saved.schemaVersion == 2)
    }

    @Test
    func reconciliationRetainsDisclosureWhileRepairingWorkspaceMembership() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.collapsedStackIds = [fixture.stackId, "previous-stack-key"]
        fixture.manualOrder = [UUID(), fixture.parent.id, fixture.parent.id]
        let snapshot = fixture.manager.makeSessionSnapshot()
        let reconciled = snapshot.reconciledForRestore()
        #expect(reconciled.ungroupedWorkspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        #expect(reconciled.ungroupedRepositoryDisclosure.first?.collapsedStackIds == fixture.collapsedStackIds)
        #expect(!reconciled.projects.contains { $0.isCatchAll })
        #expect(reconciled.schemaVersion == 2)
        #expect(
            reconciled.reconciledForRestore().ungroupedRepositoryDisclosure == reconciled.ungroupedRepositoryDisclosure)
    }
}
