import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct DependentSubmoduleSafetyTests {
    @Test
    func recursiveUserConfigurationCannotRunTheSubmoduleTransport() async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        let url = "ext::/bin/sh \(marker.executable.path) \(marker.marker.path)"
        try recordSubmodule(in: fixture, url: url)
        try fixture.git(["config", "submodule.recurse", "true"])
        try fixture.git(["config", "fetch.recurseSubmodules", "true"])
        try fixture.git(["config", "protocol.ext.allow", "always"])
        let expected = try await fixture.context()
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        #expect(!marker.executed)
        #expect(created.headCommitID == expected.headCommitID)
        #expect(!FileManager.default.fileExists(atPath: created.worktreePath + "/deps/nested/.git"))
        #expect(try fixture.git(["config", "--local", "--get", "submodule.recurse"]) == "true")
        #expect(try fixture.git(["config", "--local", "--get", "fetch.recurseSubmodules"]) == "true")
        #expect(!(await service.rollbackDependentWorktree(created)))
        #expect(!marker.executed)
        #expect(fixture.branchExists(created.branchName))
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
    }

    @Test(arguments: ["clean", "process"])
    func rollbackDoesNotInspectFiltersInsideAPopulatedSubmodule(_ mechanism: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        try recordSubmodule(in: fixture, url: fixture.repository.path)
        let expected = try await fixture.context()
        let runner = StackGitTestRunner()
        let service = fixture.worktreeService(runner: runner)
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        let nested = URL(fileURLWithPath: created.worktreePath).appendingPathComponent("deps/nested")
        try fixture.git(["clone", "--no-checkout", "--no-hardlinks", fixture.repository.path, nested.path])
        try fixture.git(["checkout", "--detach", fixture.parentCommit], at: nested)
        try fixture.git(["config", "filter.nested.\(mechanism)", marker.command], at: nested)
        try Data("base.txt filter=nested\n".utf8).write(to: nested.appendingPathComponent(".gitattributes"))
        let changes = Data("nested Working Changes\n".utf8)
        try changes.write(to: nested.appendingPathComponent("base.txt"))
        let commandCount = runner.invocations.count
        #expect(!(await service.rollbackDependentWorktree(created)))
        #expect(!marker.executed)
        #expect(try Data(contentsOf: nested.appendingPathComponent("base.txt")) == changes)
        #expect(fixture.branchExists(created.branchName))
        #expect(!runner.invocations.dropFirst(commandCount).contains { $0.contains("status") })
        #expect(!runner.invocations.contains { $0.contains("worktree") && $0.contains("remove") })
    }

    private func recordSubmodule(in fixture: StackMaintenanceFixture, url: String) throws {
        let modules = fixture.parent.appendingPathComponent(".gitmodules")
        try fixture.git(["config", "--file", modules.path, "submodule.nested.path", "deps/nested"])
        try fixture.git(["config", "--file", modules.path, "submodule.nested.url", url])
        try fixture.git(["add", ".gitmodules"], at: fixture.parent)
        try fixture.git(
            ["update-index", "--add", "--cacheinfo", "160000,\(fixture.parentCommit),deps/nested"], at: fixture.parent)
        try fixture.git(["commit", "-m", "record submodule"], at: fixture.parent)
    }
}
