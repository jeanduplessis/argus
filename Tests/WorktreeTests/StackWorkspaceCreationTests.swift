import Foundation
import Testing

@testable import Argus

@Suite
struct StackWorkspaceCreationTests {
    // MARK: - Stack creation tests

    /// Creates the shared git fixture used by all stack-creation tests:
    /// a repo with one commit on `main`, then a `parent` branch at that commit,
    /// then a second commit on `main` so that `parent` and `main` diverge.
    private func makeStackFixture(
        prefix: String
    ) throws -> (temp: TestTemporaryDirectory, service: WorktreeService) {
        let temp = try TestTemporaryDirectory(prefix: prefix)
        let repo = temp.url.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try TestGit.run(["init", "-b", "main", "."], in: repo)
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "initial"
            ],
            in: repo, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        try TestGit.run(["branch", "parent"], in: repo)  // parent stays at initial commit
        try TestGit.run(
            [
                "-c", "user.name=Test User", "-c", "user.email=test@example.com",
                "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "second"
            ],
            in: repo, environment: ["GIT_CONFIG_GLOBAL": "/dev/null"])
        let service = WorktreeService(
            worktreeBaseURL: temp.url.appendingPathComponent("managed-worktrees", isDirectory: true))
        return (temp, service)
    }

    @Test
    func stackCreationStartsAtParentCommitNotRepoHead() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-start")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        // parent is at initial commit; main is one commit ahead
        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "child",
            createNewBranch: true,
            parentBranch: "parent"
        )
        let childHead = try capture("git", ["rev-parse", "HEAD"], cwd: worktreePath)
        let parentHead = try capture("git", ["rev-parse", "refs/heads/parent"], cwd: repo.path)
        let mainHead = try capture("git", ["rev-parse", "HEAD"], cwd: repo.path)
        assertTrue(childHead == parentHead, "new stack branch starts at parent branch commit")
        assertTrue(childHead != mainHead, "parent commit differs from main HEAD")
    }

    @Test
    func stackCreationWritesBaseConfigReadableFromBothCheckouts() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-config")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "child",
            createNewBranch: true,
            parentBranch: "parent"
        )
        // Readable from the main checkout
        let fromMain = try capture("git", ["config", "--get", "branch.child.base"], cwd: repo.path)
        assertEqual(fromMain, "parent", "base config is readable from the main checkout")
        // Readable from the new worktree
        let fromWorktree = try capture("git", ["config", "--get", "branch.child.base"], cwd: worktreePath)
        assertEqual(fromWorktree, "parent", "base config is readable from the new worktree")
        // Shared RecordedBaseBranchReader sees the parent
        let reader = RecordedBaseBranchReader(
            environment: GitCommandEnvironment.standard.merging(
                ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_COUNT": "0"]
            ) { _, new in new })
        let snapshot = try reader.read(repositoryPath: repo.path)
        assertEqual(snapshot.parents["child"], "parent", "shared reader sees the recorded parent")
    }

    @Test
    func stackCreationWithNilParentBranchPreservesNormalBehavior() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-nil")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        let mainHead = try capture("git", ["rev-parse", "HEAD"], cwd: repo.path)
        let worktreePath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "ordinary",
            createNewBranch: true,
            parentBranch: nil
        )
        let ordinaryHead = try capture("git", ["rev-parse", "HEAD"], cwd: worktreePath)
        assertEqual(ordinaryHead, mainHead, "nil parentBranch creates branch at repo HEAD")
        // No branch.ordinary.base entry should exist
        #expect(throws: Error.self) {
            _ = try TestGit.run(["config", "--local", "--get", "branch.ordinary.base"], in: repo)
        }
    }

    @Test
    func stackCreationRejectsExistingBranchMode() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-reject")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        await #expect(throws: WorktreeError.self) {
            _ = try await service.createWorktree(
                projectId: UUID(),
                repositoryPath: repo.path,
                branchName: "parent",  // existing branch
                createNewBranch: false,
                parentBranch: "parent"
            )
        }
    }

    @Test
    func stackCreationFailsOnMissingParentBranch() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-missing")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        let worktreesBefore = try capture(
            "git", ["worktree", "list", "--porcelain"], cwd: repo.path)
        await #expect(throws: WorktreeError.self) {
            _ = try await service.createWorktree(
                projectId: UUID(),
                repositoryPath: repo.path,
                branchName: "child",
                createNewBranch: true,
                parentBranch: "nonexistent-branch"
            )
        }
        let worktreesAfter = try capture(
            "git", ["worktree", "list", "--porcelain"], cwd: repo.path)
        assertEqual(worktreesBefore, worktreesAfter, "failed creation leaves no worktree registration")
    }

    @Test(arguments: [false, true])
    func failedStackConfigPreservesBranchAndAnyModifiedWorktree(hookWritesFile: Bool) async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-configfail")
        let repo = temp.url.appendingPathComponent("repo")
        defer { temp.remove() }
        if hookWritesFile {
            let hooks = temp.url.appendingPathComponent("hooks", isDirectory: true)
            try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("post-checkout")
            try "#!/bin/sh\nprintf 'keep this work' > keep.txt\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            try TestGit.run(["config", "core.hooksPath", hooks.path], in: repo)
        }
        // Git replaces config atomically, so a read-only config file would not fail.
        // A lock blocks only configuration writes, not the new branch/worktree.
        let lock = repo.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        let projectId = UUID()
        let checkout = service.managedWorktreeBaseURL.appendingPathComponent(projectId.uuidString)
            .appendingPathComponent("child")
        do {
            _ = try await service.createWorktree(
                projectId: projectId, repositoryPath: repo.path, branchName: "child", parentBranch: "parent")
            Issue.record("Stack creation must report the configuration failure")
        } catch {
            #expect(error.localizedDescription.contains("Could not record stack parent"))
            #expect(error.localizedDescription.contains(hookWritesFile ? checkout.path : "retained"))
        }
        #expect(try TestGit.run(["rev-parse", "child"], in: repo) == TestGit.run(["rev-parse", "parent"], in: repo))
        #expect(FileManager.default.fileExists(atPath: checkout.path) == hookWritesFile)
        if hookWritesFile {
            #expect(
                try String(contentsOf: checkout.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep this work"
            )
        }
        #expect(throws: Error.self) { try TestGit.run(["config", "--local", "--get", "branch.child.base"], in: repo) }
    }

    @Test
    @MainActor
    func managerAddsNewWorkspaceToStackAndRejectsDuplicateWithoutChangingSelection() async throws {
        let (temp, service) = try makeStackFixture(prefix: "argus-stack-workspace")
        defer { temp.remove() }
        let repo = temp.url.appendingPathComponent("repo")
        let suite = "ArgusTests.StackCreation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = WorkspaceManager(
            settings: AppSettings(defaults: defaults),
            sessionSnapshotURL: temp.url.appendingPathComponent("session.json"),
            environment: ["ARGUS_UNDER_TEST": "1"], worktreeService: service)
        let project = try #require(await manager.createProject(repositoryPath: repo.path))
        let parent = try #require(
            await manager.addWorkspaceToProject(project.id, branchName: "parent", createNewBranch: false))
        let child = try #require(
            await manager.addWorkspaceToProject(
                project.id, branchName: "child", customTitle: "Next task", parentBranch: "parent"))
        #expect(manager.selectedWorkspaceId == child.id)
        #expect(child.displayTitle == "Next task")
        #expect(child.panelOrder.count == 1)
        manager.workspaceStackSnapshots[project.id] = try await WorkspaceStackService().load(repositoryPath: repo.path)
        let group = try #require(manager.stackGroup(for: child.id, in: project.id))
        #expect(group.workspaceIds == [parent.id, child.id])
        let count = manager.workspaces.count
        #expect(await manager.addWorkspaceToProject(project.id, branchName: "child", parentBranch: "parent") == nil)
        #expect(manager.workspaces.count == count)
        #expect(manager.selectedWorkspaceId == child.id)
        guard case .branchAlreadyExists("child") = manager.lastWorkspaceCreationError else {
            Issue.record("The duplicate branch must remain an explicit creation error")
            return
        }
    }

    private func capture(_ executable: String, _ args: [String], cwd: String) throws -> String {
        try TestGit.run(executable, args, cwd: cwd)
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
