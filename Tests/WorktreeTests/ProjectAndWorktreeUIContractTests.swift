import Testing

@Suite
struct ProjectAndWorktreeUIContractTests {
  @Test
  func projectCreationSupportsCanonicalDuplicatesAndManualMainBranches() throws {
    let sheet = try SourceContract("Argus/Views/Dialogs/NewProjectSheet.swift")
    sheet.containsAll(
      [
        "@State private var mainBranch: String = \"\"",
        "@State private var isRepositoryValid: Bool = false",
        "@State private var branchDetectionWarning: String?",
        "TextField(\"Main branch\", text: $mainBranch)",
        "mainBranch = branch",
        "mainBranchOverride: branch.isEmpty ? nil : branch",
        "workspaceManager.hasDuplicateProject(repositoryRoot: repositoryRoot)",
        "validationError = \"Project already exists for this repository\"",
        "branchDetectionWarning = \"Could not detect main branch. Enter one manually.\"",
        ".padding(.vertical, 28)",
      ], "new project validation and main-branch override")
    let canCreate = try sheet.section(after: "private var canCreate: Bool {", before: "\n    }")
    #expect(canCreate.contains("isRepositoryValid"))
    #expect(!canCreate.contains("detectedBranch != nil"))
    #expect(!canCreate.contains("branchDetectionWarning"))

    let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
    manager.containsAll(
      [
        "func hasDuplicateProject(repositoryRoot: String) -> Bool",
        "hasDuplicateProject(repositoryRoot: repositoryRoot)",
        "mainBranchOverride: String? = nil",
        "let mainBranch = normalizedMainBranch.isEmpty ? (detectedMainBranch ?? \"\") : normalizedMainBranch",
        "guard !mainBranch.isEmpty else { return nil }",
        "let detectedMainBranch = try? await worktreeService.detectMainBranch",
      ], "workspace manager project validation")
    let duplicateCheck = try manager.section(
      after: "func hasDuplicateProject(repositoryRoot:",
      before: "\n    /// Creates a new workspace"
    )
    #expect(duplicateCheck.contains("!$0.isCatchAll"))
    #expect(duplicateCheck.contains("resolvingSymlinksInPath().path"))
  }

  @Test
  func projectAndCatchAllAddActionsStayDistinct() throws {
    let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
    sidebar.containsAll(
      [
        "Menu {",
        "Label(\"New Workspace\", systemImage: \"terminal\")",
        "Label(\"New Project…\", systemImage: \"folder.badge.plus\")",
        "Image(systemName: \"plus\")",
        "if project.isCatchAll {",
        "workspaceManager.addWorkspace()",
        "name: .showNewWorkspaceSheet",
        "userInfo: [\"projectId\": project.id]",
        "Button(\"Add Workspace…\")",
      ], "project and catch-all add controls")
  }

  @Test
  func branchPickerFiltersChoicesAndRecoversFromTimeouts() throws {
    let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
    sheet.containsAll(
      [
        "@State private var branchFilter: String = \"\"",
        "private var filteredAvailableBranches: [String]",
        "localizedCaseInsensitiveContains(filter)",
        "TextField(\"Filter branches\", text: $branchFilter)",
        "ForEach(filteredAvailableBranches, id: \\.self)",
        "selectedExistingBranch = branch",
        "listWorkspaceBranchChoices(",
        "repositoryPath: project.repositoryPath",
        "defer { isLoadingBranches = false }",
        "errorMessage = error.localizedDescription",
      ], "existing branch picker")

    let service = try SourceContract("Argus/Services/WorktreeService.swift")
    service.containsAll(
      [
        "timeout: TimeInterval? = nil",
        "Task.sleep(nanoseconds:",
        "process.terminate()",
        "func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String]",
        "!worktree.isHead",
      ], "branch discovery and timeout behavior")
    let remoteHeads = try service.section(
      after: "private func listRemoteHeadBranches",
      before: "\n    /// Lists all worktrees"
    )
    #expect(remoteHeads.contains("ls-remote"))
    #expect(remoteHeads.contains("timeout:"))
  }

  @Test
  func duplicateBranchesAreRejectedWithAVisibleError() throws {
    let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
    let addWorkspace = try manager.section(
      after: "func addWorkspaceToProject(",
      before: "\n    // MARK: - Selection"
    )
    #expect(!addWorkspace.contains("uniqueBranchName(branchName"))
    #expect(
      addWorkspace.contains(
        "try await worktreeService.ensureBranchNameAvailable(branchName, repositoryPath: project.repositoryPath)"
      ))

    let service = try SourceContract("Argus/Services/WorktreeService.swift")
    service.containsAll(
      [
        "func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws",
        "throw WorktreeError.branchAlreadyExists(baseName)",
      ], "duplicate branch validation")
    try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift").containsAll(
      [
        "case .branchAlreadyExists(let branchName):",
        "errorMessage = \"Branch '\\(branchName)' already exists\"",
      ], "duplicate branch error")
  }

  @Test
  func orphanAdoptionUsesTheExistingWorktree() throws {
    let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
    manager.containsAll(
      [
        "func adoptOrphanedWorktree(",
        "workingDirectory: orphan.path",
        "worktreePath: orphan.path",
        "orphan.branchName ??",
      ], "orphan adoption")
    let sheet = try SourceContract("Argus/Views/Dialogs/OrphanedWorktreesSheet.swift")
    sheet.contains(
      "workspaceManager.adoptOrphanedWorktree(orphan)",
      "orphan sheet must use the dedicated adoption operation"
    )
    let adoption = try sheet.section(
      after: "private func adoptOrphan", before: "private func deleteOrphan")
    #expect(!adoption.contains("addWorkspaceToProject"))
  }

  @Test
  func closingAWorktreeWorkspaceOffersDeletionExplicitly() throws {
    let manager = try SourceContract("Argus/Services/WorkspaceManager.swift")
    manager.containsAll(
      [
        "shouldConfirmWorktreeDeletionBeforeClosing(_ workspaceId: UUID) -> Bool",
        "workspace.worktreePath != nil",
        "!project.isCatchAll",
        "func removeWorkspace(_ workspaceId: UUID, deletingWorktree: Bool) async -> Bool",
        "try await worktreeService.removeWorktree",
        "shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)",
      ], "worktree close behavior")
    try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
      [
        "static let showCloseWorkspaceConfirmation",
        "workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)",
        "name: .showCloseWorkspaceConfirmation",
      ], "sidebar close confirmation")
    try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
      "workspaceManager.shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)",
      "last-tab close confirmation"
    )
    try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
      [
        ".alert(\"Close Workspace?\", isPresented: $showCloseWorkspaceConfirmation)",
        "Button(\"Close Only\")",
        "Button(\"Delete Worktree and Close\", role: .destructive)",
      ], "worktree close choices")
  }
}
