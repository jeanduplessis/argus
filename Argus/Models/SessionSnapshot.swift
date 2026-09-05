import Foundation

/// Codable snapshot of a workspace for minimal Phase 2 persistence.
///
/// This intentionally stores only durable project/workspace metadata and the
/// number of terminal panels needed to reopen a basic tab set. It does not
/// include Phase 4 scrollback or browser restoration state.
struct WorkspaceSnapshot: Codable, Sendable {
    static let maximumTerminalPanels = 128
    let id: UUID
    let projectId: UUID?
    let branchName: String?
    let workspaceType: WorkspaceType
    let worktreePath: String?
    let title: String
    let customTitle: String?
    let currentDirectory: String
    let panelCount: Int
    let terminalDirectories: [String]
    let terminalCustomTitles: [String?]

    var restoredTerminalDirectories: [String] {
        let total = max(panelCount, 0)
        let sanitized =
            terminalDirectories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if sanitized.count >= total {
            return Array(sanitized.prefix(total))
        }

        return sanitized + Array(repeating: currentDirectory, count: total - sanitized.count)
    }

    var restoredTerminalCustomTitles: [String?] {
        let total = restoredTerminalDirectories.count
        let sanitized = terminalCustomTitles.map { title -> String? in
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        if sanitized.count >= total {
            return Array(sanitized.prefix(total))
        }
        return sanitized + Array(repeating: nil, count: total - sanitized.count)
    }

    init(
        id: UUID,
        projectId: UUID?,
        branchName: String?,
        workspaceType: WorkspaceType,
        worktreePath: String?,
        title: String,
        customTitle: String?,
        currentDirectory: String,
        panelCount: Int,
        terminalDirectories: [String]? = nil,
        terminalCustomTitles: [String?]? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.branchName = branchName
        self.workspaceType = workspaceType
        self.worktreePath = worktreePath
        self.title = title
        self.customTitle = customTitle
        self.currentDirectory = currentDirectory
        let safePanelCount = min(max(panelCount, 0), Self.maximumTerminalPanels)
        self.panelCount = safePanelCount
        self.terminalDirectories =
            terminalDirectories.map { Array($0.prefix(Self.maximumTerminalPanels)) }
            ?? Array(
                repeating: currentDirectory,
                count: safePanelCount
            )
        self.terminalCustomTitles =
            terminalCustomTitles.map { Array($0.prefix(Self.maximumTerminalPanels)) }
            ?? Array(
                repeating: nil,
                count: safePanelCount
            )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case branchName
        case workspaceType
        case worktreePath
        case title
        case customTitle
        case currentDirectory
        case panelCount
        case terminalDirectories
        case terminalCustomTitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let projectId = try container.decodeIfPresent(UUID.self, forKey: .projectId)
        let branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        let workspaceType = try container.decode(WorkspaceType.self, forKey: .workspaceType)
        let worktreePath = try container.decodeIfPresent(String.self, forKey: .worktreePath)
        let title = try container.decode(String.self, forKey: .title)
        let customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        let currentDirectory = try container.decode(String.self, forKey: .currentDirectory)
        let panelCount = try container.decode(Int.self, forKey: .panelCount)
        guard panelCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .panelCount,
                in: container,
                debugDescription: "Terminal Panel count cannot be negative"
            )
        }
        let terminalDirectories = try Self.decodeTerminalDirectories(from: container)
        let terminalCustomTitles = try Self.decodeTerminalCustomTitles(from: container)

        self.init(
            id: id,
            projectId: projectId,
            branchName: branchName,
            workspaceType: workspaceType,
            worktreePath: worktreePath,
            title: title,
            customTitle: customTitle,
            currentDirectory: currentDirectory,
            panelCount: panelCount,
            terminalDirectories: terminalDirectories,
            terminalCustomTitles: terminalCustomTitles
        )
    }

    private static func decodeTerminalDirectories(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String]? {
        guard container.contains(.terminalDirectories) else { return nil }
        var values = try container.nestedUnkeyedContainer(forKey: .terminalDirectories)
        var result: [String] = []
        result.reserveCapacity(min(values.count ?? 0, maximumTerminalPanels))
        while !values.isAtEnd {
            let value = try values.decode(String.self)
            if result.count < maximumTerminalPanels {
                result.append(value)
            }
        }
        return result
    }

    private static func decodeTerminalCustomTitles(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String?]? {
        guard container.contains(.terminalCustomTitles) else { return nil }
        var values = try container.nestedUnkeyedContainer(forKey: .terminalCustomTitles)
        var result: [String?] = []
        result.reserveCapacity(min(values.count ?? 0, maximumTerminalPanels))
        while !values.isAtEnd {
            let value: String?
            if try values.decodeNil() {
                value = nil
            } else {
                value = try values.decode(String.self)
            }
            if result.count < maximumTerminalPanels {
                result.append(value)
            }
        }
        return result
    }
}

/// Versioned minimal application session snapshot for Phase 2 persistence.
struct ArgusSessionSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let selectedWorkspaceId: UUID?
    let projects: [ProjectSnapshot]
    let workspaces: [WorkspaceSnapshot]
    let collections: [ProjectCollection]?
    let ungroupedWorkspaceIds: [UUID]
    let ungroupedRepositoryDisclosure: [RepositoryDisclosure]

    var isCompatible: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    func isValidForRestore(maxWorkspaces: Int) -> Bool {
        guard isCompatible || schemaVersion == 1,
            !workspaces.isEmpty,
            workspaces.count <= maxWorkspaces,
            projects.count <= maxWorkspaces + 1,
            Set(workspaces.map(\.id)).count == workspaces.count,
            Set(projects.map(\.id)).count == projects.count,
            workspaces.allSatisfy({
                (0...WorkspaceSnapshot.maximumTerminalPanels).contains($0.panelCount)
                    && $0.terminalDirectories.count <= WorkspaceSnapshot.maximumTerminalPanels
                    && $0.terminalCustomTitles.count <= WorkspaceSnapshot.maximumTerminalPanels
            }),
            workspaces.reduce(0, { $0 + $1.panelCount })
                <= maxWorkspaces * WorkspaceSnapshot.maximumTerminalPanels
        else { return false }
        return true
    }

    /// Returns a restore-safe snapshot with project/workspace cross-references
    /// reconciled according to the Phase 2 sidebar hierarchy rules.
    func reconciledForRestore() -> ArgusSessionSnapshot {
        SessionSnapshotReconciler(snapshot: self).reconcile()
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        selectedWorkspaceId: UUID?,
        projects: [ProjectSnapshot],
        workspaces: [WorkspaceSnapshot],
        collections: [ProjectCollection]? = nil,
        ungroupedWorkspaceIds: [UUID] = [],
        ungroupedRepositoryDisclosure: [RepositoryDisclosure] = []
    ) {
        self.schemaVersion = schemaVersion
        self.selectedWorkspaceId = selectedWorkspaceId
        self.projects = projects
        self.workspaces = workspaces
        self.collections = collections.map(ProjectCollection.bounded)
        self.ungroupedWorkspaceIds = ungroupedWorkspaceIds
        self.ungroupedRepositoryDisclosure = ungroupedRepositoryDisclosure
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, selectedWorkspaceId, projects, workspaces, collections
        case ungroupedWorkspaceIds, ungroupedRepositoryDisclosure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var ids: [UUID] = []
        if var values = try? container.nestedUnkeyedContainer(forKey: .ungroupedWorkspaceIds) {
            while !values.isAtEnd {
                let element = try values.superDecoder()
                if let id = try? UUID(from: element), ids.count < 128 { ids.append(id) }
            }
        }
        ungroupedWorkspaceIds = ids
        ungroupedRepositoryDisclosure =
            (try? RepositoryDisclosure.decodeList(
                from: container.superDecoder(forKey: .ungroupedRepositoryDisclosure))) ?? []
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
        projects = try container.decode([ProjectSnapshot].self, forKey: .projects)
        workspaces = try container.decode([WorkspaceSnapshot].self, forKey: .workspaces)
        if container.contains(.collections), try !container.decodeNil(forKey: .collections) {
            collections = (try? ProjectCollection.decodeList(from: container.superDecoder(forKey: .collections))) ?? []
        } else {
            collections = nil
        }
    }
}

private struct SessionSnapshotReconciler {
    let snapshot: ArgusSessionSnapshot

    func reconcile() -> ArgusSessionSnapshot {
        let projects = snapshot.projects.filter { !$0.isCatchAll }
        let projectIds = Set(projects.map(\.id))
        let workspaces = snapshot.workspaces.map { workspace in
            WorkspaceSnapshot(
                id: workspace.id, projectId: workspace.projectId.flatMap { projectIds.contains($0) ? $0 : nil },
                branchName: workspace.branchName, workspaceType: workspace.workspaceType,
                worktreePath: workspace.worktreePath, title: workspace.title, customTitle: workspace.customTitle,
                currentDirectory: workspace.currentDirectory, panelCount: workspace.panelCount,
                terminalDirectories: workspace.terminalDirectories, terminalCustomTitles: workspace.terminalCustomTitles
            )
        }
        let workspaceIds = Set(workspaces.map(\.id))
        var collections = ProjectCollection.bounded(snapshot.collections ?? [])
        var ungrouped = snapshot.ungroupedWorkspaceIds
        var disclosure = snapshot.ungroupedRepositoryDisclosure
        if snapshot.schemaVersion == 1 {
            let imported = legacyPlacement(projects: projects, workspaces: workspaces, collections: collections)
            collections = imported.collections
            ungrouped = imported.ungrouped
            disclosure = imported.disclosure
        }
        collections = ProjectCollection.reconciled(collections, validWorkspaceIds: workspaceIds)
        var placed = Set(collections.flatMap(\.workspaceIds))
        ungrouped = (ungrouped + workspaces.map(\.id)).filter {
            workspaceIds.contains($0) && placed.insert($0).inserted
        }
        for index in collections.indices {
            collections[index].repositoryDisclosure = RepositoryDisclosure.reconciled(
                collections[index].repositoryDisclosure, projectIds: projectIds)
        }
        return ArgusSessionSnapshot(
            selectedWorkspaceId: snapshot.selectedWorkspaceId.flatMap { workspaceIds.contains($0) ? $0 : nil }
                ?? workspaces.first?.id,
            projects: projects.map { project in
                ProjectSnapshot(
                    id: project.id, repositoryPath: project.repositoryPath,
                    displayName: project.displayName, mainBranch: project.mainBranch, color: project.color,
                    worktreeSetupCommand: try? WorktreeSetupCommand.validated(project.worktreeSetupCommand ?? ""))
            }, workspaces: workspaces, collections: collections,
            ungroupedWorkspaceIds: ungrouped,
            ungroupedRepositoryDisclosure: RepositoryDisclosure.reconciled(disclosure, projectIds: projectIds))
    }

    private struct LegacyPlacement {
        let collections: [ProjectCollection]
        let ungrouped: [UUID]
        let disclosure: [RepositoryDisclosure]
    }

    private func legacyPlacement(
        projects: [ProjectSnapshot], workspaces: [WorkspaceSnapshot],
        collections original: [ProjectCollection]
    ) -> LegacyPlacement {
        var collections = original
        // Reconcile legacy resource membership using Workspace.projectId,
        // then expand the old manual Project order (never discovered Stack order).
        func orderedMembers(_ project: ProjectSnapshot) -> [UUID] {
            let members = workspaces.filter {
                project.isCatchAll ? $0.projectId == nil : $0.projectId == project.id
            }
            let validIds = Set(members.map(\.id))
            var seen = Set<UUID>()
            return (project.workspaceIds + members.map(\.id)).filter {
                validIds.contains($0) && seen.insert($0).inserted
            }
        }
        func legacyDisclosure(_ project: ProjectSnapshot) -> RepositoryDisclosure {
            RepositoryDisclosure(
                projectId: project.id, isExpanded: project.isExpanded,
                collapsedStackIds: Set((project.collapsedStackIds ?? []).sorted().prefix(128)))
        }
        var seenProjects = Set<UUID>()
        for index in collections.indices {
            let members = collections[index].legacyProjectIds.compactMap { id in
                projects.first { $0.id == id }
            }.filter { seenProjects.insert($0.id).inserted }
            collections[index].workspaceIds = members.flatMap(orderedMembers)
            collections[index].repositoryDisclosure = members.map(legacyDisclosure)
        }
        let otherProjects = projects.filter { !seenProjects.contains($0.id) }
        var ungrouped = otherProjects.flatMap(orderedMembers)
        if let catchAll = snapshot.projects.first(where: \.isCatchAll) {
            ungrouped += orderedMembers(catchAll)
        }
        return LegacyPlacement(
            collections: collections, ungrouped: ungrouped, disclosure: otherProjects.map(legacyDisclosure))
    }
}
