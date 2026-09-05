import Foundation
import Testing

@testable import Argus

actor SetupTestRunner: WorktreeSetupRunning {
    private(set) var requests: [WorktreeSetupRequest] = []
    private(set) var rootExistedAtStop = false
    private(set) var stopRequests = 0
    private var holdsStops = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    var holdsRuns = false
    var failsStop = false
    var outcome: WorktreeSetupOutcome = .succeeded
    private var output: (@Sendable (WorktreeSetupOutput) async -> Void)?

    func configure(hold: Bool = false, failsStop: Bool = false, outcome: WorktreeSetupOutcome = .succeeded) {
        holdsRuns = hold
        self.failsStop = failsStop
        self.outcome = outcome
        releaseStops()
    }

    func holdStops() { holdsStops = true }

    func releaseStops() {
        holdsStops = false
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func run(
        _ request: WorktreeSetupRequest,
        cancellation: WorktreeSetupCancellation,
        output: @escaping @Sendable (WorktreeSetupOutput) async -> Void
    ) async -> WorktreeSetupResult {
        requests.append(request)
        self.output = output
        await output(.init(text: "fixture output", truncated: false))
        while holdsRuns && !cancellation.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
        if cancellation.isCancelled {
            stopRequests += 1
            if holdsStops { await withCheckedContinuation { stopWaiters.append($0) } }
            rootExistedAtStop = FileManager.default.fileExists(atPath: request.rootPath)
            if failsStop { cancellation.retainCleanup { await self.retryCleanup() } }
            return .init(outcome: .cancelled, terminationConfirmed: !failsStop)
        }
        return .init(outcome: outcome)
    }

    func emit(_ text: String) async { await output?(.init(text: text, truncated: false)) }
    private func retryCleanup() -> Bool { !failsStop }
}

@MainActor
final class SetupManagerFixture {
    let directory: TestTemporaryDirectory
    let repository: URL
    let runner: SetupTestRunner
    let manager: WorkspaceManager
    let suiteName: String
    let defaults: UserDefaults
    var project: Project { manager.namedProjects[0] }

    private init(directory: TestTemporaryDirectory, repository: URL, runner: SetupTestRunner) throws {
        self.directory = directory
        self.repository = repository
        self.runner = runner
        suiteName = "Argus.SetupTests.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: directory.url.appendingPathComponent("session.json"),
            environment: ["ARGUS_UNDER_TEST": "1"],
            worktreeService: WorktreeService(worktreeBaseURL: directory.url.appendingPathComponent("managed")),
            worktreeSetupRunner: runner
        )
    }

    static func make(command: String? = "printf fixture") async throws -> SetupManagerFixture {
        let directory = try TestTemporaryDirectory(prefix: "argus-setup-manager")
        let repository = directory.url.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main"], in: repository)
        try TestGit.run(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"],
            in: repository)
        let fixture = try SetupManagerFixture(directory: directory, repository: repository, runner: SetupTestRunner())
        let project = try #require(await fixture.manager.createProject(repositoryPath: repository.path))
        if let command { try fixture.manager.setWorktreeSetupCommand(command, for: project.id) }
        return fixture
    }

    func workspace(
        branch: String = "feature", newBranch: Bool = true, parent: String? = nil
    ) async throws -> Workspace {
        try #require(
            await manager.addWorkspaceToProject(
                project.id, branchName: branch, createNewBranch: newBranch, parentBranch: parent))
    }

    func waitForRuns(_ count: Int) async throws {
        for _ in 0..<300 {
            if await runner.requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Setup runner did not receive expected request")
    }

    func waitForStops(_ count: Int) async throws {
        for _ in 0..<300 {
            if await runner.stopRequests >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Setup runner did not receive expected stop")
    }

    func addProject(name: String) async throws -> Project {
        let repository = directory.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main"], in: repository)
        try TestGit.run(
            ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"],
            in: repository)
        return try #require(await manager.createProject(repositoryPath: repository.path))
    }

    func waitForFinish(_ panel: WorktreeSetupPanel) async throws {
        for _ in 0..<300 {
            if !panel.isRunning { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Setup did not finish")
    }

    func remove() async {
        await runner.configure()
        _ = await manager.stopAllWorktreeSetups()
        defaults.removePersistentDomain(forName: suiteName)
        directory.remove()
    }
}

final class SetupCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: RunningProcessCloseRequest?
    private var storedWorkspaceID: UUID?
    private var observers: [NSObjectProtocol] = []
    var request: RunningProcessCloseRequest? { lock.withLock { storedRequest } }
    var workspaceID: UUID? { lock.withLock { storedWorkspaceID } }

    init() {
        observers = [
            NotificationCenter.default.addObserver(
                forName: .showRunningProcessConfirmation, object: nil, queue: nil
            ) { [weak self] in
                self?.recordRequest($0.object as? RunningProcessCloseRequest)
            },
            NotificationCenter.default.addObserver(
                forName: .showCloseWorkspaceConfirmation, object: nil, queue: nil
            ) { [weak self] in
                self?.recordWorkspace($0.userInfo?["workspaceId"] as? UUID)
            }
        ]
    }

    private func recordRequest(_ request: RunningProcessCloseRequest?) { lock.withLock { storedRequest = request } }
    private func recordWorkspace(_ id: UUID?) { lock.withLock { storedWorkspaceID = id } }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// Suspends a real local Git command without modifying application I/O boundaries.
final class BoundedGitHookGate {
    let marker: URL
    let releaseFile: URL
    let hook: URL
    let expiration: URL
    var didTimeOut: Bool { FileManager.default.fileExists(atPath: expiration.path) }

    init(root: URL, repository: URL, name: String, monitorsStatus: Bool = false) throws {
        marker = root.appendingPathComponent("\(name)-started")
        releaseFile = root.appendingPathComponent("\(name)-release")
        expiration = root.appendingPathComponent("\(name)-expired")
        hook = repository.appendingPathComponent(
            monitorsStatus ? ".git/hooks/test-fsmonitor" : ".git/hooks/post-checkout")
        let script = """
            #!/bin/sh
            if mkdir '\(marker.path)-lock' 2>/dev/null; then
                touch '\(marker.path)'
                count=0
                while [ ! -f '\(releaseFile.path)' ] && [ "$count" -lt 500 ]; do
                    sleep 0.02
                    count=$((count+1))
                done
                if [ ! -f '\(releaseFile.path)' ]; then touch '\(expiration.path)'; fi
            fi
            \(monitorsStatus ? "printf 'gate-token\\0'" : "exit 0")
            """
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        if monitorsStatus { try TestGit.run(["config", "core.fsmonitor", hook.path], in: repository) }
    }

    @MainActor
    func waitUntilStarted() async throws {
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Git fixture did not reach the bounded hook")
    }

    func release() { try? Data().write(to: releaseFile) }
    deinit { release() }
}
