import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct BrowserPanelTests {
  @Test
  func schemeLessAddressesDefaultToHTTPS() throws {
    #expect(BrowserPanel.resolvedURL(from: "example.com/path")?.absoluteString == "https://example.com/path")
    #expect(BrowserPanel.resolvedURL(from: "localhost:8080")?.absoluteString == "https://localhost:8080")
    #expect(BrowserPanel.resolvedURL(from: "http://example.com")?.absoluteString == "http://example.com")
    #expect(BrowserPanel.resolvedURL(from: "  ") == nil)
  }

  @Test
  func browserSettingsMapToPublicWebKitProperties() {
    let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let panel = BrowserPanel(
      id: id,
      pageZoom: 1.25,
      developerToolsEnabled: true
    )

    #expect(panel.id == id)
    #expect(panel.webView.pageZoom == 1.25)
    #expect(panel.webView.isInspectable)

    panel.pageZoom = 1.5
    panel.developerToolsEnabled = false
    #expect(panel.webView.pageZoom == 1.5)
    #expect(!panel.webView.isInspectable)
  }

  @Test
  func browserUsesNormalTopLevelTabLifecycle() throws {
    let workspace = Workspace(workingDirectory: "/tmp")
    let firstTab = try #require(workspace.panelOrder.first)
    workspace.addTerminalPanel(workingDirectory: "/tmp/second")
    workspace.selectPanel(firstTab)

    let browser = workspace.addBrowserPanel(url: URL(string: "https://example.com"))
    #expect(workspace.panelOrder[1] == browser.id)
    #expect(workspace.activeTabId == browser.id)

    workspace.closeTab(browser.id)
    #expect(workspace.panels[browser.id] == nil)
    #expect(!workspace.panelOrder.contains(browser.id))
  }
}
