import Testing

@testable import Argus

@Suite
struct GitStatusUIContractTests {
  @Test
  func fileTreeGroupsAndCompactsDirectoryPaths() throws {
    let files = [
      GitFileChange(
        path: "Argus/Services/GitStatusService.swift",
        status: .modified,
        sectionKey: "unstaged"),
      GitFileChange(
        path: "Argus/Views/GitSidebar/GitSidebarView.swift",
        status: .modified,
        sectionKey: "unstaged"),
      GitFileChange(
        path: "Argus/Views/GitSidebar/GitStatusViewModel.swift",
        status: .modified,
        sectionKey: "unstaged"),
      GitFileChange(
        path: "Tests/GitStatusTests/GitStatusViewModelTests.swift",
        status: .modified,
        sectionKey: "unstaged"),
    ]

    let nodes = GitFileTree.makeNodes(files: files)

    #expect(nodes.map(\.name) == ["Argus", "Tests / GitStatusTests"])
    #expect(nodes[0].children.map(\.name) == ["Services", "Views / GitSidebar"])
    #expect(nodes[0].children[0].children.map(\.name) == ["GitStatusService.swift"])
    #expect(nodes[0].children[1].children.map(\.name) == [
      "GitSidebarView.swift", "GitStatusViewModel.swift",
    ])
    #expect(nodes[1].children.first?.file?.path ==
      "Tests/GitStatusTests/GitStatusViewModelTests.swift")
  }

  @Test
  func collapsedDirectoryHidesOnlyItsDescendants() throws {
    let files = [
      GitFileChange(
        path: "Argus/Services/GitStatusService.swift",
        status: .modified,
        sectionKey: "unstaged"),
      GitFileChange(
        path: "README.md",
        status: .modified,
        sectionKey: "unstaged"),
    ]
    let nodes = GitFileTree.makeNodes(files: files)
    let argusId = try #require(nodes.first(where: { $0.name == "Argus / Services" })?.id)

    let rows = GitFileTree.visibleRows(
      nodes: nodes,
      collapsedDirectoryIds: [argusId])

    #expect(rows.map(\.name) == ["Argus / Services", "README.md"])
  }

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
  func branchBarShowsChangeTotalsAndTogglesAllSections() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    let branchBar = try view.section(
      after: "private func branchBar(",
      before: "private func upstreamText")

    for expected in [
      "summary.totalFileCount", "totalDiffStats(summary)",
      "totals.additions", "totals.deletions",
      "setAllSectionsExpanded(allCollapsed, summary: summary)",
      "Collapse All", "Expand All",
      ".cursor(.pointingHand)",
    ] {
      #expect(branchBar.contains(expected))
    }
  }

  @Test
  func fileRowHoverKeepsLayoutAndHitAreaStable() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    let fileRow = try view.section(
      after: "private func fileRow(",
      before: "private func treeRowLeadingPadding")

    #expect(fileRow.contains("ZStack(alignment: .trailing)"))
    #expect(fileRow.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    #expect(fileRow.contains(".contentShape(Rectangle())"))
    #expect(fileRow.contains(".allowsHitTesting(hoveredFileId == file.id)"))
    #expect(fileRow.contains("hoveredFileActionId == actionHoverId"))
    #expect(fileRow.contains(".cursor(.pointingHand)"))
  }

  @Test
  func sectionBulkActionsShowHoverFeedbackAndPointerCursor() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    let fileSection = try view.section(
      after: "private func fileSection(",
      before: "private func directoryRow")

    #expect(fileSection.contains("hoveredSectionActionId == actionHoverId"))
    #expect(fileSection.contains("RoundedRectangle(cornerRadius: 4"))
    #expect(fileSection.contains("Color.primary.opacity(0.1)"))
    #expect(fileSection.contains(".onHover { isHovering in"))
    #expect(fileSection.contains(".cursor(.pointingHand)"))
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
