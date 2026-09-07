import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct DependentProviderOwnershipTests {
    @Test(arguments: ["child-gh-stack", "changed-common-gh-stack", "graphite", "empty-graphite"])
    func newProviderTrackingPreservesAllResourcesEvenWhenEffectiveParentsMatch(_ source: String) async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.writeStack(branches: [fixture.parentBranch])
        let runner = StackGitTestRunner()
        let service = fixture.worktreeService(runner: runner)
        let expected = try await fixture.context()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        let before = try service.stackParentService.reader.read(repositoryPath: fixture.repository.path)
        let path = URL(fileURLWithPath: created.worktreePath)
        #expect(try fixture.git(["status", "--porcelain=v1"], at: path).isEmpty)
        let provider: URL?
        switch source {
        case "child-gh-stack":
            provider = URL(fileURLWithPath: created.childContext.checkout.gitDirectory).appendingPathComponent(
                "gh-stack")
            try matchingStackData(fixture: fixture).write(to: #require(provider))
        case "changed-common-gh-stack":
            provider = fixture.metadataURL
            let bytes = try Data(contentsOf: fixture.metadataURL) + Data("\n".utf8)
            try bytes.write(to: fixture.metadataURL, options: .atomic)
        default:
            provider = nil
            try fixture.writeGraphite(
                branch: created.branchName, parent: source == "graphite" ? fixture.parentBranch : nil)
        }
        let providerBytes = try provider.map { try Data(contentsOf: $0) }
        let graphiteID =
            try source.contains("graphite")
            ? fixture.git(["rev-parse", "refs/branch-metadata/\(created.branchName)"]) : nil
        let after = try service.stackParentService.reader.read(repositoryPath: fixture.repository.path)
        #expect(after == before)
        let configuration = try Data(contentsOf: fixture.configurationURL)
        #expect(!(await service.rollbackDependentWorktree(created)))
        #expect(fixture.branchExists(created.branchName))
        #expect(try fixture.git(["rev-parse", "refs/heads/\(created.branchName)"]) == created.headCommitID)
        #expect(FileManager.default.fileExists(atPath: created.worktreePath))
        #expect(try Data(contentsOf: fixture.configurationURL) == configuration)
        if let provider {
            #expect(try Data(contentsOf: provider) == providerBytes)
        }
        if let graphiteID {
            #expect(try fixture.git(["rev-parse", "refs/branch-metadata/\(created.branchName)"]) == graphiteID)
        }
        #expect(!runner.invocations.contains { $0.contains("worktree") && $0.contains("remove") })
    }

    private func matchingStackData(fixture: StackMaintenanceFixture) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "stacks": [
                [
                    "trunk": ["branch": "main"],
                    "branches": [["branch": fixture.parentBranch], ["branch": "feature/dependent"]]
                ]
            ]
        ])
    }
}
