import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct DependentWorktreeRollbackTests {
    @Test
    func rollbackRestoresExactConfigurationAndRemovesTheCleanAttempt() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let original = try Data(contentsOf: fixture.configurationURL)
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        #expect(await service.rollbackDependentWorktree(created))
        try fixture.expectNoDependent()
        #expect(!FileManager.default.fileExists(atPath: created.worktreePath))
        #expect(try Data(contentsOf: fixture.configurationURL) == original)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: fixture.parent) == fixture.parentCommit)
    }

    @Test(arguments: [
        "untracked", "tracked", "ignored", "assume-unchanged", "commit", "configuration", "reflog", "locked"
    ])
    func rollbackRetainsAllResourcesWhenOneHasChanged(_ change: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        let path = URL(fileURLWithPath: created.worktreePath)
        switch change {
        case "untracked": try Data("keep\n".utf8).write(to: path.appendingPathComponent("new.txt"))
        case "tracked": try Data("keep\n".utf8).write(to: path.appendingPathComponent("base.txt"))
        case "ignored":
            let exclude = fixture.repository.appendingPathComponent(".git/info/exclude")
            let data = try Data(contentsOf: exclude) + Data("\nignored-file\n".utf8)
            try data.write(to: exclude)
            try Data("keep\n".utf8).write(to: path.appendingPathComponent("ignored-file"))
        case "assume-unchanged":
            try fixture.git(["update-index", "--assume-unchanged", "base.txt"], at: path)
            try Data("hidden user changes\n".utf8).write(to: path.appendingPathComponent("base.txt"))
        case "commit": try fixture.git(["commit", "--allow-empty", "-m", "new user work"], at: path)
        case "configuration": try fixture.git(["config", "unrelated.changed", "preserve"])
        case "reflog":
            try fixture.git(["update-ref", "-m", "external move", "refs/heads/feature/dependent", fixture.projectCommit]
            )
            try fixture.git([
                "update-ref", "-m", "external return", "refs/heads/feature/dependent", fixture.parentCommit
            ])
        default: try fixture.git(["worktree", "lock", path.path])
        }
        let configuration = try Data(contentsOf: fixture.configurationURL)
        #expect(!(await service.rollbackDependentWorktree(created)))
        #expect(fixture.branchExists("feature/dependent"))
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try Data(contentsOf: fixture.configurationURL) == configuration)
    }

    @Test(arguments: ["dirty", "head", "configuration", "locked"])
    func failedAddWithChangedResourcesReportsActionableRetainedPaths(_ change: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("worktree"), arguments.contains("add"), once.take(),
                let separator = arguments.firstIndex(of: "--")
            else { return nil }
            let path = URL(fileURLWithPath: arguments[separator + 1])
            switch change {
            case "dirty": try Data("keep my work\n".utf8).write(to: path.appendingPathComponent("keep.txt"))
            case "head": try fixture.git(["commit", "--allow-empty", "-m", "user commit"], at: path)
            case "configuration": try fixture.git(["config", "unrelated.value", "retained"])
            default: try fixture.git(["worktree", "lock", path.path])
            }
            throw StackParentError.commandFailed
        }
        do {
            _ = try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
            Issue.record("The failed attempt must report retained resources")
        } catch let error as DependentWorkspaceError {
            guard case .retainedResources(let repository, let branch, let path, let configuration) = error else {
                Issue.record("Expected recovery paths, got \(error)")
                return
            }
            #expect(repository == fixture.repository.path)
            #expect(branch == "feature/dependent")
            #expect(configuration == fixture.configurationURL.path)
            let retainedPath = try #require(path)
            #expect(FileManager.default.fileExists(atPath: retainedPath))
            #expect(fixture.branchExists(branch))
            if change == "dirty" {
                #expect(try String(contentsOfFile: retainedPath + "/keep.txt", encoding: .utf8) == "keep my work\n")
            }
        }
        #expect(!runner.invocations.contains { $0.contains("--force") || $0.contains("-D") })
    }

    @Test
    func reportedRegistrationFailureNeverForcesAnUnmaterializedCheckoutRemoval() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let original = try Data(contentsOf: fixture.configurationURL)
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("worktree"), arguments.contains("add"), once.take() else {
                return nil
            }
            throw StackParentError.commandFailed
        }
        do {
            _ = try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
            Issue.record("A reported registration failure must not attach a Workspace")
        } catch let error as DependentWorkspaceError {
            guard case .retainedResources(_, let branch, let path, _) = error else {
                Issue.record("Expected actionable retained resources")
                return
            }
            let retainedPath = try #require(path)
            #expect(try FileManager.default.contentsOfDirectory(atPath: retainedPath) == [".git"])
            #expect(try fixture.git(["rev-parse", "refs/heads/\(branch)"]) == fixture.parentCommit)
        } catch {
            #expect(error as? StackParentError == .commandFailed)
            try fixture.expectNoDependent()
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == original)
        #expect(!runner.invocations.contains { $0.contains("--force") || $0.contains("-D") })
    }

    @Test
    func branchCreatedBeforeAReportedUpdateFailureIsStillAttemptOwned() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("--create-reflog"), once.take() else { return nil }
            #expect(fixture.branchExists("feature/dependent"))
            throw StackParentError.commandFailed
        }
        await #expect(throws: StackParentError.commandFailed) {
            try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        try fixture.expectNoDependent()
    }

    @Test
    func storageSlugCollisionDoesNotReuseOrDeleteAnExistingDirectory() async throws {
        let fixture = try StackMaintenanceFixture()
        let occupied = fixture.storageURL.appendingPathComponent(fixture.projectID.uuidString)
            .appendingPathComponent("feature-dependent")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let file = occupied.appendingPathComponent("existing.txt")
        try Data("unowned".utf8).write(to: file)
        let expected = try await fixture.context()
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        #expect(created.worktreePath == occupied.path + "-1")
        #expect(await service.rollbackDependentWorktree(created))
        #expect(try String(contentsOf: file, encoding: .utf8) == "unowned")
    }
}
