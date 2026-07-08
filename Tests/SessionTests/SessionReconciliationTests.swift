import Foundation
import Testing

@testable import Argus

@Suite
struct SessionReconciliationTests {
  @Test
  func coveredBehaviors() throws {
    let projectId = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let catchAllId = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    let duplicateCatchAllId = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
    let invalidProjectId = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
    let validWorkspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let invalidProjectWorkspaceId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let missingProjectWorkspaceId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let staleWorkspaceId = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

    let project = ProjectSnapshot(
      id: projectId,
      repositoryPath: "/repo",
      isCatchAll: false,
      displayName: "Repo",
      mainBranch: "main",
      workspaceIds: [staleWorkspaceId, validWorkspaceId],
      isExpanded: true,
      color: nil
    )
    let catchAll = ProjectSnapshot(
      id: catchAllId,
      repositoryPath: "",
      isCatchAll: true,
      displayName: "Workspaces",
      mainBranch: "",
      workspaceIds: [],
      isExpanded: true,
      color: nil
    )
    let duplicateCatchAll = ProjectSnapshot(
      id: duplicateCatchAllId,
      repositoryPath: "",
      isCatchAll: true,
      displayName: "Old Workspaces",
      mainBranch: "",
      workspaceIds: [staleWorkspaceId],
      isExpanded: false,
      color: nil
    )

    let validWorkspace = workspace(
      id: validWorkspaceId,
      projectId: projectId,
      branchName: "main",
      type: .mainCheckout,
      directory: "/repo"
    )
    let invalidProjectWorkspace = workspace(
      id: invalidProjectWorkspaceId,
      projectId: invalidProjectId,
      branchName: nil,
      type: .external,
      directory: "/tmp/invalid"
    )
    let missingProjectWorkspace = workspace(
      id: missingProjectWorkspaceId,
      projectId: nil,
      branchName: nil,
      type: .external,
      directory: "/tmp/missing"
    )

    let reconciled = ArgusSessionSnapshot(
      selectedWorkspaceId: invalidProjectWorkspaceId,
      projects: [project, catchAll, duplicateCatchAll],
      workspaces: [validWorkspace, invalidProjectWorkspace, missingProjectWorkspace]
    ).reconciledForRestore()

    let catchAllProjects = reconciled.projects.filter(\.isCatchAll)
    assertEqual(catchAllProjects.count, 1, "restore has exactly one catch-all")
    assertEqual(catchAllProjects[0].id, catchAllId, "first catch-all identity is preserved")

    let restoredProject = reconciled.projects.first { $0.id == projectId }!
    assertEqual(
      restoredProject.workspaceIds, [validWorkspaceId],
      "stale refs are removed and valid order is preserved")

    let restoredCatchAll = catchAllProjects[0]
    assertEqual(
      restoredCatchAll.workspaceIds,
      [invalidProjectWorkspaceId, missingProjectWorkspaceId],
      "invalid or missing workspace project IDs are attached to catch-all"
    )

    assertEqual(
      reconciled.workspaces.first { $0.id == invalidProjectWorkspaceId }?.projectId,
      catchAllId,
      "invalid project ID is rewritten to catch-all"
    )
    assertEqual(
      reconciled.workspaces.first { $0.id == missingProjectWorkspaceId }?.projectId,
      catchAllId,
      "missing project ID is rewritten to catch-all"
    )

    let rereconciled = reconciled.reconciledForRestore()
    assertEqual(
      rereconciled.projects.map(\.workspaceIds), reconciled.projects.map(\.workspaceIds),
      "reconciliation is idempotent for project membership")
    assertEqual(
      rereconciled.workspaces.map(\.projectId), reconciled.workspaces.map(\.projectId),
      "reconciliation is idempotent for workspace membership")
  }

  private func workspace(
    id: UUID,
    projectId: UUID?,
    branchName: String?,
    type: WorkspaceType,
    directory: String
  ) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      id: id,
      projectId: projectId,
      branchName: branchName,
      workspaceType: type,
      worktreePath: type == .worktree ? directory : nil,
      title: branchName ?? "Terminal",
      customTitle: nil,
      currentDirectory: directory,
      panelCount: 1
    )
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}
