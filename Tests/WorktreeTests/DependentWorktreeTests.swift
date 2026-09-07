import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct DependentWorktreeTests {
    @Test
    func startsAtInitiatingCommittedHeadAndLeavesDirtyParentUntouched() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.makeDirtyParent()
        try fixture.writeStack(branches: [fixture.parentBranch])
        let provider = try Data(contentsOf: fixture.metadataURL)
        let before = try fixture.git(["status", "--porcelain=v1"], at: fixture.parent)
        let runner = StackGitTestRunner()
        let service = fixture.worktreeService(runner: runner)
        let expected = try await fixture.context()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        let path = URL(fileURLWithPath: created.worktreePath)
        #expect(created.headCommitID == fixture.parentCommit)
        #expect(created.headCommitID != fixture.projectCommit)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: path) == fixture.parentCommit)
        #expect(try fixture.git(["status", "--porcelain=v1"], at: path).isEmpty)
        #expect(try String(contentsOf: path.appendingPathComponent("base.txt"), encoding: .utf8) == "base\n")
        #expect(try String(contentsOf: path.appendingPathComponent("parent.txt"), encoding: .utf8) == "parent\n")
        #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("untracked.txt").path))
        #expect(try fixture.git(["status", "--porcelain=v1"], at: fixture.parent) == before)
        #expect(try Data(contentsOf: fixture.metadataURL) == provider)
        let metadata = try service.stackParentService.reader.read(repositoryPath: fixture.repository.path)
        #expect(metadata.parents["feature/dependent"] == fixture.parentBranch)
        #expect(created.childContext.recordedParent == fixture.parentBranch)
        #expect(created.childContext.sourceDescription == "Repository-local configuration")
        #expect(
            !runner.invocations.contains { arguments in
                ["fetch", "push", "ls-remote", "rebase", "reset", "--force", "-D"].contains { arguments.contains($0) }
            })
        try await service.validateDependentWorktree(created)
    }

    @Test(arguments: ["local", "remote", "configuration", "global", "gh-stack", "graphite", "empty-graphite"])
    func rejectsExistingBranchesAndAnyPreexistingBranchMetadata(_ kind: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let name = "feature/dependent"
        switch kind {
        case "local": try fixture.git(["branch", name, "main"])
        case "remote": try fixture.git(["update-ref", "refs/remotes/origin/\(name)", fixture.parentCommit])
        case "configuration": try fixture.git(["config", "branch.\(name).remote", "origin"])
        case "global":
            try fixture.git(["config", "--file", fixture.globalConfigurationURL.path, "branch.\(name).remote", "origin"]
            )
        case "gh-stack": try fixture.writeStack(branches: [name])
        case "graphite": try fixture.writeGraphite(branch: name, parent: "main")
        default: try fixture.writeGraphite(branch: name, parent: nil)
        }
        let expected = try await fixture.context()
        let before = try Data(contentsOf: fixture.configurationURL)
        await #expect(throws: DependentWorkspaceError.self) {
            try await fixture.worktreeService().createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: name, expectedParent: expected)
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
        #expect(fixture.branchExists(name) == (kind == "local"))
        #expect(!FileManager.default.fileExists(atPath: fixture.storageURL.path))
    }

    @Test(arguments: ["--bad", "HEAD", "bad..name", ""])
    func rejectsInvalidNewNamesWithoutCreatingResources(_ name: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        await #expect(throws: StackParentError.invalidBranchName) {
            try await fixture.worktreeService().createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: name, expectedParent: expected)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storageURL.path))
    }

    @Test(arguments: ["head", "detached", "missing"])
    func rejectsChangedParentBeforeCreatingTheBranch(_ change: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        switch change {
        case "head": try fixture.git(["commit", "--allow-empty", "-m", "new parent"], at: fixture.parent)
        case "detached": try fixture.git(["switch", "--detach"], at: fixture.parent)
        default:
            try FileManager.default.moveItem(
                at: fixture.parent, to: fixture.root.appendingPathComponent("moved-parent"))
        }
        await #expect(throws: StackParentError.self) {
            try await fixture.worktreeService().createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        try fixture.expectNoDependent()
    }

    @Test(arguments: ["before-add", "after-checkout", "before-config", "after-config"])
    func failuresRemoveOnlyAttemptOwnedBranchWorktreeAndConfig(_ failurePoint: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let original = try Data(contentsOf: fixture.configurationURL)
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            let shouldFail: Bool
            switch failurePoint {
            case "before-add":
                shouldFail = phase == .before && arguments.contains("worktree") && arguments.contains("add")
            case "after-checkout":
                shouldFail = phase == .after && arguments.contains("checkout-index")
            case "before-config": shouldFail = phase == .before && arguments.contains("--replace-all")
            default:
                shouldFail =
                    phase == .before && arguments.contains("symbolic-ref")
                    && (try? fixture.git(["config", "--local", "--get", "branch.feature/dependent.base"]))
                        == fixture.parentBranch
            }
            guard shouldFail, once.take() else { return nil }
            #expect(fixture.branchExists("feature/dependent"))
            if failurePoint == "after-checkout" { throw StackParentError.commandFailed }
            return StackGitTestRunner.failure
        }
        do {
            _ = try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
            Issue.record("The injected failure must not attach a Worktree")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-sensitive"))
            if case DependentWorkspaceError.retainedResources = error {
                Issue.record("Unchanged attempt resources should be removed")
            }
        }
        try fixture.expectNoDependent()
        #expect(try Data(contentsOf: fixture.configurationURL) == original)
        let directory = fixture.storageURL.appendingPathComponent(fixture.projectID.uuidString)
        if FileManager.default.fileExists(atPath: directory.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test
    func aParentCommitDuringWorktreeCreationIsPreservedAndTheAttemptIsRolledBack() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("worktree"), arguments.contains("add"), once.take() else {
                return nil
            }
            try fixture.git(["commit", "--allow-empty", "-m", "concurrent parent"], at: fixture.parent)
            return nil
        }
        await #expect(throws: StackParentError.contextChanged) {
            try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        #expect(try fixture.git(["rev-parse", "HEAD"], at: fixture.parent) != fixture.parentCommit)
        try fixture.expectNoDependent()
    }

    @Test
    func rejectsMetadataActivatedOnlyInTheNewCheckout() async throws {
        let fixture = try StackMaintenanceFixture()
        let included = fixture.root.appendingPathComponent("dependent-only-config")
        try fixture.git(["config", "--file", included.path, "branch.feature/dependent.base", "main"])
        try fixture.git(["config", "includeIf.onbranch:feature/dependent.path", included.path])
        let expected = try await fixture.context()
        await #expect(throws: DependentWorkspaceError.self) {
            try await fixture.worktreeService().createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        #expect(try fixture.git(["config", "--file", included.path, "branch.feature/dependent.base"]) == "main")
    }
}
