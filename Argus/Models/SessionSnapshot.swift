import Foundation

/// Codable snapshot of a workspace for minimal Phase 2 persistence.
///
/// This intentionally stores only durable project/workspace metadata and the
/// number of terminal panels needed to reopen a basic tab set. It does not
/// include Phase 4 scrollback or browser restoration state.
struct WorkspaceSnapshot: Codable, Sendable {
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
        let total = max(panelCount, 1)
        let sanitized = terminalDirectories
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
        self.panelCount = panelCount
        self.terminalDirectories = terminalDirectories ?? Array(
            repeating: currentDirectory,
            count: max(panelCount, 1)
        )
        self.terminalCustomTitles = terminalCustomTitles ?? Array(
            repeating: nil,
            count: max(panelCount, 1)
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
        let terminalDirectories = try container.decodeIfPresent([String].self, forKey: .terminalDirectories)
        let terminalCustomTitles = try container.decodeIfPresent(
            [String?].self,
            forKey: .terminalCustomTitles
        )

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
}

/// Versioned minimal application session snapshot for Phase 2 persistence.
struct ArgusSessionSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let selectedWorkspaceId: UUID?
    let projects: [ProjectSnapshot]
    let workspaces: [WorkspaceSnapshot]

    var isCompatible: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    /// Returns a restore-safe snapshot with project/workspace cross-references
    /// reconciled according to the Phase 2 sidebar hierarchy rules.
    func reconciledForRestore() -> ArgusSessionSnapshot {
        let workspaceIds = Set(workspaces.map(\.id))
        let firstCatchAll = projects.first(where: \.isCatchAll) ?? ProjectSnapshot(
            id: UUID(),
            repositoryPath: "",
            isCatchAll: true,
            displayName: "Workspaces",
            mainBranch: "",
            workspaceIds: [],
            isExpanded: true,
            color: nil
        )
        let namedProjects = projects.filter { !$0.isCatchAll }
        let namedProjectIds = Set(namedProjects.map(\.id))

        let reconciledWorkspaces = workspaces.map { workspace in
            guard let projectId = workspace.projectId,
                  namedProjectIds.contains(projectId)
            else {
                return WorkspaceSnapshot(
                    id: workspace.id,
                    projectId: firstCatchAll.id,
                    branchName: workspace.branchName,
                    workspaceType: workspace.workspaceType,
                    worktreePath: workspace.worktreePath,
                    title: workspace.title,
                    customTitle: workspace.customTitle,
                    currentDirectory: workspace.currentDirectory,
                    panelCount: workspace.panelCount,
                    terminalDirectories: workspace.terminalDirectories,
                    terminalCustomTitles: workspace.terminalCustomTitles
                )
            }
            return workspace
        }
        let reconciledWorkspaceById = Dictionary(
            uniqueKeysWithValues: reconciledWorkspaces.map { ($0.id, $0) }
        )

        func orderedWorkspaceIds(for project: ProjectSnapshot) -> [UUID] {
            var seen = Set<UUID>()
            var ordered: [UUID] = []

            for workspaceId in project.workspaceIds where workspaceIds.contains(workspaceId) {
                guard let workspace = reconciledWorkspaceById[workspaceId],
                      workspace.projectId == project.id,
                      seen.insert(workspaceId).inserted
                else { continue }
                ordered.append(workspaceId)
            }

            for workspace in reconciledWorkspaces where workspace.projectId == project.id {
                guard seen.insert(workspace.id).inserted else { continue }
                ordered.append(workspace.id)
            }

            return ordered
        }

        let reconciledNamedProjects = namedProjects.map { project in
            ProjectSnapshot(
                id: project.id,
                repositoryPath: project.repositoryPath,
                isCatchAll: false,
                displayName: project.displayName,
                mainBranch: project.mainBranch,
                workspaceIds: orderedWorkspaceIds(for: project),
                isExpanded: project.isExpanded,
                color: project.color
            )
        }
        let reconciledCatchAll = ProjectSnapshot(
            id: firstCatchAll.id,
            repositoryPath: "",
            isCatchAll: true,
            displayName: firstCatchAll.displayName.isEmpty ? "Workspaces" : firstCatchAll.displayName,
            mainBranch: "",
            workspaceIds: orderedWorkspaceIds(for: firstCatchAll),
            isExpanded: firstCatchAll.isExpanded,
            color: firstCatchAll.color
        )
        let selectedId = selectedWorkspaceId.flatMap { workspaceIds.contains($0) ? $0 : nil }
            ?? reconciledWorkspaces.first?.id

        return ArgusSessionSnapshot(
            schemaVersion: schemaVersion,
            selectedWorkspaceId: selectedId,
            projects: reconciledNamedProjects + [reconciledCatchAll],
            workspaces: reconciledWorkspaces
        )
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        selectedWorkspaceId: UUID?,
        projects: [ProjectSnapshot],
        workspaces: [WorkspaceSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.selectedWorkspaceId = selectedWorkspaceId
        self.projects = projects
        self.workspaces = workspaces
    }
}
