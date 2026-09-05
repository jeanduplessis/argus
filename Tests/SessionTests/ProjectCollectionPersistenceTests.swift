import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct ProjectCollectionPersistenceTests {
    @Test
    func userMutationsCheckpointAndRoundTripWithSchemaTwo() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Client API"))
        #expect(try saved(manager).collections?.first?.name == "Client API")
        manager.renameCollection(collection.id, name: "Client aPI")
        #expect(try saved(manager).collections?.first?.name == "Client aPI")
        manager.moveWorkspace(fixture.child.id, toCollection: collection.id)
        #expect(try saved(manager).collections?.first?.workspaceIds == [fixture.child.id])
        manager.toggleCollection(collection.id)
        #expect(try saved(manager).collections?.first?.isExpanded == false)
        let empty = try #require(manager.createCollection(name: "Empty"))
        manager.moveCollection(empty.id, offset: -1)
        let snapshot = try saved(manager)
        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.collections?.map(\.id) == [empty.id, collection.id])
        let restored = WorkspaceManager(
            settings: manager.settings, sessionSnapshotURL: fixture.root.appendingPathComponent("restored.json"),
            environment: ["ARGUS_UNDER_TEST": "1"])
        #expect(restored.restoreSession(from: snapshot))
        #expect(restored.collections == manager.collections)
        #expect(restored.selectedWorkspaceId == manager.selectedWorkspaceId)
        #expect(
            restored.sidebarOrderedWorkspaces.map(\.workspace.id)
                == manager.sidebarOrderedWorkspaces.map(\.workspace.id))
        restored.removeCollection(collection.id)
        #expect(try saved(restored).collections?.map(\.id) == [empty.id])
        #expect(restored.ungroupedWorkspaceIds.last == fixture.child.id)
    }

    @Test
    func missingCollectionsAndOptionalDisclosureRestoreWithoutDiscardingSession() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let data = try JSONEncoder().encode(manager.makeSessionSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "collections")
        let legacy = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: legacy))
        #expect(manager.collections.isEmpty)
        #expect(manager.namedProjects.map(\.id) == [fixture.project.id])
        let id = UUID()
        json["collections"] = [["id": id.uuidString, "name": "Legacy", "workspaceIds": [fixture.child.id.uuidString]]]
        let optional = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: optional))
        #expect(manager.collections.first?.isExpanded == true)
        #expect(manager.collections.first?.id == id)
    }

    @Test
    func reconciliationDropsStaleDuplicateMembershipButKeepsEmptyCollections() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.manager.makeSessionSnapshot()
        let first = ProjectCollection(
            name: "First",
            workspaceIds: [
                UUID(), UUID(), fixture.child.id, fixture.child.id
            ], isExpanded: false)
        let second = ProjectCollection(name: "Second", workspaceIds: [fixture.child.id])
        let invalid = ProjectCollection(name: " \n")
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: original.selectedWorkspaceId, projects: original.projects,
            workspaces: original.workspaces,
            collections: [first, first, invalid, second])
        #expect(snapshot.isValidForRestore(maxWorkspaces: 128))
        let reconciled = snapshot.reconciledForRestore()
        #expect(
            reconciled.collections == [
                ProjectCollection(id: first.id, name: first.name, workspaceIds: [fixture.child.id], isExpanded: false),
                ProjectCollection(id: second.id, name: second.name)
            ])
        #expect(reconciled.reconciledForRestore().collections == reconciled.collections)
        #expect(fixture.manager.restoreSession(from: snapshot))
        #expect(fixture.manager.workspaces.count == original.workspaces.count)
        #expect(Set(fixture.manager.sidebarOrderedWorkspaces.map(\.workspace.id)) == Set(original.workspaces.map(\.id)))
    }

    @Test
    func decodingBoundsCollectionCountAndMembership() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = try JSONEncoder().encode(fixture.manager.makeSessionSnapshot())
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let members = (0..<200).map { _ in UUID().uuidString }
        json["collections"] = (0..<200).map { index in
            ["id": UUID().uuidString, "name": "Collection \(index)", "workspaceIds": members] as [String: Any]
        }
        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.collections?.count == 128)
        #expect(decoded.collections?.allSatisfy { $0.workspaceIds.count == 128 } == true)
        #expect(fixture.manager.restoreSession(from: decoded))
        #expect(fixture.manager.collections.count == 128)
        #expect(fixture.manager.collections.allSatisfy { $0.workspaceIds.isEmpty })
    }

    @Test(arguments: [false, true])
    func collectionLimitCountsOnlyValidUniqueRecords(decodeJSON: Bool) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let original = fixture.manager.makeSessionSnapshot()
        let first = ProjectCollection(name: "First", workspaceIds: [fixture.child.id], isExpanded: false)
        let later = ProjectCollection(name: "Later")
        let invalid = (0..<128).map { index in
            ProjectCollection(id: first.id, name: index.isMultiple(of: 2) ? " \n" : String(repeating: "a", count: 4097))
        }
        let duplicate = ProjectCollection(id: first.id, name: "Duplicate", workspaceIds: [UUID()])
        let records = invalid + [first] + Array(repeating: duplicate, count: 128) + [later]
        let snapshot: ArgusSessionSnapshot
        if decodeJSON {
            var json = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["collections"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
            snapshot = try JSONDecoder().decode(
                ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        } else {
            snapshot = ArgusSessionSnapshot(
                selectedWorkspaceId: original.selectedWorkspaceId, projects: original.projects,
                workspaces: original.workspaces, collections: records)
        }
        #expect(snapshot.collections == [first, later])
        #expect(ProjectCollection.reconciled(records, validWorkspaceIds: [fixture.child.id]) == [first, later])
        #expect(snapshot.isValidForRestore(maxWorkspaces: 128))
        #expect(fixture.manager.restoreSession(from: snapshot))
        #expect(fixture.manager.collections == [first, later])
    }

    @Test
    func inMemoryCollectionLimitRetainsFirst128ValidRecords() {
        let records = (0..<200).map { ProjectCollection(name: "Collection \($0)") }
        let expected = Array(records.prefix(128))
        let snapshot = ArgusSessionSnapshot(
            selectedWorkspaceId: nil, projects: [], workspaces: [], collections: records)
        #expect(snapshot.collections == expected)
        #expect(ProjectCollection.reconciled(records, validWorkspaceIds: []) == expected)
    }

    @Test
    func malformedOptionalCollectionsPreserveCoreSessionAndValidSiblings() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let sibling = Project(repositoryPath: fixture.root.appendingPathComponent("sibling").path, mainBranch: "main")
        manager.projects.insert(sibling, at: 0)
        let original = manager.makeSessionSnapshot()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        let firstId = UUID()
        let secondId = UUID()
        json["collections"] =
            [
                ["id": "not-a-uuid", "name": "Invalid", "workspaceIds": []],
                [
                    "id": firstId.uuidString, "name": "First", "isExpanded": "wrong-type",
                    "workspaceIds": ["bad-uuid", 123, NSNull(), fixture.child.id.uuidString]
                ],
                "not-a-record", NSNull(),
                ["id": UUID().uuidString, "name": 42, "workspaceIds": []],
                ["id": secondId.uuidString, "name": "Second", "workspaceIds": [fixture.parent.id.uuidString]]
            ] as [Any]
        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(manager.restoreSession(from: decoded))
        #expect(manager.workspaces.map(\.id) == original.workspaces.map(\.id))
        #expect(manager.projects.map(\.id) == original.projects.map(\.id))
        #expect(manager.selectedWorkspaceId == original.selectedWorkspaceId)
        #expect(
            manager.collections == [
                ProjectCollection(id: firstId, name: "First", workspaceIds: [fixture.child.id]),
                ProjectCollection(id: secondId, name: "Second", workspaceIds: [fixture.parent.id])
            ])
        for malformed in [42, "not-an-array", ["wrong": "shape"]] as [Any] {
            json["collections"] = malformed
            let malformedSnapshot = try JSONDecoder().decode(
                ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(manager.restoreSession(from: malformedSnapshot))
            #expect(manager.collections.isEmpty)
            #expect(manager.workspaces.map(\.id) == original.workspaces.map(\.id))
        }
    }

    private func saved(_ manager: WorkspaceManager) throws -> ArgusSessionSnapshot {
        try JSONDecoder().decode(ArgusSessionSnapshot.self, from: Data(contentsOf: manager.sessionSnapshotURL))
    }
}

extension ProjectCollectionPersistenceTests {
    @Test
    // One workflow verifies conversion/reuse without splitting its identity and content assertions.
    // swiftlint:disable:next function_body_length
    func protectedImportPreservesLegacyBytesIdentityManualOrderAndEmptyContent() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let emptyRepository = Project(
            repositoryPath: fixture.root.appendingPathComponent("empty-repository").path,
            displayName: "Configured but closed", mainBranch: "main")
        emptyRepository.worktreeSetupCommand = " printf 'keep consent bytes'\n"
        manager.projects.append(emptyRepository)
        let standalone = try #require(manager.addWorkspace(workingDirectory: fixture.root.path))
        let catchAllId = UUID()
        let collectionId = UUID()
        let emptyCollectionId = UUID()
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(manager.makeSessionSnapshot())) as? [String: Any])
        legacy["schemaVersion"] = 1
        legacy.removeValue(forKey: "ungroupedWorkspaceIds")
        legacy.removeValue(forKey: "ungroupedRepositoryDisclosure")
        var projects = try #require(legacy["projects"] as? [[String: Any]])
        projects[0]["workspaceIds"] = [
            fixture.child.id.uuidString, fixture.ordinary.id.uuidString, fixture.parent.id.uuidString
        ]
        projects[0]["isExpanded"] = false
        projects[0]["collapsedStackIds"] = [fixture.stackId]
        projects.append([
            "id": catchAllId.uuidString, "repositoryPath": "", "isCatchAll": true,
            "displayName": "Workspaces", "mainBranch": "", "workspaceIds": [standalone.id.uuidString],
            "isExpanded": true
        ])
        legacy["projects"] = projects
        legacy["collections"] = [
            [
                "id": collectionId.uuidString, "name": "Mixed Case", "projectIds": [fixture.project.id.uuidString],
                "isExpanded": false
            ],
            ["id": emptyCollectionId.uuidString, "name": "Empty", "projectIds": []]
        ]
        var workspaces = try #require(legacy["workspaces"] as? [[String: Any]])
        workspaces[workspaces.count - 1]["projectId"] = catchAllId.uuidString
        workspaces[workspaces.count - 1]["terminalCustomTitles"] = ["User terminal"]
        workspaces[workspaces.count - 1]["terminalDirectories"] = [fixture.root.path]
        legacy["workspaces"] = workspaces
        legacy["selectedWorkspaceId"] = fixture.child.id.uuidString
        let source = fixture.root.appendingPathComponent("legacy-session.json")
        let destination = fixture.root.appendingPathComponent("session-v2.json")
        let original = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: source)
        let restored = WorkspaceManager(
            settings: manager.settings, sessionSnapshotURL: destination,
            legacySessionSnapshotURL: source, environment: [:])
        #expect(restored.projects.map(\.id) == [fixture.project.id, emptyRepository.id])
        #expect(restored.projects.last?.worktreeSetupCommand == emptyRepository.worktreeSetupCommand)
        #expect(restored.collections.map(\.id) == [collectionId, emptyCollectionId])
        #expect(restored.collections[0].workspaceIds == [fixture.child.id, fixture.ordinary.id, fixture.parent.id])
        #expect(restored.collections[0].repositoryDisclosure.first?.collapsedStackIds == [fixture.stackId])
        #expect(restored.collections[0].repositoryDisclosure.first?.isExpanded == false)
        #expect(restored.ungroupedWorkspaceIds == [standalone.id])
        #expect(restored.selectedWorkspaceId == fixture.child.id)
        #expect(restored.selectedWorkspace?.panels.isEmpty == true)
        #expect(restored.project(for: standalone.id) == nil)
        let persisted = try saved(restored)
        #expect(persisted.schemaVersion == 2)
        #expect(persisted.workspaces.last?.terminalCustomTitles == ["User terminal"])
        #expect(persisted.workspaces.last?.terminalDirectories == [fixture.root.path])
        restored.moveWorkspace(fixture.child.id, toCollection: emptyCollectionId)
        try restored.saveSession(to: destination)
        #expect(try Data(contentsOf: source) == original)
        let relaunched = WorkspaceManager(
            settings: manager.settings, sessionSnapshotURL: destination,
            legacySessionSnapshotURL: source, environment: [:])
        #expect(relaunched.collection(containing: fixture.child.id)?.id == emptyCollectionId)
        #expect(relaunched.projects.last?.id == emptyRepository.id)
        #expect(try Data(contentsOf: source) == original)
        // An old writer can edit its own file, but a new-format relaunch must not merge/import it again.
        legacy["selectedWorkspaceId"] = standalone.id.uuidString
        try JSONSerialization.data(withJSONObject: legacy).write(to: source)
        let afterDowngrade = WorkspaceManager(
            settings: manager.settings, sessionSnapshotURL: destination,
            legacySessionSnapshotURL: source, environment: [:])
        #expect(afterDowngrade.selectedWorkspaceId == fixture.child.id)
        #expect(afterDowngrade.collection(containing: fixture.child.id)?.id == emptyCollectionId)
    }

    @Test(arguments: ["corrupt", "future"])
    func existingInvalidNewDestinationNeverReimportsLegacy(kind: String) throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("legacy.json")
        let destination = fixture.root.appendingPathComponent("session-v2.json")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.manager.makeSessionSnapshot()))
                as? [String: Any])
        legacy["schemaVersion"] = 1
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        try bytes.write(to: source)
        if kind == "future" {
            legacy["schemaVersion"] = 999
            try JSONSerialization.data(withJSONObject: legacy).write(to: destination)
        } else {
            try Data("not JSON".utf8).write(to: destination)
        }
        let manager = WorkspaceManager(
            settings: fixture.manager.settings, sessionSnapshotURL: destination,
            legacySessionSnapshotURL: source, environment: [:])
        #expect(manager.workspaces.count == 1)
        #expect(manager.selectedWorkspaceId != fixture.child.id)
        #expect(manager.projects.isEmpty)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test
    func suppliedAndTestURLsCannotResolveProductionLegacySource() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        #expect(fixture.manager.legacySessionSnapshotURL == nil)
        let supplied = WorkspaceManager(
            settings: fixture.manager.settings,
            sessionSnapshotURL: fixture.root.appendingPathComponent("missing.json"), environment: [:])
        #expect(supplied.legacySessionSnapshotURL == nil)
        for environment in [
            ["ARGUS_UNDER_TEST": "1"], ["ARGUS_DISABLE_SESSION_RESTORE": "1"], ["XCTestConfigurationFilePath": "test"]
        ] {
            let manager = WorkspaceManager(settings: fixture.manager.settings, environment: environment)
            #expect(manager.legacySessionSnapshotURL == nil)
            #expect(
                manager.sessionSnapshotURL.path.hasSuffix(
                    "Argus/TestSessions/\(ProcessInfo.processInfo.processIdentifier)/session.json"))
        }
    }
}

extension ProjectCollectionPersistenceTests {
    @Test
    func failedInitialImportCheckpointCanRetryWithoutTouchingLegacyBytes() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.manager.makeSessionSnapshot()))
                as? [String: Any])
        json["schemaVersion"] = 1
        let original = try JSONSerialization.data(withJSONObject: json)
        let legacy = fixture.root.appendingPathComponent("legacy.json")
        try original.write(to: legacy)
        let blocker = fixture.root.appendingPathComponent("blocked-parent")
        try Data("not a directory".utf8).write(to: blocker)
        let destination = blocker.appendingPathComponent("session-v2.json")
        let imported = WorkspaceManager(
            settings: fixture.manager.settings, sessionSnapshotURL: destination,
            legacySessionSnapshotURL: legacy, environment: [:])
        #expect(imported.selectedWorkspaceId == fixture.child.id)
        #expect(imported.workspaces.count == fixture.manager.workspaces.count)
        try FileManager.default.removeItem(at: blocker)
        imported.renameWorkspace(fixture.child.id, title: "Recovered after failed checkpoint")
        let saved = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: Data(contentsOf: destination))
        #expect(saved.schemaVersion == 2)
        #expect(
            saved.workspaces.first { $0.id == fixture.child.id }?.customTitle == "Recovered after failed checkpoint")
        #expect(try Data(contentsOf: legacy) == original)
    }
}

extension ProjectCollectionPersistenceTests {
    @Test
    func malformedUngroupedPlacementAndLocalDisclosureIsolateValidSiblings() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.manager.makeSessionSnapshot()))
                as? [String: Any])
        json["ungroupedWorkspaceIds"] = ["bad-id", 12, fixture.parent.id.uuidString, fixture.parent.id.uuidString]
        json["ungroupedRepositoryDisclosure"] =
            [
                ["projectId": "bad-id"], "bad-record",
                [
                    "projectId": fixture.project.id.uuidString, "isExpanded": false,
                    "collapsedStackIds": [42, fixture.stackId, String(repeating: "x", count: 16385)]
                ]
            ] as [Any]
        let decoded = try JSONDecoder().decode(
            ArgusSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(fixture.manager.restoreSession(from: decoded))
        #expect(fixture.manager.ungroupedWorkspaceIds == [fixture.parent.id, fixture.child.id, fixture.ordinary.id])
        let disclosure = fixture.manager.repositoryDisclosure(for: fixture.project.id, in: nil)
        #expect(!disclosure.isExpanded)
        #expect(disclosure.collapsedStackIds == [fixture.stackId])
        #expect(fixture.manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.manager.selectedWorkspace?.panels.isEmpty == true)
    }
}
