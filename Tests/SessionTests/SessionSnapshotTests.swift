import Foundation
import Testing

@testable import Argus

@Suite
struct SessionSnapshotTests {
    @Test
    func defaultRuntimeConfigurationPreservesStablePaths() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let configuration = ArgusRuntimeConfiguration(variant: nil, homeDirectory: home)

        #expect(configuration.sessionSnapshotURL.path == "/Users/test/Library/Application Support/Argus/session.json")
        #expect(configuration.reviewSessionURL.path == "/Users/test/Library/Application Support/Argus/review-session.json")
        #expect(configuration.reviewCacheDirectoryURL.path == "/Users/test/Library/Caches/Argus/Review")
        #expect(configuration.socketURL.path == "/Users/test/.argus/argus.sock")
        #expect(configuration.worktreeBaseURL.path == "/Users/test/.argus/worktrees")
    }

    @Test
    func buildVariantIsolatesEveryWritableRuntimePath() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let configuration = ArgusRuntimeConfiguration(variant: "feature-a", homeDirectory: home)

        #expect(configuration.sessionSnapshotURL.path == "/Users/test/Library/Application Support/Argus/Variants/feature-a/session.json")
        #expect(configuration.reviewSessionURL.path == "/Users/test/Library/Application Support/Argus/Variants/feature-a/review-session.json")
        #expect(configuration.reviewCacheDirectoryURL.path == "/Users/test/Library/Caches/Argus/Variants/feature-a/Review")
        #expect(configuration.socketURL.path == "/Users/test/.argus/Variants/feature-a/argus.sock")
        #expect(configuration.worktreeBaseURL.path == "/Users/test/.argus/Variants/feature-a/worktrees")
    }

    @Test
    func buildRunQuitsOnlyExistingArgusProcesses() throws {
        let script = try SourceContract("scripts/build.sh")

        script.containsAll(
            [
                "app.bundleIdentifier.js === bundleIdentifier",
                "NSRunningApplication.runningApplicationWithProcessIdentifier(${pid})",
                "if (app) app.terminate",
                "kill -0 \"${pid}\""
            ],
            "run and install must gracefully terminate the exact running app before replacement"
        )
        script.excludes(
            "tell application \\\"${APP_NAME}\\\" to quit",
            "name-based quit can launch another registered Argus bundle and overwrite its session"
        )
        let runSection = try script.section(after: "do_run() {", before: "do_install() {")
        let runQuit = try #require(runSection.range(of: "quit_running"))
        let runBuild = try #require(runSection.range(of: "do_build"))
        #expect(runQuit.lowerBound < runBuild.lowerBound)

        let installSection = try script.section(after: "do_install() {", before: "do_clean() {")
        let installQuit = try #require(installSection.range(of: "quit_running"))
        let installBuild = try #require(installSection.range(of: "do_build"))
        #expect(installQuit.lowerBound < installBuild.lowerBound)
    }

    @Test
    func buildVariantChangesBuildAndApplicationIdentity() throws {
        let script = try SourceContract("scripts/build.sh")

        script.containsAll(
            [
                "--variant NAME",
                "BUILD_DIR=\"${BASE_BUILD_DIR}/Variants/${BUILD_VARIANT}\"",
                "APP_NAME=\"Argus-${BUILD_VARIANT}\"",
                "APP_BUNDLE_IDENTIFIER=\"com.argus.app.variant.${VARIANT_IDENTIFIER}\"",
                "Add :ArgusBuildVariant string ${BUILD_VARIANT}"
            ],
            "variants must use isolated build products and application identities"
        )
    }

    @Test
    func coveredBehaviors() throws {
        let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let workspaceId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        let project = ProjectSnapshot(
            id: projectId,
            repositoryPath: "/tmp/repo",
            isCatchAll: false,
            displayName: "Repo",
            mainBranch: "main",
            workspaceIds: [workspaceId],
            isExpanded: false,
            color: .blue
        )
        let workspace = WorkspaceSnapshot(
            id: workspaceId,
            projectId: projectId,
            branchName: "feature/persist",
            workspaceType: .worktree,
            worktreePath: "/tmp/worktree",
            title: "feature/persist",
            customTitle: "Persist Work",
            currentDirectory: "/tmp/worktree",
            panelCount: 1
        )
        let snapshot = ArgusSessionSnapshot(
            schemaVersion: ArgusSessionSnapshot.currentSchemaVersion,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: encoded)

        assertEqual(
            decoded.schemaVersion, ArgusSessionSnapshot.currentSchemaVersion, "schema version round-trips"
        )
        assertEqual(decoded.projects.first?.id, projectId, "project id round-trips")
        assertEqual(decoded.projects.first?.isExpanded, false, "project expansion state round-trips")
        assertEqual(decoded.workspaces.first?.projectId, projectId, "workspace project id round-trips")
        assertEqual(
            decoded.workspaces.first?.branchName, "feature/persist", "workspace branch round-trips")
        assertEqual(
            decoded.workspaces.first?.worktreePath, "/tmp/worktree", "workspace worktree path round-trips"
        )
        assertEqual(decoded.selectedWorkspaceId, workspaceId, "selected workspace id round-trips")
        assertEqual(decoded.isCompatible, true, "current schema is compatible")

        assertFutureSchemaIsIncompatible(project: project, workspace: workspace, workspaceId: workspaceId)
    }

    @Test
    func oldProjectSnapshotDecodesWithoutHostedIdentity() throws {
        let oldJSON = #"{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","repositoryPath":"/tmp/repo","isCatchAll":false,"displayName":"Repo","mainBranch":"main","workspaceIds":[],"isExpanded":true,"color":null}"#
        let project = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(oldJSON.utf8))

        #expect(project.repositoryIdentity == nil)
        #expect(project.providerMetadata == nil)
        #expect(project.repositoryPath == "/tmp/repo")
    }

    @Test
    func namedProjectHostedAssociationRoundTripsAndCatchAllAssociationIsStrippedOnReconciliation() throws {
        let namedID = UUID()
        let catchAllID = UUID()
        let identity = RepositoryIdentity(host: "github.com", owner: "argus", name: "argus")
        let metadata = RepositoryProviderMetadata(provider: "github")
        let named = ProjectSnapshot(
            id: namedID, repositoryPath: "/tmp/argus", isCatchAll: false,
            displayName: "Argus", mainBranch: "main", workspaceIds: [],
            isExpanded: true, color: nil, repositoryIdentity: identity,
            providerMetadata: metadata
        )
        let catchAll = ProjectSnapshot(
            id: catchAllID, repositoryPath: "/incorrect", isCatchAll: true,
            displayName: "Workspaces", mainBranch: "incorrect", workspaceIds: [],
            isExpanded: true, color: nil, repositoryIdentity: identity,
            providerMetadata: metadata
        )
        let snapshot = ArgusSessionSnapshot(selectedWorkspaceId: nil, projects: [named, catchAll], workspaces: [])

        let decoded = try JSONDecoder().decode(ArgusSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        let reconciled = decoded.reconciledForRestore()

        let restoredNamed = try #require(reconciled.projects.first(where: { $0.id == namedID }))
        let restoredCatchAll = try #require(reconciled.projects.first(where: { $0.id == catchAllID }))
        #expect(restoredNamed.repositoryIdentity == identity)
        #expect(restoredNamed.providerMetadata == metadata)
        #expect(restoredCatchAll.repositoryIdentity == nil)
        #expect(restoredCatchAll.providerMetadata == nil)
    }

    private func assertFutureSchemaIsIncompatible(
        project: ProjectSnapshot,
        workspace: WorkspaceSnapshot,
        workspaceId: UUID
    ) {
        let incompatible = ArgusSessionSnapshot(
            schemaVersion: 999,
            selectedWorkspaceId: workspaceId,
            projects: [project],
            workspaces: [workspace]
        )
        assertEqual(incompatible.isCompatible, false, "future schema is incompatible")
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        #expect(actual == expected, Comment(rawValue: message))
    }
}
