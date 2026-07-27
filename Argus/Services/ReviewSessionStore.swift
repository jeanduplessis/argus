import Foundation
import CryptoKit

/// Owns durable Review Session State. Provider payloads live under a separate
/// cache directory so cache cleanup can never remove user-authored drafts.
actor ReviewSessionStore {
    enum StoreError: Error, Equatable {
        case invalidSnapshot
        case automaticWritesBlocked
        case unsupportedSnapshotSchema(Int)
        case generationExhausted
    }

    enum FileOperationFailure: Error, Equatable, Sendable {
        case setTemporaryPermissions
    }

    static let defaultSessionURL = ArgusRuntimeConfiguration.current.reviewSessionURL
    static let defaultCacheDirectoryURL = ArgusRuntimeConfiguration.current.reviewCacheDirectoryURL

    private let sessionURL: URL
    private let cacheDirectoryURL: URL
    private let fileManager: FileManager
    private let fileOperationFailure: FileOperationFailure?
    private let beforeOrderedRemoteCacheWrite: (@Sendable (ReviewRemoteCache, PullRequestIdentity, UInt64) async -> Void)?
    private var pendingSave: Task<Void, Never>?
    private var highestAcceptedGeneration: UInt64?
    private var highestRemoteCacheGeneration: [PullRequestIdentity: UInt64] = [:]
    private var nextImplicitGeneration: UInt64 = 0
    private var implicitGenerationExhausted = false
    private var lastScheduledSaveError: Error?
    private var automaticWritesBlocked = false
    private var unsupportedSnapshotSchema: Int?

    init(
        sessionURL: URL = ReviewSessionStore.defaultSessionURL,
        cacheDirectoryURL: URL = ReviewSessionStore.defaultCacheDirectoryURL,
        fileManager: FileManager = .default,
        fileOperationFailure: FileOperationFailure? = nil,
        beforeOrderedRemoteCacheWrite: (@Sendable (ReviewRemoteCache, PullRequestIdentity, UInt64) async -> Void)? = nil
    ) {
        self.sessionURL = sessionURL
        self.cacheDirectoryURL = cacheDirectoryURL
        self.fileManager = fileManager
        self.fileOperationFailure = fileOperationFailure
        self.beforeOrderedRemoteCacheWrite = beforeOrderedRemoteCacheWrite
    }

    func restore() throws -> ReviewSessionSnapshot {
        guard fileManager.fileExists(atPath: sessionURL.path) else { return .init() }
        do {
            try createSecureDirectory(sessionURL.deletingLastPathComponent())
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionURL.path)
            let data = try Data(contentsOf: sessionURL)
            let snapshot = try JSONDecoder().decode(ReviewSessionSnapshot.self, from: data)
            guard (1...ReviewSessionSnapshot.currentSchemaVersion).contains(snapshot.schemaVersion) else {
                unsupportedSnapshotSchema = snapshot.schemaVersion
                automaticWritesBlocked = true
                throw StoreError.unsupportedSnapshotSchema(snapshot.schemaVersion)
            }
            automaticWritesBlocked = false
            unsupportedSnapshotSchema = nil
            return snapshot.reconciledForRestore()
        } catch let error as StoreError {
            automaticWritesBlocked = true
            throw error
        } catch {
            automaticWritesBlocked = true
            try preserveCorruptSession()
            throw error
        }
    }

    func save(_ snapshot: ReviewSessionSnapshot, generation: UInt64? = nil) throws {
        guard let generation = generation ?? implicitGeneration() else { throw StoreError.generationExhausted }
        guard accept(generation) else { return }
        pendingSave?.cancel()
        try saveAutomatically(snapshot)
    }

    /// Replaces an unreadable or unsupported snapshot only after an explicit
    /// user-directed recovery action. Automatic persistence must use `save`.
    func recoverAndSave(_ snapshot: ReviewSessionSnapshot) throws {
        pendingSave?.cancel()
        try writeAtomically(snapshot.reconciledForRestore())
        automaticWritesBlocked = false
        unsupportedSnapshotSchema = nil
        lastScheduledSaveError = nil
    }

    /// Defers crash-resilient draft persistence while coalescing keystrokes.
    func scheduleSave(
        _ snapshot: ReviewSessionSnapshot,
        generation: UInt64? = nil,
        after delay: Duration = .milliseconds(350)
    ) {
        guard let generation = generation ?? implicitGeneration() else {
            lastScheduledSaveError = StoreError.generationExhausted
            return
        }
        guard accept(generation) else { return }
        pendingSave?.cancel()
        guard !automaticWritesBlocked else {
            lastScheduledSaveError = StoreError.automaticWritesBlocked
            return
        }
        pendingSave = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                try await self?.saveScheduled(snapshot, generation: generation)
            } catch is CancellationError {
                // A newer edit superseded this save.
            } catch {
                await self?.recordScheduledSaveError(error)
            }
        }
    }

    func flushScheduledSave(_ snapshot: ReviewSessionSnapshot, generation: UInt64? = nil) throws {
        guard let generation = generation ?? implicitGeneration() else { throw StoreError.generationExhausted }
        guard accept(generation) else { return }
        pendingSave?.cancel()
        try saveAutomatically(snapshot)
    }

    func takeScheduledSaveError() -> Error? {
        defer { lastScheduledSaveError = nil }
        return lastScheduledSaveError
    }

    func writeRemoteCache(_ cache: ReviewRemoteCache) throws {
        guard valid(cache.pullRequest), cache.revision.isValid else { throw StoreError.invalidSnapshot }
        let data = try JSONEncoder().encode(cache)
        try writeCache(data, named: cacheName(for: cache.pullRequest))
    }

    /// Stores a complete provider read only when it remains the newest accepted
    /// refresh for this Pull Request. The generation is runtime-only metadata;
    /// the cache file remains schema-compatible with prior versions.
    func writeRemoteCache(
        _ cache: ReviewRemoteCache,
        owner: PullRequestIdentity,
        generation: UInt64
    ) async throws {
        guard valid(cache.pullRequest), cache.revision.isValid, cache.pullRequest == owner else {
            throw StoreError.invalidSnapshot
        }
        guard acceptRemoteCache(owner: owner, generation: generation) else { return }
        await beforeOrderedRemoteCacheWrite?(cache, owner, generation)
        guard highestRemoteCacheGeneration[owner] == generation else { return }
        let data = try JSONEncoder().encode(cache)
        try writeCache(data, named: cacheName(for: owner))
    }

    func readRemoteCache(for identity: PullRequestIdentity) throws -> ReviewRemoteCache? {
        guard valid(identity) else { throw StoreError.invalidSnapshot }
        guard let data = try readCache(named: cacheName(for: identity)) else { return nil }
        let cache = try JSONDecoder().decode(ReviewRemoteCache.self, from: data)
        guard valid(cache.pullRequest), cache.pullRequest == identity,
              ReviewRevision.isProviderSafeCommit(cache.revision.baseCommit),
              ReviewRevision.isProviderSafeCommit(cache.revision.headCommit)
        else {
            throw StoreError.invalidSnapshot
        }
        return cache
    }

    func writeCache(_ data: Data, named name: String) throws {
        let destination = try cacheURL(for: name)
        try createSecureDirectory(cacheDirectoryURL)
        try writeSecurely(data, to: destination)
    }

    func readCache(named name: String) throws -> Data? {
        let url = try cacheURL(for: name)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try createSecureDirectory(cacheDirectoryURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    /// Deletes only replaceable provider cache data, never the session snapshot.
    func clearCache() throws {
        guard fileManager.fileExists(atPath: cacheDirectoryURL.path) else { return }
        try fileManager.removeItem(at: cacheDirectoryURL)
    }

    private func writeAtomically(_ snapshot: ReviewSessionSnapshot) throws {
        let parent = sessionURL.deletingLastPathComponent()
        try createSecureDirectory(parent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try writeSecurely(data, to: sessionURL)
    }

    private func saveAutomatically(_ snapshot: ReviewSessionSnapshot) throws {
        guard !automaticWritesBlocked else { throw automaticWriteBlockError() }
        try writeAtomically(snapshot.reconciledForRestore())
        lastScheduledSaveError = nil
    }

    private func saveScheduled(_ snapshot: ReviewSessionSnapshot, generation: UInt64) throws {
        guard highestAcceptedGeneration == generation else { return }
        try saveAutomatically(snapshot)
    }

    /// Accepts only requests at or above the latest request observed by the
    /// store. Coordinator generations are strictly increasing, so an older
    /// task that reaches this actor after a lifecycle flush cannot revive an
    /// obsolete snapshot.
    private func accept(_ generation: UInt64) -> Bool {
        guard highestAcceptedGeneration.map({ generation > $0 }) ?? true else { return false }
        highestAcceptedGeneration = generation
        if generation >= nextImplicitGeneration {
            if generation == .max {
                implicitGenerationExhausted = true
            } else {
                nextImplicitGeneration = generation + 1
            }
        }
        return true
    }

    private func acceptRemoteCache(owner: PullRequestIdentity, generation: UInt64) -> Bool {
        guard highestRemoteCacheGeneration[owner].map({ generation > $0 }) ?? true else { return false }
        highestRemoteCacheGeneration[owner] = generation
        return true
    }

    /// Direct store callers retain deterministic ordering without needing to
    /// manufacture generations. Saturation avoids an integer trap; production
    /// coordinator requests never share this fallback path.
    private func implicitGeneration() -> UInt64? {
        guard !implicitGenerationExhausted else { return nil }
        let generation = nextImplicitGeneration
        if generation == .max {
            implicitGenerationExhausted = true
        } else {
            nextImplicitGeneration += 1
        }
        return generation
    }

    private func automaticWriteBlockError() -> StoreError {
        if let unsupportedSnapshotSchema {
            return .unsupportedSnapshotSchema(unsupportedSnapshotSchema)
        }
        return .automaticWritesBlocked
    }

    private func cacheURL(for name: String) throws -> URL {
        let invalid = name.isEmpty || name.contains("/") || name.contains("\\") || name == "." || name == ".."
        guard !invalid else { throw StoreError.invalidSnapshot }
        return cacheDirectoryURL.appendingPathComponent(name, isDirectory: false)
    }

    private func cacheName(for identity: PullRequestIdentity) -> String {
        let raw = "\(identity.repository.provider)\u{0}\(identity.repository.host)\u{0}\(identity.repository.owner)\u{0}\(identity.repository.name)\u{0}\(identity.number)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pr-\(digest).json"
    }

    private func valid(_ identity: PullRequestIdentity) -> Bool {
        let repository = identity.repository
        return identity.number > 0 && repository.provider == "github" && !repository.host.isEmpty &&
            !repository.owner.isEmpty && !repository.name.isEmpty
    }

    private func createSecureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeSecurely(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try createSecureDirectory(parent)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [])
        if fileOperationFailure == .setTemporaryPermissions {
            throw FileOperationFailure.setTemporaryPermissions
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private func preserveCorruptSession() throws {
        guard fileManager.fileExists(atPath: sessionURL.path) else { return }
        let backup = sessionURL.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
        try fileManager.copyItem(at: sessionURL, to: backup)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }

    private func recordScheduledSaveError(_ error: Error) { lastScheduledSaveError = error }
}
