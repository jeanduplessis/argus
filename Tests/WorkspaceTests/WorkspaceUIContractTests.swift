import AppKit
import Testing

@testable import Argus

@Suite
struct WorkspaceUIContractTests {
  @Test
  func singleWindowAndWorkspaceReorderingStayWired() throws {
    let app = try SourceContract("Argus/App/ArgusApp.swift")
    app.contains("Window(\"Argus\", id: \"main\")", "Argus must expose one main window")
    app.excludes("WindowGroup", "v1 must not expose multiple main windows")

    try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
      [
        "GeometryReader", "SidebarLayout.leftMaxWidth",
      ], "main window layout")
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
      "TitlebarView()",
      "content column must mount the custom titlebar"
    )
    try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
      [
        "PanelTabDropDelegate", ".onDrag", ".onDrop",
      ], "tab drag and drop")
    try SourceContract("Argus/Models/Workspace.swift").contains(
      "destination <= panelOrder.count",
      "panel reorder must accept the end insertion index"
    )
    try SourceContract("Argus/Views/Sidebar/SidebarView.swift").containsAll(
      [
        "SidebarWorkspaceDropDelegate", ".onDrop",
      ], "workspace drag and drop")
    try SourceContract("Argus/Services/WorkspaceManager.swift").containsAll(
      [
        "reorderWorkspace(in projectId: UUID", "project.moveWorkspace",
      ], "project-scoped workspace reorder")
  }

  @Test
  func newTerminalSelectionUsesTheNormalFocusLifecycle() throws {
    let workspace = try SourceContract("Argus/Models/Workspace.swift")
    let addTerminal = try workspace.section(
      after: "func addTerminalPanel(workingDirectory: String? = nil) -> TerminalPanel",
      before: "/// Opens a workspace file"
    )

    #expect(addTerminal.contains("selectPanel(panel.id)"))
    #expect(addTerminal.contains("panelOrder.append(panel.id)"))
    #expect(!addTerminal.contains("panelOrder.insert"))
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
      ".id(terminalPanel.surface.id)",
      "terminal content must be keyed by surface id"
    )
  }

  @Test
  func terminalClipboardKeepsPlainTextSeparateFromHTML() {
    let pasteboard = NSPasteboard(name: .init("ArgusTests.TerminalClipboard"))
    let plainText = "selected terminal text"
    let html = "<pre><span>selected terminal text</span></pre>"

    writeTerminalClipboard(
      [
        (mimeType: "text/plain", text: plainText),
        (mimeType: "text/html", text: html),
      ],
      to: pasteboard
    )

    #expect(pasteboard.string(forType: .string) == plainText)
    #expect(pasteboard.string(forType: .html) == html)
  }

  @Test
  func newTabUsesCommandT() throws {
    let app = try SourceContract("Argus/App/ArgusApp.swift")
    let newTab = try app.section(
      after: "Button(\"New Tab\")",
      before: "Button(\"Split Vertically\")"
    )

    #expect(newTab.contains("workspaceManager.addTab()"))
    #expect(newTab.contains(".keyboardShortcut(\"t\", modifiers: [.command])"))
    #expect(!newTab.contains(".keyboardShortcut(\"n\", modifiers: [.command])"))
  }

  @Test
  func splitPaneCommandsAndRenderingStayConnected() throws {
    let workspace = try SourceContract("Argus/Models/Workspace.swift")
    workspace.containsAll(
      [
        "enum PanelSplitDirection", "case vertical", "case horizontal",
        "indirect enum PanelLayoutNode", "case split(direction:",
        "func splitActiveTerminal(direction: PanelSplitDirection)",
        "func closeActivePaneOrTab()",
      ], "workspace split-pane model")
    let splitBody = try workspace.section(
      after: "func splitActiveTerminal(direction: PanelSplitDirection)",
      before: "\n    ///"
    )
    #expect(!splitBody.contains("panelOrder.insert"))
    #expect(!splitBody.contains("panelOrder.append"))

    try SourceContract("Argus/Services/WorkspaceManager.swift").contains(
      "func splitActiveTerminal(direction: PanelSplitDirection)",
      "workspace manager must expose split commands"
    )
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
      ["PanelSplitLayoutView", "workspace.activeTabLayout"],
      "content area must render the active split tree"
    )
    try SourceContract("Argus/Views/Content/TabBarView.swift").contains(
      "isActive: panelId == workspace.activeTabId",
      "tab selection must remain scoped to top-level tabs"
    )
    try SourceContract("Argus/App/ArgusApp.swift").containsAll(
      [
        "Button(\"Split Vertically\")",
        ".keyboardShortcut(\"d\", modifiers: [.command])",
        "Button(\"Split Horizontally\")",
        ".keyboardShortcut(\"d\", modifiers: [.command, .shift])",
        "terminalSurfaceDidBecomeFirstResponder",
      ], "split shortcuts and focus notification")
    try SourceContract("Argus/Ghostty/TerminalNSView.swift").containsAll(
      [
        "NotificationCenter.default.post(",
        "name: .terminalSurfaceDidBecomeFirstResponder",
      ], "terminal focus must notify the workspace manager")
  }

  @Test
  func terminalTabsUseOrdinalTitlesAndSupportRenaming() throws {
    let workspace = try SourceContract("Argus/Models/Workspace.swift")
    workspace.contains("func tabDisplayTitle(for panelId: UUID) -> String", "ordinal title API")
    let formatter = try workspace.section(
      after: "func tabDisplayTitle(for panelId: UUID) -> String",
      before: "\n    ///"
    )
    #expect(formatter.contains(#""Terminal \(index + 1)""#))
    #expect(formatter.contains("terminalCustomTitles[panelId]"))

    let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
    tabBar.containsAll(
      [
        "workspace.tabDisplayTitle(for: panelId)",
        "let title: String",
        "Text(title)",
        ".contextMenu {",
        "Button(\"Close\", role: .destructive, action: onClose)",
        "Button(\"Rename\", action: onRename)",
        "workspace.renameTerminalPanel(renamePanelId, title: renameText)",
      ], "tab bar must render and rename explicit terminal titles")
    tabBar.excludes(
      "Text(panel.displayTitle)",
      "tab items must not use terminal path or process titles"
    )
  }

  @Test
  func customWindowChromeRemainsAuthoritative() throws {
    let delegate = try SourceContract("Argus/App/AppDelegate.swift")
    delegate.containsAll(
      [
        "window.titleVisibility = .hidden",
        "window.titlebarAppearsTransparent = true",
        "window.styleMask.insert(.fullSizeContentView)",
        "targetWindow?.title = workspaceManager?.activeWorkspaceTitle",
      ], "custom window chrome")
    delegate.excludes("window.titleVisibility = .visible", "native title must remain hidden")
    try SourceContract("Argus/App/ArgusApp.swift").contains(
      ".windowStyle(.hiddenTitleBar)",
      "scene must use the custom titlebar"
    )

    let titlebar = try SourceContract("Argus/Views/Titlebar/TitlebarView.swift")
    titlebar.containsAll(
      [
        "workspaceManager.selectedWorkspace",
        "workspaceManager.project(for: workspace.id)",
        "workspace.workspaceType.icon",
        "project.displayName",
        "workspace.displayTitle",
        "gitContext.visibleText",
        "Text(\"/\")",
      ], "custom titlebar breadcrumb")
  }

  @Test
  func newWorkspacePresentationCarriesAProjectRequest() throws {
    let window = try SourceContract("Argus/Views/MainWindowView.swift")
    window.containsAll(
      [
        "private struct NewWorkspaceSheetRequest: Identifiable",
        "@State private var newWorkspaceSheetRequest: NewWorkspaceSheetRequest?",
        ".sheet(item: $newWorkspaceSheetRequest) { request in",
        "NewWorkspaceSheet(projectId: request.projectId)",
      ], "new workspace sheet request")
    window.excludes("showNewWorkspaceSheet = true", "presentation must not race optional content")
    window.excludes(
      ".sheet(isPresented: $showNewWorkspaceSheet)",
      "presentation must use an identifiable request"
    )
  }
}
