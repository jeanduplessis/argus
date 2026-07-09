import Testing

@testable import Argus

@Suite
struct BrowserPanelUIContractTests {
  @Test
  func browserStaysInWorkspaceTabsAndUsesPublicWebKitAPIs() throws {
    try SourceContract("Argus/Models/BrowserPanel.swift").containsAll(
      [
        "final class BrowserPanel", "let panelType: PanelType = .browser",
        "let webView: BrowserWKWebView", "webView.isInspectable = developerToolsEnabled",
        "webView.find(trimmedQuery, configuration: configuration)",
        "func unfocus()", "webView.allowsApplicationFocus = false",
        "func setWebContentActive(_ isActive: Bool)",
      ], "browser model lifecycle and public WebKit APIs")
    try SourceContract("Argus/Models/BrowserPanel.swift").excludes(
      "developerExtrasEnabled",
      "browser must not use private developer-tools SPI"
    )

    try SourceContract("Argus/Models/Workspace.swift").containsAll(
      [
        "func addBrowserPanel(url: URL? = nil)",
        "panelOrder.insert(panel.id, at: activeIndex + 1)",
        "selectPanel(panel.id)",
      ], "Browser Panel top-level tab lifecycle")
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
      "BrowserView(panel: browserPanel, isActive: isActive)",
      "Browser Panel must render in center workspace content"
    )
    try SourceContract("Argus/Views/Content/ContentAreaView.swift").contains(
      "if panel.panelType == .terminal",
      "pane tap focus must not override Browser Panel controls"
    )
  }

  @Test
  func browserChromeFindAndMenusStayWired() throws {
    let browserView = try SourceContract("Argus/Browser/BrowserView.swift")
    browserView.containsAll(
      [
        ".frame(height: 30)", "Enter website address", "Secure HTTPS connection",
        ".disabled(!enabled)", ".cursor(enabled ? .pointingHand : .arrow)",
        ".help(help)", ".accessibilityLabel(help)", ".onExitCommand",
        "Previous match", "Next match", "matchCountText",
      ], "compact accessible browser chrome and find overlay")

    try SourceContract("Argus/Views/Content/TabBarView.swift").containsAll(
      [
        "Menu {", "Button(\"New Browser Tab\")", "workspace.addBrowserPanel()",
        "if panel.isLoading", "ProgressView()", "else if let icon = panel.displayIcon",
      ], "tab add menu and loading-indicator precedence")
    try SourceContract("Argus/App/ArgusApp.swift").containsAll(
      [
        "Button(\"New Browser Tab\")", "workspaceManager.addBrowserTab()",
        "workspaceManager.requestFindInActiveBrowser()",
        ".keyboardShortcut(\"f\", modifiers: [.command])",
      ], "app menu Browser Panel and find commands")
  }
}
