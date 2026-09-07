import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct DependentCheckoutFilterTests {
    @Test(arguments: ["smudge", "process"])
    func refusesCommittedFiltersWithoutExecutingTheMarker(_ mechanism: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        let objectID = String(repeating: "0", count: 64)
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:\(objectID)\nsize 1\n".utf8)
        try pointer.write(to: fixture.parent.appendingPathComponent("filtered.bin"))
        try Data("filtered.bin filter=lfs\n".utf8).write(to: fixture.parent.appendingPathComponent(".gitattributes"))
        try fixture.git(["add", "filtered.bin", ".gitattributes"], at: fixture.parent)
        try fixture.git(["commit", "-m", "filtered content"], at: fixture.parent)
        try fixture.git(["config", "filter.lfs.\(mechanism)", marker.command])
        try fixture.git(["config", "filter.lfs.required", "true"])
        let expected = try await fixture.context()
        let configuration = try Data(contentsOf: fixture.configurationURL)
        #expect(!marker.executed)
        await #expect(throws: DependentWorkspaceError.checkoutFiltersUnsupported(recovery: nil)) {
            try await fixture.worktreeService().createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        #expect(!marker.executed)
        #expect(try Data(contentsOf: fixture.parent.appendingPathComponent("filtered.bin")) == pointer)
        #expect(try Data(contentsOf: fixture.configurationURL) == configuration)
        try fixture.expectNoDependent()
    }

    @Test(arguments: ["onbranch", "gitdir"])
    func checksConditionalChildAttributesBeforeMaterializingFiles(_ condition: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        let configuration = try configureChildOnlyFilter(fixture: fixture, marker: marker, condition: condition)
        let expected = try await fixture.context()
        let checkedChild = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("worktree"), arguments.contains("add"),
                let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count, checkedChild.take()
            else { return nil }
            let child = URL(fileURLWithPath: arguments[separator + 1])
            try Self.assertChildFilterConfiguration(
                fixture: fixture, marker: marker, configuration: configuration, at: child)
            return nil
        }
        do {
            _ = try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
            Issue.record("Child-only filter configuration must prevent checkout")
        } catch let error as DependentWorkspaceError {
            guard case .checkoutFiltersUnsupported(let recovery) = error else {
                Issue.record("Expected a filter-specific refusal")
                return
            }
            if fixture.branchExists("feature/dependent") {
                let recovery = try #require(recovery)
                let path = fixture.storageURL.appendingPathComponent(fixture.projectID.uuidString)
                    .appendingPathComponent("feature-dependent").path
                #expect(recovery.contains(path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: path) == [".git"])
            }
        }
        #expect(!checkedChild.take(), "The registered child must be inspected before filter validation")
        #expect(!marker.executed)
        #expect(!runner.invocations.contains { $0.contains("checkout-index") })
        #expect(
            try fixture.git(["config", "--file", configuration.included.path, "filter.marker.process"])
                == marker.command)
    }

    @Test
    func unusedGlobalLfsConfigurationDoesNotRejectAnUnfilteredCheckout() async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        try fixture.git(["config", "--file", fixture.globalConfigurationURL.path, "filter.lfs.process", marker.command])
        try fixture.git(["config", "--file", fixture.globalConfigurationURL.path, "filter.lfs.required", "true"])
        let configuration = try Data(contentsOf: fixture.globalConfigurationURL)
        let expected = try await fixture.context()
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        #expect(!marker.executed)
        #expect(try String(contentsOfFile: created.worktreePath + "/base.txt", encoding: .utf8) == "base\n")
        #expect(try String(contentsOfFile: created.worktreePath + "/parent.txt", encoding: .utf8) == "parent\n")
        #expect(try Data(contentsOf: fixture.globalConfigurationURL) == configuration)
        #expect(await service.rollbackDependentWorktree(created))
        #expect(!marker.executed)
    }

    @Test
    func aFilterActivatedAfterPreflightCannotExecuteOrSilentlyMaterializePointers() async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        try fixture.git(["config", "--file", fixture.globalConfigurationURL.path, "filter.lfs.process", marker.command])
        let expected = try await fixture.context()
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, path, phase in
            guard phase == .before, arguments.contains("checkout-index"), once.take() else { return nil }
            try Data("base.txt filter=lfs\n".utf8).write(
                to: URL(fileURLWithPath: path).appendingPathComponent(".gitattributes"))
            return nil
        }
        await #expect(throws: DependentWorkspaceError.self) {
            try await fixture.worktreeService(runner: runner).createDependentWorktree(
                projectId: fixture.projectID, repositoryPath: fixture.repository.path,
                branchName: "feature/dependent", expectedParent: expected)
        }
        #expect(!marker.executed)
        let path = fixture.storageURL.appendingPathComponent(fixture.projectID.uuidString)
            .appendingPathComponent("feature-dependent")
        #expect(fixture.branchExists("feature/dependent"))
        #expect(
            try String(contentsOf: path.appendingPathComponent(".gitattributes"), encoding: .utf8)
                == "base.txt filter=lfs\n")
    }

    @Test(arguments: ["clean", "process"])
    func rollbackDoesNotExecuteANewlyActivatedCleanOrProcessFilter(_ mechanism: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let marker = try StackExecutableMarker(root: fixture.root)
        try fixture.git([
            "config", "--file", fixture.globalConfigurationURL.path, "filter.lfs.\(mechanism)", marker.command
        ])
        let expected = try await fixture.context()
        let service = fixture.worktreeService()
        let created = try await service.createDependentWorktree(
            projectId: fixture.projectID, repositoryPath: fixture.repository.path,
            branchName: "feature/dependent", expectedParent: expected)
        let path = URL(fileURLWithPath: created.worktreePath)
        try Data("base.txt filter=lfs\n".utf8).write(to: path.appendingPathComponent(".gitattributes"))
        let changes = Data("new private Working Changes\n".utf8)
        try changes.write(to: path.appendingPathComponent("base.txt"))
        #expect(!(await service.rollbackDependentWorktree(created)))
        #expect(!marker.executed)
        #expect(fixture.branchExists("feature/dependent"))
        #expect(try Data(contentsOf: path.appendingPathComponent("base.txt")) == changes)
        #expect(FileManager.default.fileExists(atPath: path.appendingPathComponent(".gitattributes").path))
    }

    private struct ConditionalFilterConfiguration: Sendable {
        let attributes: URL
        let included: URL
        let gitDirectory: String
    }

    private func configureChildOnlyFilter(
        fixture: StackMaintenanceFixture, marker: StackExecutableMarker, condition: String
    ) throws -> ConditionalFilterConfiguration {
        let attributes = fixture.root.appendingPathComponent("child-attributes")
        let included = fixture.root.appendingPathComponent("child-config")
        let commonDirectory = try fixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let gitDirectory = commonDirectory + "/worktrees/feature-dependent"
        try Data("base.txt filter=marker\n".utf8).write(to: attributes)
        try fixture.git(["config", "--file", included.path, "core.attributesFile", attributes.path])
        try fixture.git(["config", "--file", included.path, "filter.marker.process", marker.command])
        try fixture.git(["config", "--file", included.path, "filter.marker.required", "true"])
        let predicate = condition == "onbranch" ? "onbranch:feature/dependent" : "gitdir:\(gitDirectory)"
        try fixture.git(["config", "includeIf.\(predicate).path", included.path])
        #expect(
            try fixture.git(["config", "--includes", "--get", "core.attributesFile"], at: fixture.parent)
                == "/dev/null")
        #expect(
            (try? fixture.git(["config", "--includes", "--get", "filter.marker.process"], at: fixture.parent)) == nil)
        return ConditionalFilterConfiguration(attributes: attributes, included: included, gitDirectory: gitDirectory)
    }

    private static func assertChildFilterConfiguration(
        fixture: StackMaintenanceFixture, marker: StackExecutableMarker,
        configuration: ConditionalFilterConfiguration, at child: URL
    ) throws {
        let actualGitDirectory = try fixture.git(["rev-parse", "--absolute-git-dir"], at: child)
        #expect(actualGitDirectory == configuration.gitDirectory)
        let attributesFile = try fixture.git(["config", "--includes", "--get", "core.attributesFile"], at: child)
        #expect(attributesFile == configuration.attributes.path)
        #expect(
            try fixture.git(["config", "--includes", "--get", "filter.marker.process"], at: child)
                == marker.command)
        #expect(try fixture.git(["config", "--includes", "--get", "filter.marker.required"], at: child) == "true")
        #expect(
            try fixture.git(["check-attr", "--source=HEAD", "-z", "filter", "--", "base.txt"], at: child)
                == "base.txt\0filter\0marker\0")
    }
}
