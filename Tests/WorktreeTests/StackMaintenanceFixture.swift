import Foundation
import Testing

@testable import Argus

final class StackMaintenanceFixture: @unchecked Sendable {
    let temporary: TestTemporaryDirectory
    let root: URL
    let repository: URL
    let parent: URL
    let parentBranch = "feature/parent"
    let projectID = UUID()
    let environment: [String: String]
    let projectCommit: String
    let parentCommit: String

    var configurationURL: URL { repository.appendingPathComponent(".git/config") }
    var globalConfigurationURL: URL { root.appendingPathComponent("global-config") }
    var metadataURL: URL { repository.appendingPathComponent(".git/gh-stack") }
    var storageURL: URL { root.appendingPathComponent("managed-worktrees") }

    init() throws {
        temporary = try TestTemporaryDirectory(prefix: "argus-stack-maintenance")
        root = temporary.url.resolvingSymlinksInPath()
        repository = root.appendingPathComponent("repository")
        parent = root.appendingPathComponent("parent checkout \n")
        environment = GitCommandEnvironment.standard.merging([
            "GIT_CONFIG_GLOBAL": root.appendingPathComponent("global-config").path,
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_ATTR_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "0", "GIT_CONFIG_PARAMETERS": "",
            "GIT_AUTHOR_NAME": "Stack Test", "GIT_AUTHOR_EMAIL": "stack@example.test",
            "GIT_COMMITTER_NAME": "Stack Test", "GIT_COMMITTER_EMAIL": "stack@example.test"
        ]) { _, new in new }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("global-config"))
        try Self.runGit(["init", "-b", "main", "."], in: repository, environment: environment)
        try Self.runGit(["config", "commit.gpgsign", "false"], in: repository, environment: environment)
        try Self.runGit(["config", "core.hooksPath", "/dev/null"], in: repository, environment: environment)
        try Self.runGit(["config", "core.attributesFile", "/dev/null"], in: repository, environment: environment)
        try Data("base\n".utf8).write(to: repository.appendingPathComponent("base.txt"))
        try Self.runGit(["add", "base.txt"], in: repository, environment: environment)
        try Self.runGit(["commit", "-m", "base"], in: repository, environment: environment)
        projectCommit = try Self.runGit(["rev-parse", "HEAD"], in: repository, environment: environment)
        try Self.runGit(
            ["worktree", "add", "-b", parentBranch, parent.path, "HEAD"], in: repository, environment: environment)
        try Data("parent\n".utf8).write(to: parent.appendingPathComponent("parent.txt"))
        try Self.runGit(["add", "parent.txt"], in: parent, environment: environment)
        try Self.runGit(["commit", "-m", "parent"], in: parent, environment: environment)
        parentCommit = try Self.runGit(["rev-parse", "HEAD"], in: parent, environment: environment)
    }

    deinit { temporary.remove() }

    func service(runner: any StackGitCommandRunning = StackGitProcessRunner()) -> StackParentService {
        StackParentService(environment: environment, commandRunner: runner)
    }

    func worktreeService(runner: any StackGitCommandRunning = StackGitProcessRunner()) -> WorktreeService {
        WorktreeService(worktreeBaseURL: storageURL, stackParentService: service(runner: runner))
    }

    func context(using service: StackParentService? = nil) async throws -> StackParentContext {
        try await (service ?? self.service()).inspect(repositoryPath: repository.path, worktreePath: parent.path)
    }

    @discardableResult
    func git(_ arguments: [String], at path: URL? = nil) throws -> String {
        try Self.runGit(arguments, in: path ?? repository, environment: environment)
    }

    @discardableResult
    private static func runGit(
        _ arguments: [String], in directory: URL, environment: [String: String]
    ) throws -> String {
        try StackGitCommand(environment: environment, runner: StackGitProcessRunner())
            .output(arguments, at: directory.path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func branchExists(_ branch: String) -> Bool {
        (try? git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"])) != nil
    }

    func writeStack(trunk: String = "main", branches: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "stacks": [["trunk": ["branch": trunk], "branches": branches.map { ["branch": $0] }]]
        ])
        try data.write(to: metadataURL)
    }

    func writeGraphite(branch: String, parent: String?) throws {
        let metadata = root.appendingPathComponent("graphite.json")
        let object: [String: Any] = parent.map { ["parentBranchName": $0] } ?? [:]
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let objectID = try git(["hash-object", "-w", metadata.path])
        try git(["update-ref", "refs/branch-metadata/\(branch)", objectID])
    }

    func makeDirtyParent() throws {
        try Data("unstaged parent\n".utf8).write(to: parent.appendingPathComponent("base.txt"))
        try Data("parent private work\n".utf8).write(to: parent.appendingPathComponent("untracked.txt"))
    }

    func expectNoDependent(_ name: String = "feature/dependent") throws {
        #expect(!branchExists(name))
        let registrations = try git(["worktree", "list", "--porcelain", "-z"])
        #expect(!registrations.contains("branch refs/heads/\(name)\0"))
        #expect((try? git(["config", "--local", "--get", "branch.\(name).base"])) == nil)
    }
}

final class StackGitTestRunner: StackGitCommandRunning, @unchecked Sendable {
    enum Phase { case before, after }
    typealias Interceptor = @Sendable ([String], String, Phase) throws -> ExternalProcessResult?

    private let lock = NSLock()
    private var recordedArguments: [[String]] = []
    private let interceptor: Interceptor

    init(interceptor: @escaping Interceptor = { _, _, _ in nil }) {
        self.interceptor = interceptor
    }

    var invocations: [[String]] { lock.withLock { recordedArguments } }

    func run(
        arguments: [String], repositoryPath: String, environment: [String: String], timeout: TimeInterval
    ) throws -> ExternalProcessResult {
        lock.withLock { recordedArguments.append(arguments) }
        if let result = try interceptor(arguments, repositoryPath, .before) { return result }
        let result = try StackGitProcessRunner().run(
            arguments: arguments, repositoryPath: repositoryPath, environment: environment, timeout: timeout)
        return try interceptor(arguments, repositoryPath, .after) ?? result
    }

    static var failure: ExternalProcessResult {
        ExternalProcessResult(stdout: Data(), stderr: Data("fixture-sensitive diagnostic".utf8), terminationStatus: 128)
    }
}

final class StackTestOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func take() -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

final class StackCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var arrived = false

    func stop() throws {
        lock.withLock { arrived = true }
        guard releaseSignal.wait(timeout: .now() + 15) == .success else {
            throw StackParentError.commandTimedOut
        }
    }

    func wait() async throws {
        let deadline = Date().addingTimeInterval(15)
        while !lock.withLock({ arrived }) {
            guard Date() < deadline else { throw StackParentError.commandTimedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() { releaseSignal.signal() }
}

struct StackExecutableMarker: Sendable {
    let executable: URL
    let marker: URL

    var command: String { "'\(executable.path)' '\(marker.path)'" }
    var executed: Bool { FileManager.default.fileExists(atPath: marker.path) }

    init(root: URL) throws {
        executable = root.appendingPathComponent("marker-filter")
        marker = root.appendingPathComponent("filter-executed")
        try Data("#!/bin/sh\n/usr/bin/touch \"$1\"\n/bin/cat\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    }
}
