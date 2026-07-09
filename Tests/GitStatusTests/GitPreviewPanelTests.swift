import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewPanelTests {
  @MainActor
  @Test
  func coveredBehaviors() throws {
    modelsPreviewTabTitleAndIcon()
    rendersANSIColorsWithoutEscapeCodes()
    resetsANSIColorAfterSGRReset()
    selectsRendererForPreviewContent()
    try usesGhosttyPaletteForPreviewRendering()
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
    let paletteForeground = NSColor(
      srgbRed: 0.72,
      green: 0.81,
      blue: 0.9,
      alpha: 1)
    let rendered = GitPreviewANSITextRenderer.attributedString(
      for: "\u{001B}[32m+green\u{001B}[0m plain",
      foregroundColor: paletteForeground)

    assertEqual(rendered.string, "+green plain", "reset keeps only visible preview text")
    assertColor(rendered, at: 0, equals: .systemGreen, "SGR green maps to visible foreground color")
    assertColor(
      rendered,
      at: 7,
      equals: paletteForeground,
      "SGR reset restores Ghostty-derived foreground color")
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

  private func usesGhosttyPaletteForPreviewRendering() throws {
    let darkPalette = ChromePalette(
      background: NSColor(srgbRed: 0.05, green: 0.06, blue: 0.07, alpha: 1),
      foreground: NSColor(srgbRed: 0.9, green: 0.91, blue: 0.92, alpha: 1),
      revision: 4)
    let lightPalette = ChromePalette(
      background: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1),
      foreground: NSColor(srgbRed: 0.1, green: 0.11, blue: 0.12, alpha: 1),
      revision: 5)

    #expect(darkPalette.isDark)
    #expect(!lightPalette.isDark)
    #expect(darkPalette.revision == 4)

    try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
      [
        "@ObservedObject private var ghosttyApp = GhosttyApp.shared",
        "foregroundColor: ghosttyApp.chromePalette.foreground",
        "theme: ghosttyApp.chromePalette.isDark ? .dark : .light",
        ".id(ghosttyApp.chromePalette.revision)",
        "foregroundColor: NSColor = ChromeColors.foregroundNSColor",
      ], "Git Preview palette and renderer refresh")
    try SourceContract("Argus/DiffRendering/ArgusDiffHTMLTemplate.swift").containsAll(
      [
        "--argus-background: \\(ChromeColors.backgroundCSS)",
        "--argus-foreground: \\(ChromeColors.foregroundCSS)",
        "color: var(--argus-foreground)",
        "background: var(--argus-background)",
      ], "diff renderer inherits Ghostty-derived chrome colors")
    try SourceContract("Argus/Ghostty/GhosttyApp.swift").containsAll(
      [
        "extractChromePalette(from: cfg)",
        "configColor(named: \"background\", from: config)",
        "configColor(named: \"foreground\", from: config)",
        "revision: chromePalette.revision &+ 1",
        "extractChromePalette(from: newConfig)",
      ], "Ghostty configuration owns preview palette updates")
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
