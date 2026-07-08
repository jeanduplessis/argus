import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewPanelTests {
  @MainActor
  @Test
  func coveredBehaviors() {
    clampsPreviewPanelToVisibleScreen()
    dismissesPreviewPanelThroughController()
    rendersANSIColorsWithoutEscapeCodes()
    resetsANSIColorAfterSGRReset()
  }

  private func clampsPreviewPanelToVisibleScreen() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let parentFrame = NSRect(x: 700, y: 500, width: 240, height: 160)
    let panelSize = NSSize(width: 360, height: 320)

    let frame = GitPreviewPanelLayout.frame(
      adjacentTo: parentFrame,
      panelSize: panelSize,
      visibleFrame: visibleFrame
    )

    assertEqual(frame.size, panelSize, "layout preserves requested panel size")
    assertEqual(frame.maxX <= visibleFrame.maxX, true, "layout clamps right edge")
    assertEqual(frame.maxY <= visibleFrame.maxY, true, "layout clamps top edge")
    assertEqual(frame.minX >= visibleFrame.minX, true, "layout keeps left edge visible")
    assertEqual(frame.minY >= visibleFrame.minY, true, "layout keeps bottom edge visible")
  }

  @MainActor
  private func dismissesPreviewPanelThroughController() {
    let panel = RecordingPreviewPanel()
    let controller = GitPreviewPanelController(panel: panel)

    controller.dismiss()

    assertEqual(panel.closeCount, 1, "dismiss closes the preview panel")
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

private final class RecordingPreviewPanel: GitPreviewPanelClosing {
  private(set) var closeCount = 0

  func close() {
    closeCount += 1
  }
}
