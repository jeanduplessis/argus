import Foundation

@main
struct TerminalDirectorySnapshotTests {
    static func main() throws {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let workspace = WorkspaceSnapshot(
            id: workspaceId,
            projectId: projectId,
            branchName: "feature/cwd",
            workspaceType: .worktree,
            worktreePath: "/repo/.argus/worktree",
            title: "feature/cwd",
            customTitle: nil,
            currentDirectory: "/repo/.argus/worktree",
            panelCount: 3,
            terminalDirectories: [
                "/repo/.argus/worktree/app",
                "/repo/.argus/worktree/docs",
                "/tmp/scratch"
            ]
        )

        let encoded = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        assertEqual(
            decoded.terminalDirectories,
            ["/repo/.argus/worktree/app", "/repo/.argus/worktree/docs", "/tmp/scratch"],
            "terminal directories round-trip"
        )
        assertEqual(
            decoded.restoredTerminalDirectories,
            decoded.terminalDirectories,
            "restore uses persisted terminal directories"
        )

        let legacyJSON = """
        {
          "id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
          "projectId": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
          "branchName": "main",
          "workspaceType": "worktree",
          "worktreePath": "/repo/worktree",
          "title": "main",
          "customTitle": null,
          "currentDirectory": "/repo/worktree",
          "panelCount": 2
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: legacyJSON)
        assertEqual(
            legacy.restoredTerminalDirectories,
            ["/repo/worktree", "/repo/worktree"],
            "legacy snapshots fall back to workspace directory for each terminal"
        )

        let invalidProject = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let reconciled = ArgusSessionSnapshot(
            selectedWorkspaceId: workspaceId,
            projects: [ProjectSnapshot(
                id: projectId,
                repositoryPath: "/repo",
                isCatchAll: true,
                displayName: "Workspaces",
                mainBranch: "",
                workspaceIds: [],
                isExpanded: true,
                color: nil
            )],
            workspaces: [WorkspaceSnapshot(
                id: workspaceId,
                projectId: invalidProject,
                branchName: nil,
                workspaceType: .external,
                worktreePath: nil,
                title: "Terminal",
                customTitle: nil,
                currentDirectory: "/repo",
                panelCount: 2,
                terminalDirectories: ["/repo/api", "/repo/web"]
            )]
        ).reconciledForRestore()
        assertEqual(
            reconciled.workspaces[0].terminalDirectories,
            ["/repo/api", "/repo/web"],
            "reconciliation preserves terminal directories"
        )
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
