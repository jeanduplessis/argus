import Foundation

extension WorkspaceManager {
    struct PendingWorkspaceStackReveal {
        let project: Project
        let workspaceId: UUID
        let path: String
        let revision: UInt64
        let collectionId: UUID?
    }

    func sidebarItems(for project: Project, in collectionId: UUID? = nil) -> [WorkspaceSidebarItem] {
        let inputs = workspaceIds(for: project).compactMap { workspaceId -> WorkspaceStackWorkspace? in
            guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
            return WorkspaceStackWorkspace(id: workspaceId, path: workspaceStackPath(for: workspace, in: project))
        }
        let byId = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
        let local = manualWorkspaceIds(in: collectionId).compactMap { byId[$0] }
        return WorkspaceStackLayout.items(
            workspaces: local, snapshot: workspaceStackSnapshots[project.id],
            mainBranch: project.mainBranch, repositoryWorkspaces: inputs)
    }

    func stackGroup(for workspaceId: UUID, in projectId: UUID) -> WorkspaceStackGroup? {
        guard let project = projects.first(where: { $0.id == projectId }) else { return nil }
        for item in sidebarItems(for: project, in: collection(containing: workspaceId)?.id) {
            if case .stack(let group) = item, group.workspaceIds.contains(workspaceId) { return group }
        }
        return nil
    }

    func cancelPendingWorkspaceStackReveal(in projectId: UUID) {
        if pendingWorkspaceStackReveal?.project.id == projectId {
            pendingWorkspaceStackReveal = nil
        }
    }

    func retainPendingWorkspaceStackRevealIfNeeded(for workspace: Workspace) {
        guard isObservingWorkspaceStacks,
            selectedWorkspaceId == workspace.id,
            let project = project(for: workspace.id),
            workspace.projectId == project.id,
            let path = workspaceStackPath(for: workspace, in: project),
            workspaceStackSnapshots[project.id]?.worktrees.contains(where: { $0.path == path }) != true
        else { return }
        pendingWorkspaceStackReveal = PendingWorkspaceStackReveal(
            project: project, workspaceId: workspace.id, path: path, revision: workspaceRevealRevision,
            collectionId: collection(containing: workspace.id)?.id)
        refreshWorkspaceStacks(in: project.id)
    }

    func toggleWorkspaceStack(_ stackId: String, in projectId: UUID, collectionId: UUID? = nil) {
        pendingWorkspaceStackReveal = nil
        updateRepositoryDisclosure(for: projectId, in: collectionId) { disclosure in
            if !disclosure.collapsedStackIds.insert(stackId).inserted { disclosure.collapsedStackIds.remove(stackId) }
        }
        saveSession()
    }

    func canMoveWorkspace(in projectId: UUID?, moving workspaceId: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1 else { return false }
        let sectionId = collection(containing: workspaceId)?.id
        let items = movableItems(projectId: projectId, in: sectionId)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }) else { return false }
        return items.indices.contains(source + offset)
    }

    @discardableResult
    func moveWorkspace(in projectId: UUID?, moving workspaceId: UUID, offset: Int) -> Bool {
        guard canMoveWorkspace(in: projectId, moving: workspaceId, offset: offset) else { return false }
        let sectionId = collection(containing: workspaceId)?.id
        var items = movableItems(projectId: projectId, in: sectionId)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }) else { return false }
        return reorderSidebarItems(items, from: source, to: source + offset, in: sectionId)
    }

    @discardableResult
    func reorderWorkspace(in projectId: UUID?, moving workspaceId: UUID, before targetWorkspaceId: UUID) -> Bool {
        let sectionId = collection(containing: workspaceId)?.id
        guard collection(containing: targetWorkspaceId)?.id == sectionId,
            project(for: workspaceId)?.id == projectId, project(for: targetWorkspaceId)?.id == projectId
        else { return false }
        let items = movableItems(projectId: projectId, in: sectionId)
        guard let source = items.firstIndex(where: { $0.workspaceIds.contains(workspaceId) }),
            let target = items.firstIndex(where: { $0.workspaceIds.contains(targetWorkspaceId) }), source != target
        else { return false }
        return reorderSidebarItems(items, from: source, to: source < target ? target - 1 : target, in: sectionId)
    }

    private func reorderSidebarItems(
        _ original: [WorkspaceSidebarItem], from source: Int, to destination: Int,
        in sectionId: UUID?
    ) -> Bool {
        guard source != destination else { return false }
        var items = original
        items.insert(items.remove(at: source), at: destination)
        // Only reorder slots occupied by this repository. Keep raw manual order
        // within each Stack, rather than persisting the discovered parent order.
        let manual = manualWorkspaceIds(in: sectionId)
        let reordered = items.flatMap { item in manual.filter { item.workspaceIds.contains($0) } }
        let movedIds = Set(reordered)
        var iterator = reordered.makeIterator()
        setManualWorkspaceIds(manual.map { movedIds.contains($0) ? iterator.next()! : $0 }, in: sectionId)
        pendingWorkspaceStackReveal = nil
        saveSession()
        return true
    }

    private func movableItems(projectId: UUID?, in collectionId: UUID?) -> [WorkspaceSidebarItem] {
        if let project = projects.first(where: { $0.id == projectId }) {
            return sidebarItems(for: project, in: collectionId)
        }
        return manualWorkspaceIds(in: collectionId).map { .workspace($0) }
    }

    func startWorkspaceStackObservations() {
        guard !isObservingWorkspaceStacks else { return }
        isObservingWorkspaceStacks = true
        reconcileWorkspaceStackObservations()
    }

    func stopWorkspaceStackObservations() {
        pendingWorkspaceStackReveal = nil
        isObservingWorkspaceStacks = false
        let observations = workspaceStackObservations.values.map(\.observation)
        workspaceStackObservations.removeAll()
        observations.forEach { $0.stop() }
        workspaceStackSnapshots.removeAll()
        workspaceStackErrors.removeAll()
        refreshingWorkspaceStackProjectIds.removeAll()
    }

    func refreshWorkspaceStacks(in projectId: UUID) {
        guard let entry = workspaceStackObservations[projectId],
            ownsWorkspaceStackObservation(entry.observation, for: entry.project)
        else { return }
        entry.observation.refresh()
    }

    func reconcileWorkspaceStackObservations() {
        guard isObservingWorkspaceStacks else { return }
        for (projectId, entry) in workspaceStackObservations
        where !projects.contains(where: { $0 === entry.project }) {
            cancelPendingWorkspaceStackReveal(in: projectId)
            workspaceStackObservations.removeValue(forKey: projectId)
            entry.observation.stop()
            workspaceStackSnapshots.removeValue(forKey: projectId)
            workspaceStackErrors.removeValue(forKey: projectId)
            refreshingWorkspaceStackProjectIds.remove(projectId)
        }
        for project in namedProjects where workspaceStackObservations[project.id] == nil {
            startWorkspaceStackObservation(for: project)
        }
    }

    private func startWorkspaceStackObservation(for project: Project) {
        let observation = WorkspaceStackObservation(
            repositoryPath: project.repositoryPath, reader: workspaceStackReader)
        workspaceStackObservations[project.id] = (project, observation)
        observation.start(
            onRefreshing: { [weak self, weak project, weak observation] isRefreshing in
                guard let self, let project, let observation,
                    self.ownsWorkspaceStackObservation(observation, for: project)
                else { return }
                if isRefreshing {
                    self.refreshingWorkspaceStackProjectIds.insert(project.id)
                } else {
                    self.refreshingWorkspaceStackProjectIds.remove(project.id)
                }
            },
            onResult: { [weak self, weak project, weak observation] result in
                guard let self, let project, let observation,
                    self.ownsWorkspaceStackObservation(observation, for: project)
                else { return }
                self.receiveWorkspaceStackResult(result, for: project)
            }
        )
    }

    private func ownsWorkspaceStackObservation(_ observation: WorkspaceStackObservation, for project: Project) -> Bool {
        isObservingWorkspaceStacks
            && projects.contains(where: { $0 === project })
            && workspaceStackObservations[project.id]?.observation === observation
    }

    private func receiveWorkspaceStackResult(_ result: Result<WorkspaceStackSnapshot, Error>, for project: Project) {
        switch result {
        case .success(let snapshot):
            workspaceStackSnapshots[project.id] = snapshot
            workspaceStackErrors[project.id] = snapshot.issue
            for workspace in workspaces where workspace.projectId == project.id {
                guard let path = workspaceStackPath(for: workspace, in: project),
                    let worktree = snapshot.worktrees.first(where: { $0.path == path })
                else { continue }
                if workspace.branchName != worktree.branch {
                    workspace.branchName = worktree.branch
                }
            }
            revealPendingWorkspaceStackIfReady(for: project, snapshot: snapshot)
        case .failure(let error):
            cancelPendingWorkspaceStackReveal(in: project.id)
            workspaceStackSnapshots.removeValue(forKey: project.id)
            workspaceStackErrors[project.id] = error.localizedDescription
        }
    }

    private func revealPendingWorkspaceStackIfReady(for project: Project, snapshot: WorkspaceStackSnapshot) {
        guard let pending = pendingWorkspaceStackReveal, pending.project === project else { return }
        guard selectedWorkspaceId == pending.workspaceId,
            workspaceRevealRevision == pending.revision,
            collection(containing: pending.workspaceId)?.id == pending.collectionId,
            repositoryDisclosure(for: project.id, in: pending.collectionId).isExpanded,
            collection(containing: pending.workspaceId)?.isExpanded != false,
            self.project(for: pending.workspaceId) === project,
            let workspace = workspaces.first(where: { $0.id == pending.workspaceId }),
            workspace.projectId == project.id,
            workspaceStackPath(for: workspace, in: project) == pending.path
        else {
            cancelPendingWorkspaceStackReveal(in: project.id)
            return
        }
        guard snapshot.worktrees.contains(where: { $0.path == pending.path }) else { return }
        pendingWorkspaceStackReveal = nil
        guard let group = stackGroup(for: workspace.id, in: project.id) else { return }
        updateRepositoryDisclosure(for: project.id, in: pending.collectionId) { $0.collapsedStackIds.remove(group.id) }
        workspaceRevealRevision &+= 1
    }

    private func workspaceStackPath(for workspace: Workspace, in project: Project) -> String? {
        let path: String?
        switch workspace.workspaceType {
        case .mainCheckout:
            path = project.repositoryPath
        case .worktree:
            path = workspace.worktreePath
        case .external:
            path = nil
        }
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
