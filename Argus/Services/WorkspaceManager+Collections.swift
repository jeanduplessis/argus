import Foundation

extension WorkspaceManager {
    func collection(containing workspaceId: UUID) -> ProjectCollection? {
        collections.first { $0.workspaceIds.contains(workspaceId) }
    }

    func manualWorkspaceIds(in collectionId: UUID?) -> [UUID] {
        guard let collectionId else { return ungroupedWorkspaceIds }
        return collections.first { $0.id == collectionId }?.workspaceIds ?? []
    }

    func workspaceIds(for project: Project) -> [UUID] {
        workspaces.filter { $0.projectId == project.id }.map(\.id)
    }

    /// The fully expanded projection is the sole navigation order. Repository
    /// blocks occupy their first manual member; discovery never rewrites placement.
    var navigationSections: [WorkspaceNavigationSection] {
        (collections.map { Optional($0.id) } + [nil]).map { sectionId in
            let ids = manualWorkspaceIds(in: sectionId)
            var seenProjects = Set<UUID>()
            let blocks = ids.compactMap { id -> WorkspaceNavigationBlock? in
                guard let workspace = workspaces.first(where: { $0.id == id }) else { return nil }
                guard let project = project(for: id) else {
                    return WorkspaceNavigationBlock(project: nil, items: [.workspace(workspace.id)])
                }
                guard seenProjects.insert(project.id).inserted else { return nil }
                return WorkspaceNavigationBlock(project: project, items: sidebarItems(for: project, in: sectionId))
            }
            return WorkspaceNavigationSection(id: sectionId, blocks: blocks)
        }
    }

    func repositoryDisclosure(for projectId: UUID, in collectionId: UUID?) -> RepositoryDisclosure {
        let records =
            collectionId.flatMap { id in collections.first { $0.id == id }?.repositoryDisclosure }
            ?? ungroupedRepositoryDisclosure
        return records.first { $0.projectId == projectId } ?? RepositoryDisclosure(projectId: projectId)
    }

    func updateRepositoryDisclosure(
        for projectId: UUID, in collectionId: UUID?, _ update: (inout RepositoryDisclosure) -> Void
    ) {
        var record = repositoryDisclosure(for: projectId, in: collectionId)
        update(&record)
        if let collectionId {
            guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
            collections[index].repositoryDisclosure.removeAll { $0.projectId == projectId }
            collections[index].repositoryDisclosure.append(record)
        } else {
            ungroupedRepositoryDisclosure.removeAll { $0.projectId == projectId }
            ungroupedRepositoryDisclosure.append(record)
        }
    }

    func toggleRepository(_ projectId: UUID, in collectionId: UUID?) {
        pendingWorkspaceStackReveal = nil
        updateRepositoryDisclosure(for: projectId, in: collectionId) { $0.isExpanded.toggle() }
        saveSession()
    }

    var canCreateCollection: Bool { collections.count < ProjectCollection.maximumCount }

    @discardableResult
    func createCollection(name: String) -> ProjectCollection? {
        guard canCreateCollection, let name = ProjectCollection.normalizedName(name) else { return nil }
        let collection = ProjectCollection(name: name)
        collections.append(collection)
        saveSession()
        return collection
    }

    @discardableResult
    func renameCollection(_ collectionId: UUID, name: String) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }),
            let name = ProjectCollection.normalizedName(name)
        else { return false }
        collections[index].name = name
        saveSession()
        return true
    }

    func toggleCollection(_ collectionId: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        pendingWorkspaceStackReveal = nil
        collections[index].isExpanded.toggle()
        saveSession()
    }

    func revealCollection(containing workspaceId: UUID) {
        guard let index = collections.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }) else { return }
        collections[index].isExpanded = true
    }

    func removeCollection(_ collectionId: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collectionId }) else { return }
        pendingWorkspaceStackReveal = nil
        ungroupedWorkspaceIds += collections.remove(at: index).workspaceIds
        saveSession()
    }

    func validateCreationDestination(_ collectionId: UUID?) -> Bool {
        guard collectionId == nil || collections.contains(where: { $0.id == collectionId }) else {
            lastWorkspaceCreationError = .worktreeCreationFailed(
                "The destination Collection was removed. Choose a new destination.")
            return false
        }
        return true
    }

    func appendPlacement(_ workspaceId: UUID, to collectionId: UUID?) {
        if let collectionId, let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].workspaceIds.append(workspaceId)
        } else {
            ungroupedWorkspaceIds.append(workspaceId)
        }
    }

    func removePlacement(_ workspaceId: UUID) {
        pendingWorkspaceStackReveal = nil
        ungroupedWorkspaceIds.removeAll { $0 == workspaceId }
        for index in collections.indices { collections[index].workspaceIds.removeAll { $0 == workspaceId } }
    }

    func setManualWorkspaceIds(_ ids: [UUID], in collectionId: UUID?) {
        if let collectionId, let index = collections.firstIndex(where: { $0.id == collectionId }) {
            collections[index].workspaceIds = ids
        } else if collectionId == nil {
            ungroupedWorkspaceIds = ids
        }
    }

    /// Individual placement never changes repository association or content.
    @discardableResult
    func moveWorkspace(_ workspaceId: UUID, toCollection collectionId: UUID?, at insertionIndex: Int? = nil) -> Bool {
        guard workspaces.contains(where: { $0.id == workspaceId }),
            collectionId == nil || collections.contains(where: { $0.id == collectionId })
        else { return false }
        let previous = manualWorkspaceIds(in: collectionId)
        var next = previous.filter { $0 != workspaceId }
        let index = insertionIndex ?? next.count
        guard (0...next.count).contains(index) else { return false }
        next.insert(workspaceId, at: index)
        guard collection(containing: workspaceId)?.id != collectionId || previous != next else { return false }
        removePlacement(workspaceId)
        setManualWorkspaceIds(next, in: collectionId)
        saveSession()
        return true
    }

    func canMoveCollection(_ collectionId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
            let index = collections.firstIndex(where: { $0.id == collectionId })
        else { return false }
        return collections.indices.contains(index + offset)
    }

    @discardableResult
    func moveCollection(_ collectionId: UUID, offset: Int) -> Bool {
        guard canMoveCollection(collectionId, offset: offset),
            let index = collections.firstIndex(where: { $0.id == collectionId })
        else { return false }
        return reorderCollection(collectionId, to: index + offset)
    }

    @discardableResult
    func reorderCollection(_ collectionId: UUID, to index: Int) -> Bool {
        guard let source = collections.firstIndex(where: { $0.id == collectionId }),
            collections.indices.contains(index), source != index
        else { return false }
        pendingWorkspaceStackReveal = nil
        collections.insert(collections.remove(at: source), at: index)
        saveSession()
        return true
    }
    func restoreSelectionAfterRemovingWorkspaces(_ removedIds: Set<UUID>, previousOrder: [UUID]) {
        guard let selectedWorkspaceId, removedIds.contains(selectedWorkspaceId) else { return }
        if workspaces.isEmpty {
            let workspace = freshStandaloneWorkspace(workingDirectory: automaticFallbackDirectory())
            workspaces.append(workspace)
            appendPlacement(workspace.id, to: nil)
            selectWorkspace(workspace.id)
            return
        }
        let survivingIds = Set(workspaces.map(\.id))
        let selectedIndex = previousOrder.firstIndex(of: selectedWorkspaceId) ?? 0
        let replacementId =
            previousOrder.dropFirst(selectedIndex + 1).first(where: survivingIds.contains)
            ?? previousOrder.prefix(selectedIndex).last(where: survivingIds.contains)
            ?? sidebarOrderedWorkspaces.first?.workspace.id
            ?? workspaces.first?.id
        if let replacementId {
            selectWorkspace(replacementId)
        }
    }
}
