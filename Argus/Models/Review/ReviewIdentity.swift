import Foundation

struct RepositoryIdentity: Codable, Hashable, Sendable, Comparable {
    let provider: String
    let host: String
    let owner: String
    let name: String

    init(provider: String = "github", host: String, owner: String, name: String) {
        self.provider = Self.normalize(provider)
        self.host = Self.normalizeHost(host)
        self.owner = Self.normalize(owner)
        self.name = Self.normalize(name)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func normalizeHost(_ host: String) -> String {
        normalize(host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// Provider-neutral validation for values restored from Review Session State.
    /// GitHub-specific command construction remains owned by the provider.
    var isValid: Bool {
        provider == "github"
            && Self.isSafeHost(host)
            && Self.isSafePathSegment(owner)
            && Self.isSafePathSegment(name)
    }

    private static func isSafeHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private static func isSafePathSegment(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private enum CodingKeys: String, CodingKey { case provider, host, owner, name }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try values.decode(String.self, forKey: .provider),
            host: try values.decode(String.self, forKey: .host),
            owner: try values.decode(String.self, forKey: .owner),
            name: try values.decode(String.self, forKey: .name)
        )
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.provider, lhs.host, lhs.owner, lhs.name) < (rhs.provider, rhs.host, rhs.owner, rhs.name)
    }
}

/// Provider data retained with a hosted Repository Identity. This deliberately
/// contains no credential or local-checkout information.
struct RepositoryProviderMetadata: Codable, Hashable, Sendable {
    let provider: String
    let accountLogin: String?

    init(provider: String, accountLogin: String? = nil) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accountLogin = accountLogin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty
    }

    /// Metadata is safe to retain only when its optional account coordinate can
    /// be used as a provider account argument. The provider itself is repaired
    /// from the authoritative Repository Identity during session restoration.
    var hasSafeAccountLogin: Bool {
        guard let accountLogin else { return true }
        return !accountLogin.isEmpty
            && accountLogin.count <= 39
            && accountLogin.first != "-"
            && accountLogin.last != "-"
            && accountLogin.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
    }

    var isValid: Bool {
        provider == "github" && hasSafeAccountLogin
    }

    private enum CodingKeys: String, CodingKey {
        case provider, accountLogin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            provider: try values.decode(String.self, forKey: .provider),
            accountLogin: try values.decodeIfPresent(String.self, forKey: .accountLogin)
        )
    }
}

/// The small cross-mode Project reference exposed by WorkspaceManager.
/// Views and review services use this instead of reaching into Code Project state.
struct SharedProjectReference: Codable, Hashable, Sendable {
    let projectID: UUID
    let displayName: String
    let repositoryIdentity: RepositoryIdentity
    let providerMetadata: RepositoryProviderMetadata
}

/// Review Work Mode's durable record for a Project. `projectID` is shared with
/// a Named Project when a local Project Repository Root has been associated.
struct ReviewProject: Codable, Hashable, Sendable, Identifiable {
    var id: UUID { projectID }
    let projectID: UUID
    var repositoryIdentity: RepositoryIdentity
    var displayName: String
    var providerMetadata: RepositoryProviderMetadata

    init(
        projectID: UUID = UUID(),
        repositoryIdentity: RepositoryIdentity,
        displayName: String? = nil,
        providerMetadata: RepositoryProviderMetadata? = nil
    ) {
        self.projectID = projectID
        self.repositoryIdentity = repositoryIdentity
        self.displayName =
            displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? repositoryIdentity.name
        self.providerMetadata = providerMetadata ?? .init(provider: repositoryIdentity.provider)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct PullRequestIdentity: Codable, Hashable, Sendable, Comparable {
    let repository: RepositoryIdentity
    let number: Int

    init(repository: RepositoryIdentity, number: Int) {
        self.repository = repository
        self.number = number
    }

    var isValid: Bool { repository.isValid && number > 0 }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.repository == rhs.repository ? lhs.number < rhs.number : lhs.repository < rhs.repository
    }
}

struct ReviewRevision: Codable, Hashable, Sendable {
    let baseCommit: String
    let headCommit: String

    init(baseCommit: String, headCommit: String) {
        self.baseCommit = baseCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headCommit = headCommit.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case baseCommit
        case headCommit
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseCommit: try values.decode(String.self, forKey: .baseCommit),
            headCommit: try values.decode(String.self, forKey: .headCommit)
        )
    }

    /// The provider-compatible wire form for commits used in GitHub CLI
    /// arguments. Short provider identifiers remain valid for test fixtures and
    /// provider responses; separators and whitespace do not.
    static func isProviderSafeCommit(_ commit: String) -> Bool {
        let value = commit.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value.count <= 128
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
            }
    }

    var isValid: Bool {
        Self.isProviderSafeCommit(baseCommit) && Self.isProviderSafeCommit(headCommit)
    }
}
