import Foundation

@main
struct SessionSnapshotTests {
    static func main() throws {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let project = ProjectSnapshot(
            id: projectId,
            repositoryPath: "/tmp/repo",
            isCatchAll: false,
            displayName: "Repo",
            mainBranch: "main",
            workspaceIds: [workspaceId],
            isExpanded: false,
            color: .blue
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceId,
            projectId: projectId,
            branchName: "feature/persist",
            workspaceType: .worktree,
            worktreePath: "/tmp/worktree",
            title: "feature/persist",
            customTitle: "Persist Work",
            currentDirectory: "/tmp/worktree",
            panelCount: 1
        )
        let snapshot = ArgusSessionSnapshot(
            schemaVersion: ArgusSessionSnapshot.currentSchemaVersion,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: encoded)

        assertEqual(decoded.schemaVersion, ArgusSessionSnapshot.currentSchemaVersion, "schema version round-trips")
        assertEqual(decoded.projects.first?.id, projectId, "project id round-trips")
        assertEqual(decoded.projects.first?.isExpanded, false, "project expansion state round-trips")
        assertEqual(decoded.workspaces.first?.projectId, projectId, "workspace project id round-trips")
        assertEqual(decoded.workspaces.first?.branchName, "feature/persist", "workspace branch round-trips")
        assertEqual(decoded.workspaces.first?.worktreePath, "/tmp/worktree", "workspace worktree path round-trips")
        assertEqual(decoded.selectedWorkspaceId, workspaceId, "selected workspace id round-trips")
        assertEqual(decoded.isCompatible, true, "current schema is compatible")

        let incompatible = ArgusSessionSnapshot(
            schemaVersion: 999,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )
        assertEqual(incompatible.isCompatible, false, "future schema is incompatible")
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
