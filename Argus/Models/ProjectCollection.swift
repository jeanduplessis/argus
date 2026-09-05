import Foundation

/// A non-owning, single-level navigation organizer. Workspace placement lives only here or in the ungrouped order.
struct ProjectCollection: Codable, Identifiable, Equatable, Sendable {
    static let maximumCount = 128
    static let maximumNameBytes = 4096

    let id: UUID
    var name: String
    var workspaceIds: [UUID]
    var isExpanded: Bool
    var repositoryDisclosure: [RepositoryDisclosure] = []
    // Schema-1 import only; never used by runtime placement.
    var legacyProjectIds: [UUID] = []

    init(id: UUID = UUID(), name: String, workspaceIds: [UUID] = [], isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.workspaceIds = workspaceIds
        self.isExpanded = isExpanded
    }

    static func normalizedName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumNameBytes else { return nil }
        return trimmed
    }

    /// Only valid, unique records consume the Collection limit.
    static func bounded(_ collections: [Self]) -> [Self] {
        var seenCollections = Set<UUID>()
        var result: [Self] = []
        for var collection in collections {
            guard result.count < maximumCount else { break }
            guard let name = normalizedName(collection.name),
                seenCollections.insert(collection.id).inserted
            else { continue }
            collection.name = name
            result.append(collection)
        }
        return result
    }

    /// First valid occurrence wins, both for identity and membership. Preserve
    /// empty user-created Collections; stale references do not delete an organizer.
    static func reconciled(_ collections: [Self], validWorkspaceIds: Set<UUID>) -> [Self] {
        var seenWorkspaces = Set<UUID>()
        return bounded(collections).map { collection in
            let members = collection.workspaceIds.filter {
                validWorkspaceIds.contains($0) && seenWorkspaces.insert($0).inserted
            }
            var result = collection
            result.workspaceIds = members
            result.legacyProjectIds = []
            return result
        }
    }

    static func decodeList(from decoder: Decoder) throws -> [Self] {
        var values = try decoder.unkeyedContainer()
        var result: [Self] = []
        var seenCollections = Set<UUID>()
        while !values.isAtEnd {
            // Consume each element before decoding so a malformed optional
            // record cannot reject the core session or stall this loop.
            let element = try values.superDecoder()
            guard result.count < maximumCount,
                var collection = try? Self(from: element),
                let name = normalizedName(collection.name),
                seenCollections.insert(collection.id).inserted
            else { continue }
            collection.name = name
            result.append(collection)
        }
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, workspaceIds, isExpanded, repositoryDisclosure
        case legacyProjectIds = "projectIds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isExpanded = (try? container.decode(Bool.self, forKey: .isExpanded)) ?? true
        var ids: [UUID] = []
        if var members = try? container.nestedUnkeyedContainer(forKey: .workspaceIds) {
            while !members.isAtEnd {
                let member = try members.superDecoder()
                if let id = try? UUID(from: member), ids.count < Self.maximumCount { ids.append(id) }
            }
        }
        workspaceIds = ids
        legacyProjectIds = Self.decodeIds(from: container, key: .legacyProjectIds)
        repositoryDisclosure =
            (try? RepositoryDisclosure.decodeList(from: container.superDecoder(forKey: .repositoryDisclosure))) ?? []
    }

    private static func decodeIds(from container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) -> [UUID] {
        var ids: [UUID] = []
        if var values = try? container.nestedUnkeyedContainer(forKey: key) {
            while !values.isAtEnd {
                guard let decoder = try? values.superDecoder() else { break }
                if let id = try? UUID(from: decoder), ids.count < maximumCount { ids.append(id) }
            }
        }
        return ids
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(workspaceIds, forKey: .workspaceIds)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(repositoryDisclosure, forKey: .repositoryDisclosure)
    }
}

/// Disclosure belongs to a repository's appearance in one navigation section.
struct RepositoryDisclosure: Codable, Equatable, Sendable {
    let projectId: UUID
    var isExpanded = true
    var collapsedStackIds: Set<String> = []

    private enum CodingKeys: String, CodingKey { case projectId, isExpanded, collapsedStackIds }

    init(projectId: UUID, isExpanded: Bool = true, collapsedStackIds: Set<String> = []) {
        self.projectId = projectId
        self.isExpanded = isExpanded
        self.collapsedStackIds = collapsedStackIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        isExpanded = (try? container.decode(Bool.self, forKey: .isExpanded)) ?? true
        var keys = Set<String>()
        if var values = try? container.nestedUnkeyedContainer(forKey: .collapsedStackIds) {
            while !values.isAtEnd {
                let value = try values.superDecoder()
                if let key = try? String(from: value), key.utf8.count <= 16384, keys.count < 128 { keys.insert(key) }
            }
        }
        collapsedStackIds = keys
    }
}

struct WorkspaceNavigationSection: Identifiable {
    let id: UUID?
    let blocks: [WorkspaceNavigationBlock]
    var workspaceIds: [UUID] { blocks.flatMap(\.workspaceIds) }
}

struct WorkspaceNavigationBlock: Identifiable {
    enum Identifier: Hashable {
        case repository(UUID)
        case workspace(UUID)
    }
    let project: Project?
    let items: [WorkspaceSidebarItem]
    var workspaceIds: [UUID] { items.flatMap(\.workspaceIds) }
    var id: Identifier { project.map { .repository($0.id) } ?? .workspace(workspaceIds[0]) }
}

extension RepositoryDisclosure {
    static func decodeList(from decoder: Decoder) throws -> [Self] {
        var values = try decoder.unkeyedContainer()
        var result: [Self] = []
        while !values.isAtEnd {
            let element = try values.superDecoder()
            if result.count < 128, let record = try? Self(from: element) { result.append(record) }
        }
        return result
    }

    static func reconciled(_ records: [Self], projectIds: Set<UUID>) -> [Self] {
        var seen = Set<UUID>()
        return records.prefix(128).filter { projectIds.contains($0.projectId) && seen.insert($0.projectId).inserted }
            .map { record in
                Self(
                    projectId: record.projectId, isExpanded: record.isExpanded,
                    collapsedStackIds: Set(
                        record.collapsedStackIds.filter { $0.utf8.count <= 16384 }.sorted().prefix(128)))
            }
    }
}
