import Foundation

extension WorkspaceCommandRuntime {
    /// Projects the fully expanded left-sidebar order, including Stack Groups
    /// and the nonselectable branch references that complete them.
    func listResult() -> WorkspaceListResult {
        let numbers = workspaceNumbers()
        return WorkspaceListResult(
            selectedWorkspaceId: workspaceManager.selectedWorkspaceId?.uuidString,
            sections: workspaceManager.navigationSections.map { section in
                WorkspaceListSection(
                    collectionId: section.id?.uuidString,
                    name: workspaceManager.collections.first { $0.id == section.id }?.name,
                    items: section.blocks.flatMap { block -> [WorkspaceSectionListItem] in
                        if let project = block.project {
                            return [.project(projectEntry(project, items: block.items, numbers: numbers))]
                        }
                        return block.workspaceIds.compactMap { id in
                            workspace(id).map { .workspace(entry(for: $0, numbers: numbers)) }
                        }
                    })
            }
        )
    }

    /// Workspace Numbers: 1-based global left-sidebar positions.
    func workspaceNumbers() -> [UUID: Int] {
        Dictionary(
            workspaceManager.sidebarOrderedWorkspaces.enumerated().map { ($0.element.workspace.id, $0.offset + 1) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func entry(for workspace: Workspace, numbers: [UUID: Int]) -> WorkspaceListEntry {
        WorkspaceListEntry(
            id: workspace.id.uuidString,
            number: numbers[workspace.id],
            title: workspace.displayTitle,
            kind: Self.kind(for: workspace.workspaceType),
            branch: workspace.branchName,
            root: workspace.currentDirectory,
            worktreePath: workspace.worktreePath,
            isSelected: workspaceManager.selectedWorkspaceId == workspace.id,
            tabCount: workspace.panelCount
        )
    }

    private func projectEntry(
        _ project: Project, items: [WorkspaceSidebarItem], numbers: [UUID: Int]
    ) -> ProjectListEntry {
        ProjectListEntry(
            id: project.id.uuidString,
            name: project.displayName,
            repositoryPath: project.repositoryPath,
            mainBranch: project.mainBranch,
            stackDiagnostic: workspaceManager.workspaceStackErrors[project.id],
            items: items.compactMap { item in
                listItem(for: item, numbers: numbers)
            }
        )
    }

    private func listItem(
        for item: WorkspaceSidebarItem,
        numbers: [UUID: Int]
    ) -> WorkspaceListItem? {
        switch item {
        case .workspace(let workspaceId):
            guard let workspace = workspace(workspaceId) else { return nil }
            return .workspace(entry(for: workspace, numbers: numbers))
        case .stack(let group):
            return .stack(
                StackGroupListEntry(
                    id: group.id,
                    baseBranch: group.baseBranch,
                    rows: group.rows.map { row in stackRow(row, numbers: numbers) }
                )
            )
        }
    }

    private func stackRow(_ row: WorkspaceStackRow, numbers: [UUID: Int]) -> StackRowListEntry {
        StackRowListEntry(
            branch: row.branch,
            parentBranch: row.parentBranch,
            lane: row.lane,
            issue: row.issue,
            workspace: row.workspaceId
                .flatMap { workspace($0) }
                .map { entry(for: $0, numbers: numbers) }
        )
    }

    private func workspace(_ workspaceId: UUID) -> Workspace? {
        workspaceManager.workspaces.first { $0.id == workspaceId }
    }

    private static func kind(for workspaceType: WorkspaceType) -> WorkspaceKindEntry {
        switch workspaceType {
        case .mainCheckout: .mainCheckout
        case .worktree: .worktree
        case .external: .standalone
        }
    }
}
