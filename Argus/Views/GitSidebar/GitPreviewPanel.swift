import AppKit
import SwiftUI

@MainActor
protocol GitPreviewPanelClosing: AnyObject {
    func close()
}

extension NSPanel: GitPreviewPanelClosing {}

protocol GitPreviewPresenting: AnyObject {
    @MainActor
    func show(preview: GitPreview, parentWindow: NSWindow?)

    @MainActor
    func showFailure(kind: GitPreviewKind, path: String, message: String, parentWindow: NSWindow?)
}

@MainActor
final class GitPreviewPanelController {
    private weak var panel: (any GitPreviewPanelClosing)?

    init(panel: any GitPreviewPanelClosing) {
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
    }
}

final class AppKitGitPreviewPresenter: GitPreviewPresenting {
    private var controller: GitPreviewPanelController?

    @MainActor
    func show(preview: GitPreview, parentWindow: NSWindow?) {
        present(title: title(for: preview.kind, path: preview.path), output: preview.output, parentWindow: parentWindow)
    }

    @MainActor
    func showFailure(kind: GitPreviewKind, path: String, message: String, parentWindow: NSWindow?) {
        present(title: title(for: kind, path: path), output: message, parentWindow: parentWindow)
    }

    @MainActor
    private func present(title: String, output: String, parentWindow: NSWindow?) {
        let panelSize = NSSize(width: 720, height: 520)
        let visibleFrame = parentWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let parentFrame = parentWindow?.frame ?? visibleFrame
        let panel = EscapeClosingGitPreviewPanel(
            contentRect: GitPreviewPanelLayout.frame(adjacentTo: parentFrame, panelSize: panelSize, visibleFrame: visibleFrame),
            styleMask: [.titled, .utilityWindow, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let controller = GitPreviewPanelController(panel: panel)
        panel.title = title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: GitPreviewPanelContent(title: title, output: output) {
            controller.dismiss()
        })
        self.controller = controller
        parentWindow?.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
    }

    private func title(for kind: GitPreviewKind, path: String) -> String {
        switch kind {
        case .diff:
            return "Diff: \(path)"
        case .blame:
            return "Blame: \(path)"
        }
    }
}

final class EscapeClosingGitPreviewPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct GitPreviewPanelContent: View {
    let title: String
    let output: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            Divider()

            GitPreviewANSITextView(output: output)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct GitPreviewANSITextRenderer {
    static func attributedString(for output: String) -> NSAttributedString {
        let text = output.isEmpty ? "No output" : output
        let result = NSMutableAttributedString()
        var index = text.startIndex
        var attributes = defaultAttributes()

        while index < text.endIndex {
            if let sequence = sgrSequence(in: text, at: index) {
                apply(sequence.codes, to: &attributes)
                index = sequence.endIndex
                continue
            }

            result.append(NSAttributedString(
                string: String(text[index]),
                attributes: attributes
            ))
            index = text.index(after: index)
        }

        return result
    }

    private static func sgrSequence(in text: String, at index: String.Index) -> (codes: [Int], endIndex: String.Index)? {
        guard text[index] == "\u{001B}" else { return nil }
        let bracketIndex = text.index(after: index)
        guard bracketIndex < text.endIndex, text[bracketIndex] == "[" else { return nil }

        var cursor = text.index(after: bracketIndex)
        var parameterText = ""
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "m" {
                let endIndex = text.index(after: cursor)
                let codes = parameterText.isEmpty
                    ? [0]
                    : parameterText.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                return (codes, endIndex)
            }
            guard character.isNumber || character == ";" else { return nil }
            parameterText.append(character)
            cursor = text.index(after: cursor)
        }

        return nil
    }

    private static func apply(_ codes: [Int], to attributes: inout [NSAttributedString.Key: Any]) {
        for code in codes {
            switch code {
            case 0:
                attributes = defaultAttributes()
            case 1:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            case 22:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            case 30...37, 90...97:
                attributes[.foregroundColor] = color(for: code)
            case 39:
                attributes[.foregroundColor] = NSColor.textColor
            default:
                continue
            }
        }
    }

    private static func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor
        ]
    }

    private static func color(for code: Int) -> NSColor {
        switch code {
        case 30: return .black
        case 31, 91: return .systemRed
        case 32, 92: return .systemGreen
        case 33, 93: return .systemYellow
        case 34, 94: return .systemBlue
        case 35, 95: return .systemPurple
        case 36, 96: return .systemCyan
        case 37, 97: return .textColor
        case 90: return .secondaryLabelColor
        default: return .textColor
        }
    }
}

private struct GitPreviewANSITextView: NSViewRepresentable {
    let output: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(GitPreviewANSITextRenderer.attributedString(for: output))
    }
}

enum GitPreviewPanelLayout {
    static func frame(adjacentTo parentFrame: NSRect, panelSize: NSSize, visibleFrame: NSRect) -> NSRect {
        let horizontalGap: CGFloat = 12
        var origin = NSPoint(x: parentFrame.maxX + horizontalGap, y: parentFrame.maxY - panelSize.height)

        if origin.x + panelSize.width > visibleFrame.maxX {
            origin.x = parentFrame.minX - horizontalGap - panelSize.width
        }
        origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)

        return NSRect(origin: origin, size: panelSize)
    }
}
