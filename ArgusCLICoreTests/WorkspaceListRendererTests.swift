import ArgusIPC
import Foundation
import Testing

@testable import ArgusCLICore

@Suite
struct WorkspaceListRendererTests {
    @Test
    func stackGroupsRenderAsParentBeforeDependentTrees() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")

        #expect(
            renderer.lines(for: Self.result) == [
                "No Collection",
                "argus  main  ~/Projects/argus",
                "      stack  base main",
                "  1   feature/parent  [worktree]",
                "        \u{21B3} feature/gap  (branch reference)",
                "  2 *     \u{21B3} Child work  feature/child  [worktree]",
                "  3   scratch  [worktree]",
                "  4   notes  [standalone]  ~/notes"
            ])
    }

    @Test
    func diagnosticsAndEmptySectionsStayVisible() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")
        let result = WorkspaceListResult(
            selectedWorkspaceId: nil,
            sections: [
                WorkspaceListSection(
                    collectionId: nil, name: nil,
                    items: [
                        .project(
                            ProjectListEntry(
                                id: "project", name: "argus", repositoryPath: nil,
                                mainBranch: nil, stackDiagnostic: "Conflicting recorded parents for 'x'", items: []
                            ))
                    ])
            ]
        )

        #expect(
            renderer.lines(for: result) == [
                "No Collection",
                "argus",
                "      ! Conflicting recorded parents for 'x'",
                "      (no Workspaces)"
            ])
    }

    @Test
    func aStackWithNoRecordedBaseSaysSo() {
        let renderer = WorkspaceListRenderer(homeDirectory: "/Users/tester")
        let group = StackGroupListEntry(
            id: "stack",
            baseBranch: nil,
            rows: [
                StackRowListEntry(
                    branch: "feature/parent", parentBranch: nil, lane: 0,
                    issue: "Recorded parent cycle", workspace: Self.parent
                )
            ]
        )
        let result = WorkspaceListResult(
            selectedWorkspaceId: nil,
            sections: [
                WorkspaceListSection(
                    collectionId: nil, name: nil,
                    items: [
                        .project(
                            ProjectListEntry(
                                id: "project", name: "argus", repositoryPath: nil,
                                mainBranch: nil, stackDiagnostic: nil, items: [.stack(group)]
                            ))
                    ])
            ]
        )

        #expect(
            renderer.lines(for: result) == [
                "No Collection",
                "argus",
                "      stack  base not recorded",
                "  1   feature/parent  [worktree]",
                "      ! Recorded parent cycle"
            ])
    }

    @Test
    func emptyCollectionsAndMixedSectionsRoundTripWithoutSyntheticProjects() throws {
        let result = WorkspaceListResult(
            selectedWorkspaceId: "child",
            sections: [
                WorkspaceListSection(collectionId: "empty", name: "Empty", items: []),
                WorkspaceListSection(collectionId: "mixed", name: "Working", items: Self.result.sections[0].items),
                WorkspaceListSection(collectionId: nil, name: nil, items: [])
            ])
        let encoded = try JSONEncoder().encode(result)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["projects"] == nil)
        #expect((object["sections"] as? [Any])?.count == 3)
        #expect(try #require(String(data: encoded, encoding: .utf8)).contains("isCatchAll") == false)
        let decoded = try JSONDecoder().decode(WorkspaceListResult.self, from: encoded)
        #expect(decoded.sections.map(\.collectionId) == ["empty", "mixed", nil])
        let lines = WorkspaceListRenderer(homeDirectory: "/Users/tester").lines(for: decoded)
        #expect(Array(lines.prefix(3)) == ["Empty", "      (no Workspaces)", "Working"])
        #expect(Array(lines.suffix(2)) == ["No Collection", "      (no Workspaces)"])
        #expect(lines.filter { $0.contains("[standalone]") }.count == 1)
    }

    private static let parent = WorkspaceListEntry(
        id: "parent", number: 1, title: "feature/parent", kind: .worktree, branch: "feature/parent",
        root: "/tmp/parent", worktreePath: "/tmp/parent", isSelected: false, tabCount: 1
    )

    private static let child = WorkspaceListEntry(
        id: "child", number: 2, title: "Child work", kind: .worktree, branch: "feature/child",
        root: "/tmp/child", worktreePath: "/tmp/child", isSelected: true, tabCount: 2
    )

    private static let scratch = WorkspaceListEntry(
        id: "scratch", number: 3, title: "scratch", kind: .worktree, branch: "scratch",
        root: "/tmp/scratch", worktreePath: "/tmp/scratch", isSelected: false, tabCount: 1
    )

    private static let notes = WorkspaceListEntry(
        id: "notes", number: 4, title: "notes", kind: .standalone, branch: nil,
        root: "/Users/tester/notes", worktreePath: nil, isSelected: false, tabCount: 1
    )

    private static let result = WorkspaceListResult(
        selectedWorkspaceId: "child",
        sections: [
            WorkspaceListSection(
                collectionId: nil, name: nil,
                items: [
                    .project(
                        ProjectListEntry(
                            id: "project",
                            name: "argus",
                            repositoryPath: "/Users/tester/Projects/argus",
                            mainBranch: "main",
                            stackDiagnostic: nil,
                            items: [
                                .stack(
                                    StackGroupListEntry(
                                        id: "stack",
                                        baseBranch: "main",
                                        rows: [
                                            StackRowListEntry(
                                                branch: "feature/parent", parentBranch: "main", lane: 0,
                                                issue: nil, workspace: parent
                                            ),
                                            StackRowListEntry(
                                                branch: "feature/gap", parentBranch: "feature/parent", lane: 0,
                                                issue: nil, workspace: nil
                                            ),
                                            StackRowListEntry(
                                                branch: "feature/child", parentBranch: "feature/gap", lane: 0,
                                                issue: nil, workspace: child
                                            )
                                        ]
                                    )),
                                .workspace(scratch)
                            ]
                        )),
                    .workspace(notes)
                ])
        ]
    )
}
