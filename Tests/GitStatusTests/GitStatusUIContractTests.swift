import Testing

@Suite
struct GitStatusUIContractTests {
  @Test
  func fileRowsExposeSectionAppropriateActions() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    view.containsAll(
      [
        "fileActions(for file: GitFileChange)",
        "case \"staged\":", ".unstage",
        "case \"unstaged\":", "case \"untracked\":", ".stage",
        ".copyPath",
        "await performFileOperation(action.operation, path: file.path)",
        "viewModel.copyPath(file.path)",
        "case .fileOperationFailed(_, let message):",
      ], "git file row actions")
  }

  @Test
  func destructiveAndBulkActionsRequireConfirmation() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    view.containsAll(
      [
        "case discard", "case delete",
        "case \"unstaged\":", ".discard",
        "case \"untracked\":", ".delete",
        "await confirmAndPerformFileOperation(action.operation, paths: [file.path])",
        "sectionActions(title: String, count: Int)",
        "Stage All", "Unstage All", "Discard All", "Delete All",
        "await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count)",
      ], "destructive and bulk git actions")
    view.excludes("files.map(\\.path)", "bulk actions must not be limited to displayed rows")
  }

  @Test
  func diffAndBlameActionsUseThePreviewPipeline() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    view.containsAll(
      [
        "case diff", "case blame",
        "await showPreview(kind: .diff, file: file)",
        "await showPreview(kind: .blame, file: file)",
      ], "diff and blame actions")
    let untracked = try view.section(after: "case \"untracked\":", before: "default:")
    #expect(untracked.contains(".diff"))
    #expect(!untracked.contains(".blame"))

    try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
      [
        "EscapeClosingGitPreviewPanel",
        "event.keyCode == 53",
        "Button(\"Close\"",
        ".keyboardShortcut(.cancelAction)",
        "@MainActor\nprotocol GitPreviewPanelClosing",
        "extension NSPanel: GitPreviewPanelClosing",
      ], "preview panel dismissal")
    try SourceContract("Argus/Services/GitPreviewService.swift").containsAll(
      [
        "diff.external=", "--no-ext-diff",
      ], "diff command selection")
  }

  @Test
  func nonRepositoryStateOffersInitializationAndRecovery() throws {
    try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
      [
        "case .notRepository(let rootPath):",
        "notRepositoryContent(rootPath: rootPath",
        "Text(\"Initialize Repository\")",
        "await viewModel.initializeRepository(context: context)",
        "case .repositoryInitializationFailed(let rootPath, let message):",
        "notRepositoryContent(rootPath: rootPath, message: message",
      ], "repository initialization UI")
  }

  @Test
  func titlebarAndSidebarShareWorkspaceScopedStatus() throws {
    try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
      [
        "@StateObject private var gitStatusViewModel = GitStatusViewModel()",
        ".environmentObject(gitStatusViewModel)",
      ], "shared git status ownership")
    try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
      [
        "@EnvironmentObject private var viewModel: GitStatusViewModel",
        "viewModel.refresh(workspaceId: workspace.id, context: context)",
      ], "workspace-scoped sidebar status")
    try SourceContract("Argus/Views/Titlebar/TitlebarView.swift").containsAll(
      [
        "@EnvironmentObject private var gitStatusViewModel: GitStatusViewModel",
        "gitStatusViewModel.titlebarGitContext(for: workspace.id)",
        "gitContext.visibleText",
        ".task(id: workspaceManager.selectedWorkspaceId)",
        "gitStatusViewModel.stateWorkspaceId != workspace.id",
        "gitStatusViewModel.refresh(workspaceId: workspace.id, context: context)",
        "WorkspaceTitleFormatter.title(",
        "gitContext: gitContext?.windowTitleText",
        "NSApp.mainWindow?.title",
      ], "workspace-scoped titlebar status")
  }

  @Test
  func previewDependenciesAreCompiledIntoTheApp() throws {
    let project = try SourceContract("Argus.xcodeproj/project.pbxproj")
    project.containsAll(
      [
        "GitPreviewService.swift in Sources",
        "GitPreviewPanel.swift in Sources",
      ], "preview sources in app target")
    try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel.swift").containsAll(
      [
        "private let previewService: any GitPreviewProviding",
        "private let previewPresenter: any GitPreviewPresenting",
      ], "preview dependencies")
  }
}
