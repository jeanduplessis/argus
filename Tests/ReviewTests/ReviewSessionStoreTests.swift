import CryptoKit
import Foundation
import Testing

@testable import Argus

@Suite
struct ReviewSessionStoreTests {
    @Test
    func atomicSaveRestoresSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(sessionURL: root.appendingPathComponent("session.json"), cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let snapshot = ReviewSessionSnapshot(tabs: [.init(pullRequest: identity, replyDrafts: [.init(conversationID: "c", body: "draft")])])
        try await store.save(snapshot)
        let restored = try await store.restore()
        #expect(restored.tabs.first?.replyDrafts.first?.body == "draft")
        #expect(try permissions(of: root.appendingPathComponent("session.json")) == 0o600)
        #expect(try permissions(of: root) == 0o700)
    }

    @Test
    func automaticFlushWritesANormalSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let snapshot = ReviewSessionSnapshot(tabs: [.init(pullRequest: identity)])

        try await store.flushScheduledSave(snapshot)

        #expect(try await store.restore().tabs.first?.pullRequest == identity)
    }

    @Test
    func generationOrderingKeepsTheNewestAutomaticSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let older = ReviewSessionSnapshot(rightSidebarWidth: 200)
        let newer = ReviewSessionSnapshot(rightSidebarWidth: 400)

        await store.scheduleSave(older, generation: 1, after: .milliseconds(50))
        await store.scheduleSave(newer, generation: 2, after: .milliseconds(20))
        try await store.flushScheduledSave(older, generation: 1)
        try await Task.sleep(for: .milliseconds(50))

        #expect(try await store.restore().rightSidebarWidth == 400)
    }

    @Test
    func orderedRemoteCacheWritesKeepTheNewestRevisionPerPullRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RemoteCacheWriteGate()
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache"),
            beforeOrderedRemoteCacheWrite: { cache, _, _ in
                if cache.revision.headCommit == "old" { await gate.wait() }
            }
        )
        let first = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let second = PullRequestIdentity(repository: first.repository, number: 2)
        let old = remoteCache(for: first, head: "old")
        let new = remoteCache(for: first, head: "new")
        let independent = remoteCache(for: second, head: "independent")

        async let olderWrite: Void = store.writeRemoteCache(old, owner: first, generation: 1)
        await gate.waitUntilSuspended()
        try await store.writeRemoteCache(independent, owner: second, generation: 1)
        try await store.writeRemoteCache(new, owner: first, generation: 2)

        #expect(try await store.readRemoteCache(for: first)?.revision == new.revision)
        #expect(try await store.readRemoteCache(for: second)?.revision == independent.revision)
        await gate.resume()
        try await olderWrite

        #expect(try await store.readRemoteCache(for: first)?.revision == new.revision)
        #expect(try await store.readRemoteCache(for: second)?.revision == independent.revision)
    }

    @Test
    func restoreNormalizesWhitespacePaddedPersistedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let snapshot = ReviewSessionSnapshot(tabs: [.init(pullRequest: identity, revision: .init(baseCommit: "base", headCommit: "head"))])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        var tabs = object["tabs"] as! [[String: Any]]
        tabs[0]["revision"] = ["baseCommit": "  base-commit\n", "headCommit": "\thead_commit  "]
        object["tabs"] = tabs
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: sessionURL)

        let restored = try await store.restore()

        #expect(restored.tabs[0].revision == .init(baseCommit: "base-commit", headCommit: "head_commit"))
        #expect(restored.tabs[0].revision?.isValid == true)
    }

    @Test
    func restoreNormalizesPersistedLoadedStateWithoutProviderPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        try await store.save(
            .init(tabs: [
                .init(
                    pullRequest: identity,
                    revision: .init(baseCommit: "base", headCommit: "head"),
                    changedFiles: [.init(path: "Source.swift")],
                    loadState: .loaded
                )
            ])
        )

        let restored = try await store.restore()

        #expect(restored.tabs[0].loadState == .stale)
        #expect(restored.tabs[0].changedFiles.isEmpty)
    }

    @Test
    func pendingViewedIntentSurvivesRestartWithoutPersistingProviderPayload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(
            sessionURL: root.appendingPathComponent("session.json"),
            cacheDirectoryURL: root.appendingPathComponent("cache")
        )
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        try await store.save(.init(tabs: [
            .init(
                pullRequest: identity,
                revision: revision,
                changedFiles: [.init(path: "Provider.swift", viewedState: .pendingViewed)],
                pendingViewedIntents: [.init(revision: revision, path: "Source.swift", viewed: true)]
            )
        ]))

        let restored = try await store.restore()

        #expect(restored.tabs[0].changedFiles.isEmpty)
        #expect(restored.tabs[0].pendingViewedIntents == [.init(revision: revision, path: "Source.swift", viewed: true)])
    }

    @Test
    func cacheCleanupLeavesDraftSessionUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        try await store.save(.init(tabs: [.init(pullRequest: identity, replyDrafts: [.init(conversationID: "c", body: "draft")])]))
        try await store.writeCache(Data("remote".utf8), named: "payload.json")
        try await store.clearCache()
        #expect(try await store.readCache(named: "payload.json") == nil)
        let restored = try await store.restore()
        #expect(restored.tabs.first?.replyDrafts.first?.body == "draft")
    }

    @Test
    func completeRemoteCacheRoundTripsSeparatelyFromDraftSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewSessionStore(sessionURL: root.appendingPathComponent("session.json"), cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let revision = ReviewRevision(baseCommit: "base", headCommit: "head")
        let cache = ReviewRemoteCache(pullRequest: identity, revision: revision, changedFiles: [.init(path: "A.swift", validAnchorCoordinates: [.init(side: .right, line: 2)])], conversations: [], activity: [], checks: .init(mergeable: "MERGEABLE", mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now)
        try await store.writeRemoteCache(cache)
        try await store.save(.init(tabs: [.init(pullRequest: identity, replyDrafts: [.init(conversationID: "c", body: "draft")])]))

        #expect(try await store.readRemoteCache(for: identity)?.revision == revision)
        #expect(try await store.readRemoteCache(for: identity)?.changedFiles[0].validAnchorCoordinates == [.init(side: .right, line: 2)])
        #expect(try await store.restore().tabs.first?.replyDrafts.first?.body == "draft")
    }

    @Test
    func legacyRemoteCacheWithoutCoordinatesDecodesWithNoInlineAnchors() throws {
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let cache = ReviewRemoteCache(
            pullRequest: identity, revision: .init(baseCommit: "base", headCommit: "head"),
            changedFiles: [.init(path: "A.swift")], conversations: [], activity: [],
            checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
        var files = object["changedFiles"] as! [[String: Any]]
        files[0].removeValue(forKey: "validAnchorCoordinates")
        object["changedFiles"] = files

        let restored = try JSONDecoder().decode(ReviewRemoteCache.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(restored.changedFiles[0].validAnchorCoordinates.isEmpty)
    }

    @Test
    func rejectsSemanticallyInvalidRemoteCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectoryURL = root.appendingPathComponent("cache")
        let store = ReviewSessionStore(sessionURL: root.appendingPathComponent("session.json"), cacheDirectoryURL: cacheDirectoryURL)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let cache = ReviewRemoteCache(pullRequest: identity, revision: .init(baseCommit: "base", headCommit: "head"), changedFiles: [], conversations: [], activity: [], checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
        object["revision"] = ["baseCommit": "base", "headCommit": ""]
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        try await store.writeCache(invalidData, named: cacheName(for: identity))

        await #expect(throws: ReviewSessionStore.StoreError.invalidSnapshot) {
            try await store.readRemoteCache(for: identity)
        }
    }

    @Test
    func rejectsRemoteCacheWithNonemptyUnsafeCommitIdentifier() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheDirectoryURL = root.appendingPathComponent("cache")
        let store = ReviewSessionStore(sessionURL: root.appendingPathComponent("session.json"), cacheDirectoryURL: cacheDirectoryURL)
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let cache = ReviewRemoteCache(pullRequest: identity, revision: .init(baseCommit: "base", headCommit: "head"), changedFiles: [], conversations: [], activity: [], checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []), savedAt: .now)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
        object["revision"] = ["baseCommit": "base/main", "headCommit": "head"]
        try await store.writeCache(try JSONSerialization.data(withJSONObject: object), named: cacheName(for: identity))

        await #expect(throws: ReviewSessionStore.StoreError.invalidSnapshot) {
            try await store.readRemoteCache(for: identity)
        }
    }

    @Test
    func corruptSessionBlocksEveryAutomaticWriteUntilExplicitRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: sessionURL)
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))

        await #expect(throws: (any Error).self) { try await store.restore() }
        let original = try Data(contentsOf: sessionURL)
        await store.scheduleSave(.init(), after: .zero)
        #expect(await store.takeScheduledSaveError() as? ReviewSessionStore.StoreError == .automaticWritesBlocked)
        await #expect(throws: ReviewSessionStore.StoreError.automaticWritesBlocked) {
            try await store.flushScheduledSave(.init())
        }
        await #expect(throws: ReviewSessionStore.StoreError.automaticWritesBlocked) {
            try await store.save(.init())
        }
        #expect(try Data(contentsOf: sessionURL) == original)
        let backupURL = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("session.corrupt-") })
        #expect(try Data(contentsOf: backupURL) == original)

        try await store.recoverAndSave(.init())
        #expect((try await store.restore()).schemaVersion == ReviewSessionSnapshot.currentSchemaVersion)
        try await store.save(.init())
    }

    @Test
    func restoresVersionOneSnapshotThroughReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        let identity = PullRequestIdentity(repository: .init(host: "github.com", owner: "o", name: "r"), number: 1)
        let legacy = ReviewSessionSnapshot(tabs: [.init(pullRequest: identity)])
        var data = try JSONEncoder().encode(legacy)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 1
        data = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: sessionURL)

        let restored = try await store.restore()

        #expect(restored.tabs.first?.pullRequest == identity)
        #expect(restored.schemaVersion == ReviewSessionSnapshot.currentSchemaVersion)
    }

    @Test
    func futureSchemaBlocksEveryAutomaticWriteUntilExplicitRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let future = #"{"schemaVersion":999}"#
        try Data(future.utf8).write(to: sessionURL)

        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(999)) {
            try await store.restore()
        }
        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(999)) {
            try await store.flushScheduledSave(.init())
        }
        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(999)) {
            try await store.save(.init())
        }
        #expect(try Data(contentsOf: sessionURL) == Data(future.utf8))

        try await store.recoverAndSave(.init())
        try await store.save(.init())
    }

    @Test
    func schemaZeroIsNotOverwrittenByAutomaticOrFlushSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let original = #"{"schemaVersion":0}"#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(original.utf8).write(to: sessionURL)
        let store = ReviewSessionStore(sessionURL: sessionURL, cacheDirectoryURL: root.appendingPathComponent("cache"))

        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(0)) {
            try await store.restore()
        }
        await store.scheduleSave(.init(), after: .zero)
        #expect(await store.takeScheduledSaveError() as? ReviewSessionStore.StoreError == .automaticWritesBlocked)
        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(0)) {
            try await store.flushScheduledSave(.init())
        }
        await #expect(throws: ReviewSessionStore.StoreError.unsupportedSnapshotSchema(0)) {
            try await store.save(.init())
        }
        #expect(String(decoding: try Data(contentsOf: sessionURL), as: UTF8.self) == original)
    }

    @Test
    func failedAtomicWriteRemovesTemporaryFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionURL = root.appendingPathComponent("session.json")
        let original = Data("previous session".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: sessionURL)
        let store = ReviewSessionStore(
            sessionURL: sessionURL,
            cacheDirectoryURL: root.appendingPathComponent("cache"),
            fileOperationFailure: .setTemporaryPermissions
        )

        await #expect(throws: ReviewSessionStore.FileOperationFailure.setTemporaryPermissions) {
            try await store.save(.init())
        }
        #expect(try Data(contentsOf: sessionURL) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func cacheName(for identity: PullRequestIdentity) -> String {
        let raw = "\(identity.repository.provider)\u{0}\(identity.repository.host)\u{0}\(identity.repository.owner)\u{0}\(identity.repository.name)\u{0}\(identity.number)"
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "pr-\(digest).json"
    }

    private func remoteCache(for identity: PullRequestIdentity, head: String) -> ReviewRemoteCache {
        .init(
            pullRequest: identity,
            revision: .init(baseCommit: "base", headCommit: head),
            changedFiles: [.init(path: "\(head).swift")],
            conversations: [],
            activity: [],
            checks: .init(mergeable: nil, mergeStateStatus: nil, reviewDecision: nil, checks: []),
            savedAt: .now
        )
    }
}

private actor RemoteCacheWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspended = false
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        suspended = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
