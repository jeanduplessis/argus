import Foundation
import Testing

@testable import Argus

extension WorkspaceStackMaintenanceTests {
    @Test
    func cleanupAcceptsCanonicalEvidenceForUnsortedFetchURLs() async throws {
        let repository = try StackRepositoryFixture()
        let sshURL = "ssh://git@github.example/owner/repo.git"
        let httpsURL = "https://github.example/owner/repo.git"
        try TestGit.run(["remote", "add", "origin", sshURL], in: repository.repository)
        try TestGit.run(["remote", "set-url", "--add", "origin", httpsURL], in: repository.repository)
        let branch = "feature/retained"
        let checkout = try repository.addWorktree(branch: branch)
        try TestGit.run(["config", "branch.\(branch).remote", "origin"], in: checkout)
        try TestGit.run(["config", "branch.\(branch).merge", "refs/heads/main"], in: checkout)
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let project = Project(repositoryPath: repository.repository.path, mainBranch: "main")
        let workspace = Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: branch, workspaceType: .worktree,
                worktreePath: checkout.path, title: "Retained", customTitle: nil,
                currentDirectory: checkout.path, panelCount: 0
            ))
        fixture.manager.appendPlacement(workspace.id, to: nil)
        fixture.manager.projects.insert(project, at: 0)
        fixture.manager.workspaces.append(workspace)
        let head = try TestGit.run(["rev-parse", "HEAD"], in: checkout)
        let registration = try TestGit.run(["worktree", "list", "--porcelain"], in: repository.repository)
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: workspace, project: project, branchName: branch, headCommitID: head
            ))
        let inputs = try await WorktreePullRequestLocalInputProvider(worktreeService: fixture.manager.worktreeService)
            .readWorktree(target: candidate.target)
        #expect(inputs.fetchRemotes == [GitFetchRemote(name: "origin", fetchURLs: [sshURL, httpsURL])])
        let evidence = Self.closeEvidence(for: candidate, inputs: inputs)
        #expect(evidence.fetchRemotes == [GitFetchRemote(name: "origin", fetchURLs: [httpsURL, sshURL])])
        #expect(evidence.branch.upstreamRepository == evidence.repository)
        try await fixture.manager.closeMergedWorkspaces([candidate], evidence: { _ in evidence })
        #expect(!fixture.manager.workspaces.contains { $0 === workspace })
        #expect(fixture.manager.workspaceIds(for: project).isEmpty)
        #expect(try TestGit.run(["rev-parse", branch], in: repository.repository) == head)
        #expect(try TestGit.run(["worktree", "list", "--porcelain"], in: repository.repository) == registration)
    }

    @Test(arguments: ["remote", "fetchURL", "upstream"])
    func cleanupRechecksRepositoryContextWithoutWaitingForStatusRefresh(_ change: String) async throws {
        let repository = try StackRepositoryFixture()
        try TestGit.run(["remote", "add", "origin", "https://github.example/owner/repo.git"], in: repository.repository)
        let branch = "feature/retained"
        let checkout = try repository.addWorktree(branch: branch)
        try TestGit.run(["config", "branch.\(branch).remote", "origin"], in: checkout)
        try TestGit.run(["config", "branch.\(branch).merge", "refs/heads/main"], in: checkout)
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let project = Project(repositoryPath: repository.repository.path, mainBranch: "main")
        let workspace = Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: project.id, branchName: branch, workspaceType: .worktree,
                worktreePath: checkout.path, title: "Retained", customTitle: nil,
                currentDirectory: checkout.path, panelCount: 0
            ))
        fixture.manager.appendPlacement(workspace.id, to: nil)
        fixture.manager.projects.insert(project, at: 0)
        fixture.manager.workspaces.append(workspace)
        let head = try TestGit.run(["rev-parse", "HEAD"], in: checkout)
        let candidate = try #require(
            MergedWorkspaceCloseCandidate(
                workspace: workspace, project: project, branchName: branch, headCommitID: head
            ))
        let inputs = try await WorktreePullRequestLocalInputProvider(worktreeService: fixture.manager.worktreeService)
            .readWorktree(target: candidate.target)
        let evidence = Self.closeEvidence(for: candidate, inputs: inputs)
        if change == "remote" {
            try TestGit.run(
                ["remote", "set-url", "origin", "https://github.example/owner/other.git"], in: repository.repository)
        } else if change == "fetchURL" {
            try TestGit.run(
                ["remote", "set-url", "origin", "ssh://git@github.example/owner/repo.git"], in: repository.repository)
        } else {
            try TestGit.run(["config", "branch.\(branch).merge", "refs/heads/other"], in: checkout)
        }
        #expect(evidence.isExactHeadMerged(for: candidate.target, branchName: branch, headCommitID: head, at: .now))
        #expect(try TestGit.run(["rev-parse", "HEAD"], in: checkout) == head)
        await #expect(throws: MergedWorkspaceCleanupError.self) {
            try await fixture.manager.closeMergedWorkspaces([candidate], evidence: { _ in evidence })
        }
        #expect(fixture.manager.workspaces.contains { $0 === workspace })
        #expect(fixture.manager.workspaceIds(for: project) == [workspace.id])
        #expect(try TestGit.run(["rev-parse", "HEAD"], in: checkout) == head)
    }

    static func closeEvidence(
        for candidate: MergedWorkspaceCloseCandidate, inputs: WorkspacePullRequestWorktreeInputs
    ) -> WorkspacePullRequestEvidence {
        let repository =
            inputs.branch.upstreamRepository
            ?? RepositoryIdentity(
                provider: .github, host: "github.example", owner: "owner", repositoryName: "repo"
            )
        return WorkspacePullRequestEvidence(
            target: candidate.target, repository: repository, branch: inputs.branch,
            fetchRemotes: GitFetchRemote.normalized(inputs.fetchRemotes),
            ownership: WorkspacePullRequestEvidence.Ownership(
                workspaceGeneration: UUID(), projectGeneration: UUID(), repositoryGeneration: UUID(),
                observationGeneration: UUID(), requestID: UUID()),
            status: PullRequestRuntimeFixture.status(
                branch: candidate.branchName, repository: repository, head: candidate.headCommitID, lifecycle: .merged),
            validatedAt: .now
        )
    }
}
