import Foundation
import SwiftUI

/// Color for visual project identification in the sidebar.
enum ProjectColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, pink

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        }
    }
}

/// Classification of a workspace's relationship to its project's git repo.
enum WorkspaceType: String, Codable, Sendable {
    case mainCheckout
    case worktree
    case external

    var label: String {
        switch self {
        case .mainCheckout: return "Main"
        case .worktree: return "Worktree"
        case .external: return "External"
        }
    }

    var icon: String {
        switch self {
        case .mainCheckout: return "folder.fill"
        case .worktree: return "arrow.triangle.branch"
        case .external: return "folder"
        }
    }
}

/// A worktree on disk with no corresponding workspace data.
struct OrphanedWorktree: Identifiable {
    let id = UUID()
    let path: String
    let branchName: String?
    let projectId: UUID
}

/// Codable snapshot of a `Project`, used for persistence.
/// Decoupled from the `@MainActor` class so Codable conformance doesn't
/// fight Swift 6 strict concurrency.
struct ProjectSnapshot: Codable, Sendable {
    let id: UUID
    let repositoryPath: String
    let isCatchAll: Bool
    let displayName: String
    let mainBranch: String
    let workspaceIds: [UUID]
    let isExpanded: Bool
    let color: ProjectColor?
    var collapsedStackIds: Set<String>?
    var worktreeSetupCommand: String?

    private enum CodingKeys: String, CodingKey {
        case id, repositoryPath, displayName, mainBranch, color, worktreeSetupCommand
        case isCatchAll, workspaceIds, isExpanded, collapsedStackIds
    }

    init(
        id: UUID, repositoryPath: String, isCatchAll: Bool = false, displayName: String,
        mainBranch: String, workspaceIds: [UUID] = [], isExpanded: Bool = true,
        color: ProjectColor?, collapsedStackIds: Set<String>? = nil, worktreeSetupCommand: String? = nil
    ) {
        self.id = id
        self.repositoryPath = repositoryPath
        self.isCatchAll = isCatchAll
        self.displayName = displayName
        self.mainBranch = mainBranch
        self.workspaceIds = workspaceIds
        self.isExpanded = isExpanded
        self.color = color
        self.collapsedStackIds = collapsedStackIds
        self.worktreeSetupCommand = worktreeSetupCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        repositoryPath = try container.decode(String.self, forKey: .repositoryPath)
        displayName = try container.decode(String.self, forKey: .displayName)
        mainBranch = try container.decode(String.self, forKey: .mainBranch)
        color = try container.decodeIfPresent(ProjectColor.self, forKey: .color)
        worktreeSetupCommand = try container.decodeIfPresent(String.self, forKey: .worktreeSetupCommand)
        isCatchAll = try container.decodeIfPresent(Bool.self, forKey: .isCatchAll) ?? false
        workspaceIds = try container.decodeIfPresent([UUID].self, forKey: .workspaceIds) ?? []
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        collapsedStackIds = try container.decodeIfPresent(Set<String>.self, forKey: .collapsedStackIds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(repositoryPath, forKey: .repositoryPath)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(mainBranch, forKey: .mainBranch)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encodeIfPresent(worktreeSetupCommand, forKey: .worktreeSetupCommand)

    }

}

/// Shared repository identity and configuration, independent of navigation placement.
@MainActor
final class Project: Identifiable, ObservableObject {
    let id: UUID
    let repositoryPath: String
    @Published var displayName: String
    @Published var mainBranch: String
    @Published var color: ProjectColor?
    @Published var worktreeSetupCommand: String?

    init(repositoryPath: String, displayName: String? = nil, mainBranch: String) {
        self.id = UUID()
        self.repositoryPath = repositoryPath
        self.displayName = displayName ?? (repositoryPath as NSString).lastPathComponent
        self.mainBranch = mainBranch
    }

    init(snapshot: ProjectSnapshot) {
        id = snapshot.id
        repositoryPath = snapshot.repositoryPath
        displayName = snapshot.displayName
        mainBranch = snapshot.mainBranch
        color = snapshot.color
        worktreeSetupCommand = try? WorktreeSetupCommand.validated(snapshot.worktreeSetupCommand ?? "")
    }

    func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            id: id, repositoryPath: repositoryPath,
            displayName: displayName, mainBranch: mainBranch, color: color, worktreeSetupCommand: worktreeSetupCommand)
    }
}
