import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewPanelTests {
  @MainActor
  @Test
  func coveredBehaviors() {
    modelsPreviewTabTitleAndIcon()
    rendersANSIColorsWithoutEscapeCodes()
    resetsANSIColorAfterSGRReset()
    selectsRendererForPreviewContent()
  }

  @MainActor
  private func modelsPreviewTabTitleAndIcon() {
    let panel = GitPreviewPanel(
      rootPath: "/tmp/repo",
      preview: GitPreview(
        kind: .diff,
        path: "Sources/App.swift",
        content: .ansiText("diff")))

    assertEqual(panel.panelType, .gitPreview, "preview uses generic workspace tab model")
    assertEqual(panel.displayTitle, "Diff: App.swift", "diff tab uses compact file title")
    assertEqual(panel.displayIcon, "doc.text.magnifyingglass", "diff tab uses preview icon")

    panel.update(preview: GitPreview(
      kind: .blame,
      path: "Sources/App.swift",
      content: .ansiText("blame")))
    assertEqual(panel.displayTitle, "Blame: App.swift", "updated blame preview refreshes tab title")
  }

  private func rendersANSIColorsWithoutEscapeCodes() {
    let rendered = GitPreviewANSITextRenderer.attributedString(
      for: "\u{001B}[31m-red\u{001B}[0m plain")

    assertEqual(
      rendered.string, "-red plain", "ANSI escape codes are stripped from rendered preview text")
    assertColor(rendered, at: 0, equals: .systemRed, "SGR red maps to visible foreground color")
  }

  private func resetsANSIColorAfterSGRReset() {
    let rendered = GitPreviewANSITextRenderer.attributedString(
      for: "\u{001B}[32m+green\u{001B}[0m plain")

    assertEqual(rendered.string, "+green plain", "reset keeps only visible preview text")
    assertColor(rendered, at: 0, equals: .systemGreen, "SGR green maps to visible foreground color")
    assertColor(rendered, at: 7, equals: .textColor, "SGR reset restores default foreground color")
  }

  private func selectsRendererForPreviewContent() {
    let diff = GitPreviewContent.diff(GitDiffPreview(
      fileName: "file.txt", oldContent: "old", newContent: "new"))
    assertEqual(
      GitPreviewPanelContentKind(content: diff), .diff,
      "structured diff content selects Pierre renderer")
    assertEqual(
      GitPreviewPanelContentKind(content: .ansiText("blame")), .ansiText,
      "blame and failure text select ANSI renderer")
  }

  private func assertColor(
    _ text: NSAttributedString, at index: Int, equals expected: NSColor, _ message: String
  ) {
    let actual = text.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    #expect(actual?.isEqual(expected) == true, Comment(rawValue: message))
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}
