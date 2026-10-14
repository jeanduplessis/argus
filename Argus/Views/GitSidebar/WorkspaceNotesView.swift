import AppKit
import SwiftUI

/// Notes View: one plain-text editor for the Selected Workspace's Workspace Notes.
struct WorkspaceNotesView: View {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        WorkspaceNotesEditor(
            workspace: workspaceManager.selectedWorkspace,
            fontSize: CGFloat(appSettings.documentTextSize),
            onNotesChange: { notes, workspaceId in
                workspaceManager.setWorkspaceNotes(notes, for: workspaceId)
            },
            onEndEditing: { workspaceManager.flushWorkspaceNotesCheckpoint() }
        )
        .background(ChromeColors.contentBackground)
    }
}

struct WorkspaceNotesEditor: NSViewRepresentable {
    let workspace: Workspace?
    let fontSize: CGFloat
    let onNotesChange: (String, UUID) -> Void
    let onEndEditing: () -> Void

    func makeNSView(context: Context) -> WorkspaceNotesScrollView {
        WorkspaceNotesScrollView()
    }

    func updateNSView(_ scrollView: WorkspaceNotesScrollView, context: Context) {
        scrollView.onNotesChange = onNotesChange
        scrollView.onEndEditing = onEndEditing
        scrollView.setFontSize(fontSize)
        if scrollView.workspaceId != workspace?.id {
            scrollView.showNotes(workspace?.notes ?? "", for: workspace?.id)
        }
    }

    static func dismantleNSView(_ scrollView: WorkspaceNotesScrollView, coordinator: ()) {
        scrollView.onEndEditing?()
    }
}

/// Hosts the Workspace Notes text view. Editor text, undo history, and the
/// UTF-8 byte count are transient; durable notes live on the Workspace.
final class WorkspaceNotesScrollView: NSScrollView, NSTextViewDelegate {
    static let placeholder = "Notes for this Workspace"
    static let textInset = NSSize(width: 12, height: 12)

    let textView: WorkspaceNotesTextView
    private(set) var workspaceId: UUID?
    private(set) var notesUTF8ByteCount = 0
    private let notesUndoManager = UndoManager()
    private var baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var onNotesChange: ((String, UUID) -> Void)?
    var onEndEditing: (() -> Void)?

    override init(frame frameRect: NSRect) {
        textView = WorkspaceNotesTextView(usingTextLayoutManager: false)
        super.init(frame: frameRect)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        contentView.drawsBackground = false

        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesRuler = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.font = baseFont
        textView.placeholder = Self.placeholder
        textView.setAccessibilityLabel("Workspace Notes")
        textView.setAccessibilityPlaceholderValue(Self.placeholder)
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Replaces the editor with one Workspace's notes. Undo history never
    /// crosses Workspaces, so it is cleared on every swap.
    func showNotes(_ notes: String, for workspaceId: UUID?) {
        textView.unmarkText()
        self.workspaceId = workspaceId
        textView.isEditable = workspaceId != nil
        textView.string = notes
        notesUTF8ByteCount = notes.utf8.count
        notesUndoManager.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        highlight()
    }

    func setFontSize(_ size: CGFloat) {
        guard baseFont.pointSize != size else { return }
        baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        textView.font = baseFont
        highlight()
    }

    private func highlight() {
        guard let textStorage = textView.textStorage else { return }
        WorkspaceNotesHighlighter.apply(to: textStorage, baseFont: baseFont)
        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
        textView.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        notesUndoManager
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString else { return true }
        let removedText = (textView.string as NSString).substring(with: affectedCharRange)
        guard
            WorkspaceNotes.fitsAfterReplacing(
                currentUTF8ByteCount: notesUTF8ByteCount,
                removedText: removedText,
                insertedText: replacementString
            )
        else {
            NSSound.beep()
            return false
        }
        return true
    }

    func textDidChange(_ notification: Notification) {
        let notes = textView.string
        notesUTF8ByteCount = notes.utf8.count
        highlight()
        guard let workspaceId else { return }
        onNotesChange?(notes, workspaceId)
    }

    func textDidEndEditing(_ notification: Notification) {
        onEndEditing?()
    }
}

/// Plain-text Workspace Notes editor that draws its placeholder while empty.
final class WorkspaceNotesTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: origin.x + padding, y: origin.y), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
