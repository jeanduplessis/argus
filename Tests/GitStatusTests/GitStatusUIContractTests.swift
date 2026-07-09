import Foundation
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
  func workspaceFileTreeShowsDirectoriesAndFiles() throws {
    let entries = [
      WorkspaceFileTreeEntry(path: "Sources/App.swift", isDirectory: false),
      WorkspaceFileTreeEntry(path: "Sources/Views", isDirectory: true),
      WorkspaceFileTreeEntry(path: "Sources/Views/MainView.swift", isDirectory: false),
      WorkspaceFileTreeEntry(path: "Empty", isDirectory: true),
      WorkspaceFileTreeEntry(path: "README.md", isDirectory: false),
    ]

    let nodes = WorkspaceFileTree.makeNodes(entries: entries)

    #expect(nodes.map(\.name) == ["Empty", "Sources", "README.md"])
    #expect(nodes[1].children.map(\.name) == ["Views", "App.swift"])
    #expect(nodes[1].children[0].children.map(\.name) == ["MainView.swift"])

    let rows = WorkspaceFileTree.visibleRows(
      nodes: nodes,
      expandedDirectoryIds: [])

    #expect(rows.map(\.name) == ["Empty", "Sources", "README.md"])
  }

  @Test
  func workspaceFileProviderLoadsRootEntriesBeforeChildren() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-files-panel-\(UUID().uuidString)", isDirectory: true)
    let sources = root.appendingPathComponent("Sources", isDirectory: true)
    let nested = sources.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "readme\n".write(
      to: root.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8)
    try "app\n".write(
      to: sources.appendingPathComponent("App.swift"),
      atomically: true,
      encoding: .utf8)
    try "nested\n".write(
      to: nested.appendingPathComponent("Nested.swift"),
      atomically: true,
      encoding: .utf8)

    let provider = FileManagerWorkspaceFileTreeProvider()
    let rootState = await provider.loadTree(rootPath: root.path)
    guard case .loaded(let rootSnapshot) = rootState else {
      Issue.record("expected root file tree, got \(rootState)")
      return
    }

    #expect(rootSnapshot.nodes.map(\.name) == ["Sources", "README.md"])
    #expect(rootSnapshot.nodes.first(where: { $0.name == "Sources" })?.children.isEmpty == true)

    let sourceState = await provider.loadChildren(
      rootPath: rootSnapshot.rootPath,
      directoryPath: "Sources")
    guard case .loaded(let sourceSnapshot) = sourceState else {
      Issue.record("expected source child file tree, got \(sourceState)")
      return
    }

    #expect(sourceSnapshot.nodes.map(\.name) == ["Nested", "App.swift"])
    #expect(sourceSnapshot.nodes.first(where: { $0.name == "Nested" })?.children.isEmpty == true)
  }

  @Test
  func workspaceFileRequestsIncludeWorkspaceIdentityAndNormalizedRoot() {
    let firstWorkspaceId = UUID()
    let secondWorkspaceId = UUID()
    let first = WorkspaceFileTreeRequest(
      workspaceId: firstWorkspaceId,
      rootPath: "/tmp/argus/../workspace")
    let sameWorkspaceAndRoot = WorkspaceFileTreeRequest(
      workspaceId: firstWorkspaceId,
      rootPath: "/tmp/workspace")
    let differentWorkspace = WorkspaceFileTreeRequest(
      workspaceId: secondWorkspaceId,
      rootPath: "/tmp/workspace")

    #expect(first == sameWorkspaceAndRoot)
    #expect(first != differentWorkspace)
    #expect(first.rootPath == "/tmp/workspace")
  }

  @Test
  func rightSidebarHostsFilesAndChangesPanels() throws {
    let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
    rightView.containsAll(
      [
        "struct RightSidebarView: View",
        "case files", "case changes",
        "return \"Files\"", "return \"Changes\"",
        "WorkspaceFilesView(",
        "workspaceId: workspaceManager.selectedWorkspace?.id",
        "rootPath: workspaceManager.selectedWorkspace?.currentDirectory",
        "WorkspaceFileTreeRequest(",
        "GitSidebarView(showsHeader: false)",
        "private var changesCount: Int?",
        "summary.totalFileCount",
        "Refresh files", "Refresh changes",
      ], "right sidebar panel tabs")
    rightView.excludes("Text(\"Git Status\")", "git status panel is renamed to changes")

    let changesView = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    changesView.contains("Text(\"Changes\")", "git status header is renamed to changes")
    changesView.excludes("Text(\"Git Status\")", "git status header no longer uses old title")

    try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
      [
        "RightSidebarView()",
        "right side panel",
      ], "right sidebar host")
  }

  @Test
  func filesPanelReadsWorkspaceDirectoryWithBoundedTraversal() throws {
    try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift").containsAll(
      [
        "FileManagerWorkspaceFileTreeProvider",
        "loadChildren(rootPath: String, directoryPath: String)",
        "WorkspaceFileTreeSnapshot.displayedEntryLimit",
        "contentsOfDirectory",
        ".skipsPackageDescendants",
        "name == \".git\"",
        ".id(request)",
        "snapshot.request == request",
        "expandedDirectoryIds",
        "WorkspaceFileTree.visibleRows(",
      ], "files panel traversal")
  }

  @Test
  func filesPanelRowsSupportSelectionOpenAndContextActions() throws {
    let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
    rightView.containsAll(
      [
        "@State private var selectedItemId: String?",
        "private func workspaceDirectoryRow(",
        "let isSelected = selectedItemId == directory.id",
        "@State private var hoveredItemId: String?",
        "selectDirectory(directory)",
        "toggleWorkspaceDirectory(directory, rootPath: rootPath)",
        "openWorkspaceDirectory(directory, rootPath: rootPath)",
        "copyWorkspaceItem(directory, rootPath: rootPath)",
        "guard let initiatingRequest = request else { return }",
        "initiatingRequest: initiatingRequest",
        "private func workspaceFileRow(",
        "return Button {",
        "selectFile(file)",
        "let isSelected = selectedItemId == file.id",
        "let isHovered = hoveredItemId == file.id",
        "isHovered ? ChromeColors.hoveredTabFill : Color.clear",
        ".simultaneousGesture(TapGesture(count: 2).onEnded {",
        "openWorkspaceFile(file, rootPath: rootPath)",
        ".contextMenu {",
        "Button(\"Open Folder\")",
        "Button(\"Copy Folder\")",
        "Button(\"Delete Folder\", role: .destructive)",
        "Button(\"Rename Folder\")",
        "Button(\"Open File\")",
        "Button(\"Copy File\")",
        "Button(\"Delete File\", role: .destructive)",
        "Button(\"Rename File\")",
        "copyWorkspaceItem(file, rootPath: rootPath)",
        "$0.id == initiatingRequest.workspaceId",
        "sourceWorkspace.openFilePanel(",
      ], "files panel row interactions")
    rightView.containsAll(
      [
        "WorkspaceFileOperating",
        "FileManagerWorkspaceFileOperator",
        "NSPasteboard.general",
        "confirmDelete(path: String)",
        "promptRename(currentName: String)",
        "func deleteFileWithConfirmation(request: WorkspaceFileTreeRequest, path: String)",
        "func renameFileWithPrompt(request: WorkspaceFileTreeRequest, path: String)",
        "activeRequest == request",
        "viewModel.isCurrent(initiatingRequest)",
        "resolvedItemURL(rootPath: String, path: String)",
        "removeItem(at:",
        "moveItem(at:",
      ], "files panel file operations")

    try SourceContract("Argus/Models/Panel.swift").containsAll(
      [
        "case file",
        "final class FilePanel",
        "let panelType: PanelType = .file",
      ], "file panel model")
    try SourceContract("Argus/Models/Workspace.swift").containsAll(
      [
        "func openFilePanel(rootPath: String, relativePath: String) -> FilePanel",
        "selectPanel(existing.id)",
        "func updateOpenFilePanel(rootPath: String, oldPath: String, newPath: String)",
      ], "workspace file tab helpers")
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
      [
        "case .file:",
        "FilePanelContentView(panel: filePanel)",
        "Data(contentsOf: url)",
        "data.contains(0)",
        "FileSyntaxHighlighter.highlightedText",
        "GeometryReader { proxy in",
        "@State private var lineWrapEnabled = true",
        "Text(String(number))",
        "ScrollView([.horizontal, .vertical])",
        ".fixedSize(horizontal: false, vertical: true)",
        ".fixedSize(horizontal: true, vertical: true)",
        "minHeight: viewportSize.height",
        "alignment: .topLeading",
      ], "file tab content rendering")
  }

  @Test
  func fileTabsShowLineNumbersAndWrapSourceByDefault() throws {
    let lines = FileSourceText.lines(
      in: "first\r\n/* second\ncontinued */\n",
      fileName: "Example.swift")

    #expect(lines.map { String($0.characters) } == [
      "first", "/* second", "continued */", "",
    ])
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
      [
        "@State private var lineWrapEnabled = true",
        "private var lineWrapButton: some View",
        "Text(\"Wrap\")",
        ".accessibilityLabel(\"Line wrap\")",
        ".accessibilityValue(lineWrapEnabled ? \"On\" : \"Off\")",
        "Text(String(number))",
        ".accessibilityLabel(\"Line \\(number)\")",
        "Color.primary.opacity(0.025)",
      ], "File Tab source gutter and line wrap control")
  }

  @Test
  func filePanelSyntaxHighlighterStylesRecognizedSourceFiles() throws {
    let swiftTokens = FileSyntaxHighlighter.tokens(
      in: "import SwiftUI\nlet title = \"Argus\" // app name\n",
      fileName: "Sources/App.swift")

    #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "import")))
    #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "let")))
    #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .typeName, text: "SwiftUI")))
    #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
    #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .comment, text: "// app name")))

    let jsonTokens = FileSyntaxHighlighter.tokens(
      in: "{\n  \"name\": \"Argus\",\n  \"enabled\": true\n}",
      fileName: "config.json")

    #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .property, text: "\"name\"")))
    #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
    #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .literal, text: "true")))

    #expect(FileSyntaxHighlighter.tokens(
      in: "let title = \"plain\"",
      fileName: "notes.txt"
    ).isEmpty)
  }

  @Test
  func markdownFileTabsExposeSourceAndRenderedDisplays() throws {
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
      [
        "enum MarkdownDisplayMode", "case source", "case rendered",
        "return \"doc.plaintext\"", "return \"doc.richtext\"",
        "Show Markdown source", "Show rendered Markdown",
        "if isMarkdownFile, markdownDisplayMode == .rendered",
        "MarkdownRenderedView(",
        ".cursor(.pointingHand)",
        ".accessibilityValue(isSelected ? \"Selected\" : \"\")",
      ], "Markdown File Tab display controls")
  }

  @Test
  func markdownRendererPreservesCommonBlockStructure() {
    let blocks = MarkdownRenderer.blocks(
      source: """
        # Heading

        Paragraph with **bold** text.

        - First

        > Quote

        ```swift
        let value = 1
        ```

        | Name | Value |
        | --- | --- |
        | Argus | One |
        """,
      baseURL: URL(fileURLWithPath: "/tmp"))

    guard case .heading(let level, let heading) = blocks[0] else {
      Issue.record("expected heading block")
      return
    }
    #expect(level == 1)
    #expect(String(heading.characters) == "Heading")

    #expect(blocks.contains { block in
      guard case .listItem(let marker, _, let content) = block else { return false }
      return marker == "•" && String(content.characters) == "First"
    })
    #expect(blocks.contains { block in
      guard case .quote(let content) = block else { return false }
      return String(content.characters) == "Quote"
    })
    #expect(blocks.contains { block in
      guard case .code(let language, let content) = block else { return false }
      return language == "swift" && String(content.characters).contains("let value = 1")
    })
    #expect(blocks.contains { block in
      guard case .table(let rows) = block else { return false }
      return rows.count == 2
        && rows[0].isHeader
        && String(rows[1].cells[0].characters) == "Argus"
    })
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
        "return \"Stage File\"", "return \"Unstage File\"",
        "return \"Discard Changes\"", "return \"Delete File\"",
        "return \"View Diff\"", "return \"View Blame\"", "return \"Copy Path\"",
        "perform(action, for: file, owner: owner)",
        "await performFileOperation(action.operation, path: file.path, owner: owner)",
        "viewModel.copyPath(file.path)",
        "case .fileOperationFailed(_, let message):",
        "Image(systemName: file.status.systemImage)",
        ".foregroundColor(file.status.tintColor)",
        ".accessibilityValue(fileAccessibilityValue(file))",
        ".accessibilityActions {",
        ".contextMenu {",
      ], "git file row actions")
  }

  @Test
  func gitFileStatusesExposeDistinctIconsAndAccessibleNames() {
    let expectedStyles: [(GitFileStatus, String, String)] = [
      (.added, "doc.badge.plus", "Added"),
      (.modified, "pencil", "Modified"),
      (.deleted, "trash", "Deleted"),
      (.renamed, "arrow.right", "Renamed"),
      (.copied, "doc.on.doc", "Copied"),
      (.typeChanged, "wrench.and.screwdriver", "Type changed"),
      (.untracked, "questionmark.circle", "Untracked"),
      (.unmerged, "exclamationmark.triangle", "Merge conflict"),
    ]

    for (status, icon, accessibleName) in expectedStyles {
      #expect(status.systemImage == icon)
      #expect(status.displayName == accessibleName)
    }
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
    #expect(fileRow.contains("hoveredFileId == file.id ? ChromeColors.hoveredTabFill : Color.clear"))
    #expect(fileRow.contains("let revealsActions = hoveredFileId == file.id || focusedFileId == file.id"))
    #expect(fileRow.contains(".allowsHitTesting(revealsActions)"))
    #expect(fileRow.contains(".accessibilityHidden(!revealsActions)"))
    #expect(fileRow.contains(".focusable()"))
    #expect(fileRow.contains("hoveredFileActionId == actionHoverId"))
    #expect(fileRow.contains(".cursor(viewModel.canPerformActions(for: owner) ? .pointingHand : .arrow)"))
  }

  @Test
  func directoryRowsShowFileEquivalentHoverFeedback() throws {
    let filesView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
    let filesDirectoryRow = try filesView.section(
      after: "private func workspaceDirectoryRow(",
      before: "private func workspaceFileRow(")
    let changesView = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    let changesDirectoryRow = try changesView.section(
      after: "private func directoryRow(",
      before: "private func fileRow(")

    for expected in [
      ".frame(maxWidth: .infinity, alignment: .leading)",
      "ChromeColors.hoveredTabFill",
      ".onHover { isHovering in",
    ] {
      #expect(filesDirectoryRow.contains(expected))
      #expect(changesDirectoryRow.contains(expected))
    }
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
        "await confirmAndPerformFileOperation(action.operation, paths: [file.path], owner: owner)",
        "sectionActions(title: String, count: Int)",
        "Stage All Files", "Unstage All Files", "Discard All Changes", "Delete All Untracked Files",
        "await confirmAndPerformSectionFileOperation(action.operation, sectionKey: sectionKey, pathCount: count, owner: owner)",
        "role: .destructive",
      ], "destructive and bulk git actions")
    view.excludes("files.map(\\.path)", "bulk actions must not be limited to displayed rows")

    let viewModel = try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel.swift")
    viewModel.containsAll(
      [
        "fileOperationConfirmer.confirm(operation: operation, paths: paths)",
        "fileOperationConfirmer.confirm(operation: operation, pathCount: pathCount)",
        "guard activeMutationRequest == nil, activeRefreshRequests[owner] == nil else { return nil }",
        "activeMutationRequest = (requestId, owner)",
        "isMutationInProgress = true",
        "if activeMutationRequest?.owner == owner",
        "pendingRefreshOwners.insert(owner)",
      ], "exact-path confirmation and serialized Git mutations")
  }

  @Test
  func destructiveConfirmationNamesExactPaths() {
    #expect(
      GitStatusFileOperation.discard.confirmationMessage(paths: ["Sources/App.swift", "README.md"])
        == "This will permanently discard unstaged changes in:\n\n\"Sources/App.swift\"\n\"README.md\"")
    #expect(
      GitStatusFileOperation.delete.confirmationMessage(paths: ["scratch notes.txt"])
        == "This will permanently delete from disk:\n\n\"scratch notes.txt\"")
  }

  @Test
  func diffAndBlameActionsUseThePreviewPipeline() throws {
    let view = try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift")
    view.containsAll(
      [
        "case diff", "case blame",
        "await showPreview(kind: .diff, file: file, owner: owner)",
        "await showPreview(kind: .blame, file: file, owner: owner)",
        "viewModel.loadPreview(kind: kind, file: file, owner: owner)",
        "$0.id == owner.workspaceId",
        "rootPath: owner.rootPath",
      ], "diff and blame actions")
    let untracked = try view.section(after: "case \"untracked\":", before: "default:")
    #expect(untracked.contains(".diff"))
    #expect(!untracked.contains(".blame"))

    try SourceContract("Argus/Models/Panel.swift").containsAll(
      [
        "case gitPreview",
        "final class GitPreviewPanel",
        "let panelType: PanelType = .gitPreview",
      ], "preview tab model")
    try SourceContract("Argus/Models/Workspace.swift").containsAll(
      [
        "func openGitPreviewPanel(rootPath: String, preview: GitPreview)",
        "$0.preview.kind == preview.kind",
        "$0.preview.path == preview.path",
        "existing.update(preview: preview)",
        "selectPanel(existing.id)",
      ], "preview tab insertion and reuse")
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
      [
        "case .gitPreview:",
        "GitPreviewPanelContentView(panel: previewPanel)",
      ], "preview tab content")
    try SourceContract("Argus/Services/GitPreviewService.swift").containsAll(
      [
        "case diff(GitDiffPreview)",
        "cat-file", "workingTreeFile(rootPath:",
      ], "structured diff content extraction")
  }

  @Test
  func nonRepositoryStateOffersInitializationAndRecovery() throws {
    try SourceContract("Argus/Views/GitSidebar/GitSidebarView.swift").containsAll(
      [
        "case .notRepository(let rootPath):",
        "notRepositoryContent(rootPath: rootPath",
        "Text(\"Initialize Git Repository\")",
        "guard let owner = selectedSnapshotOwner, viewModel.ownsSnapshot(owner)",
        "await viewModel.initializeRepository(owner: owner)",
        "case .repositoryInitializationFailed(let rootPath, let message):",
        "notRepositoryContent(rootPath: rootPath, message: message",
        "Text(\"Refresh Changes\")",
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
        "GitStatusSnapshotOwner",
        "viewModel.owner(workspaceId: workspace.id, context: context)",
        "viewModel.activate(owner)",
        "viewModel.ownsSnapshot(owner)",
        "viewModel.refresh(owner: owner)",
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
        "ArgusDiffView.swift in Sources",
        "pierre-diffs-bundle.js in Resources",
        "RightSidebarView.swift in Sources",
      ], "preview sources in app target")
    try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel.swift").containsAll(
      [
        "private let previewService: any GitPreviewProviding",
        "func loadPreview(",
      ], "preview dependencies")
    try SourceContract("Argus/Views/GitSidebar/GitStatusViewModel.swift").excludes(
      "GitPreviewPresenting", "preview loading must not open an AppKit window")
  }
}
