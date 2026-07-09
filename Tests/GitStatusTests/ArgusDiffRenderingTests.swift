import Foundation
import Testing
import WebKit

@testable import Argus

@Suite
struct ArgusDiffRenderingTests {
  @Test
  func inputEncodesExpectedJSONShape() throws {
    let input = sampleInput()
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
    let oldFile = try #require(object["oldFile"] as? [String: Any])
    let options = try #require(object["options"] as? [String: Any])

    #expect(oldFile["name"] as? String == "file.swift")
    #expect(oldFile["contents"] as? String == "old\n")
    #expect(oldFile["language"] as? String == "swift")
    #expect(options["theme"] as? String == "dark")
    #expect(options["style"] as? String == "split")
    #expect(options["overflow"] as? String == "scroll")
  }

  @Test
  func htmlLoadsLocalBundleAndNamesBridge() {
    #expect(ArgusDiffHTMLTemplate.html.contains("pierre-diffs-bundle.js"))
    #expect(ArgusDiffHTMLTemplate.html.contains("argusDiffBridge"))
    #expect(ArgusDiffHTMLTemplate.html.contains("prefers-color-scheme"))
  }

  @MainActor
  @Test
  func coordinatorQueuesRenderUntilBridgeIsReady() {
    var scripts: [String] = []
    let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { scripts.append($0) })

    coordinator.update(input: sampleInput())
    #expect(scripts.isEmpty)

    coordinator.bridgeDidBecomeReady()
    #expect(scripts.count == 1)
    #expect(scripts[0].contains("window.argusDiff.render"))
  }

  @MainActor
  @Test
  func coordinatorUpdatesOptionsWithoutRecreatingRender() {
    var scripts: [String] = []
    let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { scripts.append($0) })
    coordinator.update(input: sampleInput())
    coordinator.bridgeDidBecomeReady()
    scripts.removeAll()

    let updated = ArgusDiffInput(
      oldFile: sampleInput().oldFile,
      newFile: sampleInput().newFile,
      options: ArgusDiffOptions(theme: .light, style: .unified, overflow: .wrap))
    coordinator.update(input: updated)

    #expect(scripts.count == 3)
    #expect(scripts.contains(where: { $0.contains("setTheme") }))
    #expect(scripts.contains(where: { $0.contains("setStyle") }))
    #expect(scripts.contains(where: { $0.contains("setOverflow") }))
    #expect(!scripts.contains(where: { $0.contains("argusDiff.render") }))
  }

  @MainActor
  @Test
  func dismantleStopsLoadingAndResetsCoordinator() {
    let coordinator = ArgusDiffWebViewCoordinator(evaluateJavaScript: { _ in })
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: ArgusDiffHTMLTemplate.bridgeHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = contentController
    let webView = WKWebView(frame: .zero, configuration: configuration)
    coordinator.bridgeDidBecomeReady()

    coordinator.dismantle(webView: webView)

    #expect(!coordinator.isReady)
  }

  @Test
  func generatedBundleIsCopiedIntoHostApp() throws {
    let url = try #require(Bundle.main.url(
      forResource: ArgusDiffHTMLTemplate.bundleResourceName,
      withExtension: "js"))
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @MainActor
  @Test
  func bundledBridgeRendersDiffInWebView() async throws {
    var rendererError: String?
    let coordinator = ArgusDiffWebViewCoordinator()
    coordinator.onError = { rendererError = $0 }
    let contentController = WKUserContentController()
    contentController.add(coordinator, name: ArgusDiffHTMLTemplate.bridgeHandlerName)
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = contentController
    configuration.websiteDataStore = .nonPersistent()
    let webView = WKWebView(frame: .zero, configuration: configuration)
    coordinator.attach(to: webView)
    coordinator.update(input: sampleInput())
    webView.loadHTMLString(ArgusDiffHTMLTemplate.html, baseURL: Bundle.main.resourceURL)

    for _ in 0..<100 where !coordinator.isReady {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(coordinator.isReady)

    var childCount = 0
    for _ in 0..<100 where childCount == 0 && rendererError == nil {
      try await Task.sleep(for: .milliseconds(20))
      childCount = try #require(
        try await webView.evaluateJavaScript(
          "document.getElementById('diff').childElementCount") as? Int)
    }

    #expect(rendererError == nil)
    #expect(childCount > 0)
    coordinator.dismantle(webView: webView)
  }

  private func sampleInput() -> ArgusDiffInput {
    ArgusDiffInput(
      oldFile: ArgusDiffFile(name: "file.swift", contents: "old\n", language: "swift"),
      newFile: ArgusDiffFile(name: "file.swift", contents: "new\n", language: "swift"),
      options: ArgusDiffOptions(theme: .dark, style: .split, overflow: .scroll))
  }
}
