import Foundation

/// One fully expanded Collection or the final ungrouped section.
public struct WorkspaceListSection: Codable, Sendable {
    /// Both fields are nil for ungrouped placement; empty Collections remain present.
    public let collectionId: String?
    public let name: String?
    public let items: [WorkspaceSectionListItem]

    public init(collectionId: String?, name: String?, items: [WorkspaceSectionListItem]) {
        self.collectionId = collectionId
        self.name = name
        self.items = items
    }
}

/// A section-local repository block or a direct Standalone Workspace row.
public enum WorkspaceSectionListItem: Codable, Sendable {
    case project(ProjectListEntry)
    case workspace(WorkspaceListEntry)

    private enum Kind: String, Codable { case project, workspace }
    private enum CodingKeys: String, CodingKey { case kind, project, workspace }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .project:
            self = .project(try container.decode(ProjectListEntry.self, forKey: .project))
        case .workspace:
            self = .workspace(try container.decode(WorkspaceListEntry.self, forKey: .workspace))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .project(let project):
            try container.encode(Kind.project, forKey: .kind)
            try container.encode(project, forKey: .project)
        case .workspace(let workspace):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(workspace, forKey: .workspace)
        }
    }
}
