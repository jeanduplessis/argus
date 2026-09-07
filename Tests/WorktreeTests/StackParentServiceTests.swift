import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct StackParentServiceTests {
    @Test
    func inspectsActualCanonicalWorkspaceBranchAndHeadWithoutChangingDirtyFiles() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.makeDirtyParent()
        try fixture.writeStack(branches: [fixture.parentBranch])
        let alias = fixture.root.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.parent)
        let before = try fixture.git(["status", "--porcelain=v1"], at: fixture.parent)
        let context = try await fixture.service().inspect(
            repositoryPath: fixture.repository.path, worktreePath: alias.path)
        #expect(context.repositoryPath == fixture.repository.path)
        #expect(context.worktreePath == fixture.parent.path)
        #expect(context.branchName == fixture.parentBranch)
        #expect(context.headCommitID == fixture.parentCommit)
        #expect(context.headCommitID != fixture.projectCommit)
        #expect(context.recordedParent == "main")
        #expect(context.sourceDescription == "Graphite / gh-stack metadata")
        #expect(!context.hasLocalOverride)
        #expect(try fixture.git(["status", "--porcelain=v1"], at: fixture.parent) == before)
    }

    @Test
    func localOverridePreservesGlobalIncludedAndProviderConfiguration() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["branch", "alternate", "main"])
        try fixture.writeStack(branches: [fixture.parentBranch])
        try fixture.writeGraphite(branch: fixture.parentBranch, parent: "main")
        try fixture.git([
            "config", "--file", fixture.globalConfigurationURL.path, "branch.\(fixture.parentBranch).base", "main"
        ])
        let included = fixture.root.appendingPathComponent("included-config")
        try Data("[unrelated]\n\tsetting = preserved\n".utf8).write(to: included)
        try fixture.git(["config", "include.path", included.path])
        try fixture.git(["config", "unrelated.private-value", "fixture-sensitive"])
        let globalBefore = try Data(contentsOf: fixture.globalConfigurationURL)
        let includeBefore = try Data(contentsOf: included)
        let providerBefore = try Data(contentsOf: fixture.metadataURL)
        let service = fixture.service()
        let original = try await fixture.context(using: service)
        #expect(original.sourceDescription == "Global configuration")
        let edited = try await service.setParent("alternate", expected: original)
        #expect(edited.recordedParent == "alternate")
        #expect(edited.localOverride == "alternate")
        #expect(edited.sourceDescription == "Repository-local configuration")
        #expect(
            try service.reader.read(repositoryPath: fixture.repository.path).parents[fixture.parentBranch]
                == "alternate")
        let removed = try await service.setParent(nil, expected: edited)
        #expect(removed.recordedParent == "main")
        #expect(!removed.hasLocalOverride)
        #expect(removed.sourceDescription == "Global configuration")
        #expect(try Data(contentsOf: fixture.globalConfigurationURL) == globalBefore)
        #expect(try Data(contentsOf: included) == includeBefore)
        #expect(try Data(contentsOf: fixture.metadataURL) == providerBefore)
        #expect(try fixture.git(["config", "unrelated.private-value"]) == "fixture-sensitive")
        #expect(!removed.sourceDescription.contains("fixture-sensitive"))
    }

    @Test
    func removingLocalOverrideExposesProviderParentInsteadOfDetaching() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["branch", "alternate", "main"])
        try fixture.writeStack(branches: [fixture.parentBranch])
        let service = fixture.service()
        let original = try await fixture.context(using: service)
        let override = try await service.setParent("alternate", expected: original)
        let removed = try await service.setParent(nil, expected: override)
        #expect(removed.recordedParent == "main")
        #expect(removed.localOverride == nil)
        #expect(removed.sourceDescription == "Graphite / gh-stack metadata")
        #expect(try fixture.git(["symbolic-ref", "--short", "HEAD"], at: fixture.parent) == fixture.parentBranch)
    }

    @Test(arguments: ["HEAD", "--unsafe", "bad..name", "bad\nname", "", String(repeating: "a", count: 4_097)])
    func rejectsInvalidParentNamesWithoutWriting(_ name: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let context = try await fixture.context()
        let before = try Data(contentsOf: fixture.configurationURL)
        await #expect(throws: StackParentError.invalidBranchName) {
            try await fixture.service().setParent(name, expected: context)
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
    }

    @Test
    func rejectsSelfCyclesAndUnresolvableParents() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["branch", "dependent", fixture.parentCommit])
        try fixture.git(["config", "branch.dependent.base", fixture.parentBranch])
        let context = try await fixture.context()
        let before = try Data(contentsOf: fixture.configurationURL)
        for (parent, error) in [
            (fixture.parentBranch, StackParentError.selfParent),
            ("dependent", StackParentError.parentCycle),
            ("missing-parent", StackParentError.parentNotResolvable)
        ] {
            await #expect(throws: error) { try await fixture.service().setParent(parent, expected: context) }
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
    }

    @Test
    func acceptsLocallyAvailableOriginTrackingParentWithoutFetching() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["update-ref", "refs/remotes/origin/remote-parent", fixture.projectCommit])
        let runner = StackGitTestRunner()
        let context = try await fixture.context()
        let edited = try await fixture.service(runner: runner).setParent("remote-parent", expected: context)
        #expect(edited.recordedParent == "remote-parent")
        #expect(!fixture.branchExists("remote-parent"))
        #expect(!runner.invocations.contains { $0.contains("fetch") || $0.contains("ls-remote") })
    }

    @Test(arguments: ["head", "branch", "configuration", "provider", "global"])
    func rejectsChangedOptimisticContext(_ change: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let context = try await fixture.context()
        switch change {
        case "head": try fixture.git(["commit", "--allow-empty", "-m", "later parent work"], at: fixture.parent)
        case "branch": try fixture.git(["switch", "-c", "replacement"], at: fixture.parent)
        case "configuration": try fixture.git(["config", "unrelated.changed", "true"])
        case "provider": try fixture.writeStack(branches: [fixture.parentBranch])
        default:
            try fixture.git([
                "config", "--file", fixture.globalConfigurationURL.path, "branch.\(fixture.parentBranch).base", "main"
            ])
        }
        let before = try Data(contentsOf: fixture.configurationURL)
        await #expect(throws: StackParentError.self) {
            try await fixture.service().setParent("main", expected: context)
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
    }

    @Test(arguments: ["worktree", "included", "command", "multiple"])
    func refusesUnsafeConfigurationSources(_ source: String) async throws {
        let fixture = try StackMaintenanceFixture()
        let key = "branch.\(fixture.parentBranch).base"
        var environment = fixture.environment
        switch source {
        case "worktree":
            try fixture.git(["config", "extensions.worktreeConfig", "true"])
            try fixture.git(["config", "--worktree", key, "main"], at: fixture.parent)
        case "included":
            let included = fixture.root.appendingPathComponent("parent-config")
            try fixture.git(["config", "--file", included.path, key, "main"])
            try fixture.git(["config", "include.path", included.path])
        case "command":
            environment["GIT_CONFIG_COUNT"] = "1"
            environment["GIT_CONFIG_KEY_0"] = key
            environment["GIT_CONFIG_VALUE_0"] = "main"
        default:
            try fixture.git(["config", "--add", key, "main"])
            try fixture.git(["config", "--add", key, "main"])
        }
        let service = StackParentService(environment: environment)
        let context = try await fixture.context(using: service)
        #expect(context.editingIssue != nil)
        let before = try Data(contentsOf: fixture.configurationURL)
        await #expect(throws: StackParentError.self) { try await service.setParent("main", expected: context) }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
    }

    @Test
    func removalThatExposesAProviderCycleRestoresTheLocalOverride() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["branch", "dependent", fixture.parentCommit])
        try fixture.writeStack(trunk: fixture.parentBranch, branches: ["dependent", fixture.parentBranch])
        try fixture.git(["config", "branch.\(fixture.parentBranch).base", "main"])
        let context = try await fixture.context()
        let before = try Data(contentsOf: fixture.configurationURL)
        await #expect(throws: StackParentError.readbackFailed) {
            try await fixture.service().setParent(nil, expected: context)
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == before)
        #expect(try await fixture.context().recordedParent == "main")
    }
}
