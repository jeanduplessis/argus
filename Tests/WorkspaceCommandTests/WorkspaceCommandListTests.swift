import Foundation
import Testing

@testable import Argus

@MainActor
@Suite
struct WorkspaceCommandListTests {
    @Test
    func listProjectsWorkspaceNumbersAndStackGroups() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let result = WorkspaceCommandRuntime(workspaceManager: fixture.manager).listResult()

        #expect(result.selectedWorkspaceId == fixture.child.id.uuidString)
        #expect(result.sections.count == 1)
        #expect(result.sections[0].collectionId == nil)

        let project = try #require(result.sections[0].items.first.flatMap(Self.project))
        #expect(project.id == fixture.project.id.uuidString)
        #expect(project.name == fixture.project.displayName)
        #expect(project.mainBranch == "main")
        #expect(project.repositoryPath == fixture.project.repositoryPath)
        #expect(project.items.count == 2)

        let group = try #require(project.items.first.flatMap(Self.stack))
        #expect(group.id == fixture.stackId)
        #expect(group.baseBranch == "main")
        #expect(group.rows.map(\.branch) == ["feature/parent", "feature/gap", "feature/child"])
        #expect(group.rows.map(\.parentBranch) == ["main", "feature/parent", "feature/gap"])
        #expect(group.rows.map { $0.workspace?.number } == [1, nil, 2])
        #expect(group.rows.first?.workspace?.kind == .mainCheckout)
        #expect(group.rows.first?.workspace?.isSelected == false)
        #expect(group.rows.last?.workspace?.isSelected == true)
        #expect(group.rows.last?.workspace?.id == fixture.child.id.uuidString)

        let ordinary = try #require(project.items.last.flatMap(Self.workspace))
        #expect(ordinary.number == 3)
        #expect(ordinary.kind == .worktree)
        #expect(ordinary.branch == "unrelated")
        #expect(ordinary.worktreePath == fixture.ordinary.currentDirectory)
    }

    @Test
    func standaloneWorkspacesAndStackDiagnosticsAreReported() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let standalone = try #require(fixture.manager.addWorkspace(title: "notes"))
        fixture.manager.workspaceStackErrors[fixture.project.id] = "Conflicting recorded parents"
        let result = WorkspaceCommandRuntime(workspaceManager: fixture.manager).listResult()

        let section = try #require(result.sections.first)
        #expect(section.items.first.flatMap(Self.project)?.stackDiagnostic == "Conflicting recorded parents")
        guard case .workspace(let entry) = try #require(section.items.last) else {
            Issue.record("Standalone Workspace must be a direct section row")
            return
        }
        #expect(entry.id == standalone.id.uuidString)
        #expect(entry.kind == .standalone)
        #expect(entry.branch == nil)
        #expect(entry.worktreePath == nil)
        #expect(entry.root == standalone.currentDirectory)
        #expect(entry.isSelected)
        #expect(entry.number == 4)
    }

    @Test
    func mixedEmptyCollectionsAndSplitStacksMatchNavigationWithoutChangingFocus() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let working = try #require(manager.createCollection(name: "Working"))
        let empty = try #require(manager.createCollection(name: "Empty"))
        let standalone = try #require(manager.addWorkspace(title: "notes"))
        #expect(manager.moveWorkspace(fixture.parent.id, toCollection: working.id))
        #expect(manager.moveWorkspace(standalone.id, toCollection: working.id))
        let otherProject = Project(repositoryPath: "/tmp/other-repository", mainBranch: "main")
        manager.projects.append(otherProject)
        let other = Workspace(
            title: "other", workingDirectory: otherProject.repositoryPath, projectId: otherProject.id,
            branchName: "main", workspaceType: .mainCheckout)
        manager.workspaces.append(other)
        manager.appendPlacement(other.id, to: working.id)
        manager.selectWorkspace(fixture.child.id)
        _ = fixture.child.addBrowserPanel(url: URL(string: "about:blank"))
        let tab = fixture.child.activeTabId
        let pane = fixture.child.activePanelId
        manager.toggleCollection(working.id)
        manager.toggleRepository(fixture.project.id, in: nil)
        manager.toggleWorkspaceStack(fixture.stackId, in: fixture.project.id, collectionId: working.id)
        let manual = manager.collections.map(\.workspaceIds)
        let ungrouped = manager.ungroupedWorkspaceIds
        let runtime = WorkspaceCommandRuntime(workspaceManager: manager)
        let result = runtime.listResult()
        #expect(result.sections.map(\.collectionId) == [working.id.uuidString, empty.id.uuidString, nil])
        #expect(result.sections[1].items.isEmpty)
        #expect(result.sections[0].items.count == 3)
        let firstProject = try #require(result.sections[0].items.first.flatMap(Self.project))
        let localStack = try #require(firstProject.items.first.flatMap(Self.stack))
        #expect(localStack.rows.compactMap { $0.workspace?.id } == [fixture.parent.id.uuidString])
        let lastProject = try #require(result.sections[2].items.first.flatMap(Self.project))
        let otherStack = try #require(lastProject.items.first.flatMap(Self.stack))
        #expect(otherStack.rows.compactMap { $0.workspace?.id } == [fixture.child.id.uuidString])
        #expect(otherStack.rows.first { $0.branch == "feature/parent" }?.workspace == nil)
        #expect(otherStack.rows.first { $0.branch == "feature/child" }?.parentBranch == "feature/gap")
        let rows = Self.workspaceRows(result)
        #expect(rows.map(\.id) == manager.sidebarOrderedWorkspaces.map { $0.workspace.id.uuidString })
        #expect(Set(rows.map(\.id)).count == manager.workspaces.count)
        #expect(rows.map(\.number) == Array(1...manager.workspaces.count).map(Optional.some))
        #expect(rows.filter(\.isSelected).map(\.id) == [fixture.child.id.uuidString])
        #expect(manager.selectedWorkspaceId == fixture.child.id)
        #expect(fixture.child.activeTabId == tab)
        #expect(fixture.child.activePanelId == pane)
        #expect(manager.collections.map(\.workspaceIds) == manual)
        #expect(manager.ungroupedWorkspaceIds == ungrouped)
        #expect(manager.collections[0].isExpanded == false)
    }

    private static func workspaceRows(_ result: WorkspaceListResult) -> [WorkspaceListEntry] {
        result.sections.flatMap(\.items).flatMap { item -> [WorkspaceListEntry] in
            switch item {
            case .workspace(let entry): return [entry]
            case .project(let project):
                return project.items.flatMap { item -> [WorkspaceListEntry] in
                    switch item {
                    case .workspace(let entry): return [entry]
                    case .stack(let stack): return stack.rows.compactMap(\.workspace)
                    }
                }
            }
        }
    }

    private static func project(_ item: WorkspaceSectionListItem) -> ProjectListEntry? {
        guard case .project(let entry) = item else { return nil }
        return entry
    }

    private static func stack(_ item: WorkspaceListItem) -> StackGroupListEntry? {
        guard case .stack(let group) = item else { return nil }
        return group
    }

    private static func workspace(_ item: WorkspaceListItem) -> WorkspaceListEntry? {
        guard case .workspace(let entry) = item else { return nil }
        return entry
    }
}
