// swiftlint:disable file_length
// ContentAreaView+FilePanel.swift
// Argus

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum FilePanelLoadedContent: Equatable, Sendable {
    case text(String)
    case image(Data)
    case svg(source: String, data: Data)
}

enum FilePanelContentState: Equatable, Sendable {
    case loading
    case loaded(FilePanelLoadedContent)
    case binary
    case oversized
    case failed(String)
}

struct FilePanelInitialPresentation: Equatable {
    let displayMode: FileDisplayMode
    let lineWrapEnabled: Bool

    static func resolve(
        fileURL: URL,
        wrapSourceLines: Bool,
        openMarkdownInPreview: Bool,
        openSVGInPreview: Bool
    ) -> Self {
        let fileExtension = fileURL.pathExtension.lowercased()
        let opensInPreview =
            (fileExtension == "svg" && openSVGInPreview)
            || (["md", "markdown"].contains(fileExtension) && openMarkdownInPreview)
        return Self(
            displayMode: opensInPreview ? .preview : .source,
            lineWrapEnabled: wrapSourceLines
        )
    }
}

enum FilePanelContentLoader {
    static let maximumFileSize = 2 * 1_024 * 1_024

    static func load(url: URL) -> FilePanelContentState {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                return .failed("File preview is unavailable for this item")
            }
            if let fileSize = values.fileSize, fileSize > maximumFileSize {
                return .oversized
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
            guard data.count <= maximumFileSize else { return .oversized }
            guard !Task.isCancelled else { return .loading }
            return content(data: data, url: url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func content(data: Data, url: URL) -> FilePanelContentState {
        if url.pathExtension.lowercased() == "svg" {
            guard let source = String(data: data, encoding: .utf8) else {
                return .failed("SVG source is not valid UTF-8")
            }
            return .loaded(.svg(source: source, data: data))
        }

        if let type = UTType(filenameExtension: url.pathExtension),
            type.conforms(to: .image)
        {
            return .loaded(.image(data))
        }

        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return .loaded(.text(text))
        }

        if CGImageSourceCreateWithData(data as CFData, nil) != nil {
            return .loaded(.image(data))
        }

        return .binary
    }
}

/// Pasteboard payload for the File Tab "Copy File Content" action.
enum FilePanelPasteboardContent: Equatable {
    case string(String)
    case image(Data)

    /// Nil for binary, oversized, failed, or still-loading content.
    init?(state: FilePanelContentState) {
        switch state {
        case .loaded(.text(let text)):
            self = .string(text)
        case .loaded(.svg(let source, _)):
            self = .string(source)
        case .loaded(.image(let data)):
            self = .image(data)
        case .loading, .binary, .oversized, .failed:
            return nil
        }
    }

    /// Leaves the pasteboard unchanged and returns false when the content cannot be written.
    @MainActor
    func write(to pasteboard: NSPasteboard) -> Bool {
        switch self {
        case .string(let text):
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        case .image(let data):
            guard let image = NSImage(data: data) else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])
        }
    }

    /// Reads the file's current contents off the main actor, then writes them to
    /// the general pasteboard or beeps when the file cannot be copied.
    @MainActor
    static func copyFileContent(at url: URL) {
        Task {
            let state = await Task.detached(priority: .userInitiated) {
                FilePanelContentLoader.load(url: url)
            }.value
            guard let content = FilePanelPasteboardContent(state: state),
                content.write(to: .general)
            else {
                NSSound.beep()
                return
            }
        }
    }
}

struct FilePanelContentView: View {
    @ObservedObject var panel: FilePanel
    @EnvironmentObject private var appSettings: AppSettings
    @State private var preparedContent = FilePanelPreparedContent.loading
    let documentTextSize: Double

    init(
        panel: FilePanel,
        wrapSourceLines: Bool = true,
        openMarkdownInPreview: Bool = false,
        openSVGInPreview: Bool = false,
        documentTextSize: Double = 12
    ) {
        self.panel = panel
        let initialPresentation = FilePanelInitialPresentation.resolve(
            fileURL: panel.fileURL,
            wrapSourceLines: wrapSourceLines,
            openMarkdownInPreview: openMarkdownInPreview,
            openSVGInPreview: openSVGInPreview
        )
        if panel.displayMode == nil {
            panel.displayMode = initialPresentation.displayMode
        }
        if panel.lineWrapEnabled == nil {
            panel.lineWrapEnabled = initialPresentation.lineWrapEnabled
        }
        self.documentTextSize = documentTextSize
    }

    private var displayMode: FileDisplayMode {
        get { panel.displayMode ?? .source }
        nonmutating set { panel.displayMode = newValue }
    }

    private var lineWrapEnabled: Bool {
        get { panel.lineWrapEnabled ?? true }
        nonmutating set { panel.lineWrapEnabled = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            fileHeader
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChromeColors.contentBackground)
        .task(id: panel.fileURL) {
            await loadFile()
        }
    }
}

extension FilePanelContentView {
    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(panel.relativePath)
                .font(
                    .system(
                        size: appSettings.presentationMetrics.textSize(forBaseSize: 12),
                        weight: .medium,
                        design: .monospaced
                    )
                )
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)

            if showsSource {
                lineWrapButton
            }

            if supportsSourcePreview {
                ForEach(FileDisplayMode.allCases, id: \.self) { mode in
                    displayModeButton(mode)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .overlay(alignment: .bottom) {
            ChromeColors.separator.frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loaded(let loadedContent):
            switch loadedContent {
            case .text:
                if isMarkdownFile, displayMode == .preview {
                    MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)
                } else {
                    sourceContent(preparedContent.source)
                }
            case .image(let data):
                FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)
            case .svg(_, let data):
                if displayMode == .preview {
                    FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)
                } else {
                    sourceContent(preparedContent.source)
                }
            }
        case .binary:
            fileMessage("Binary file", systemImage: "doc.fill")
        case .oversized:
            fileMessage("File is too large to preview", systemImage: "doc.badge.ellipsis")
        case .failed(let message):
            fileMessage(message, systemImage: "exclamationmark.triangle")
        }
    }

    private var state: FilePanelContentState {
        preparedContent.state
    }

    private var isMarkdownFile: Bool {
        ["md", "markdown"].contains(panel.fileURL.pathExtension.lowercased())
    }

    private var isSVGFile: Bool {
        panel.fileURL.pathExtension.lowercased() == "svg"
    }

    private var supportsSourcePreview: Bool {
        isMarkdownFile || isSVGFile
    }

    private var showsSource: Bool {
        switch state {
        case .loaded(.text):
            return !supportsSourcePreview || displayMode == .source
        case .loaded(.svg):
            return displayMode == .source
        default:
            return false
        }
    }

    private var fileIcon: String {
        switch state {
        case .loaded(.image), .loaded(.svg):
            return "photo"
        default:
            return "doc.text"
        }
    }

    private var lineWrapButton: some View {
        HoverStateView { isHovered in
            Button {
                lineWrapEnabled.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(lineWrapEnabled ? Color.primary : Color.secondary)
                        .accessibilityHidden(true)
                    Text("Wrap")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(lineWrapEnabled ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(lineWrapEnabled ? ChromeColors.activeTabFill : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(lineWrapEnabled ? "Disable line wrap" : "Enable line wrap")
            .accessibilityLabel("Line wrap")
            .accessibilityValue(lineWrapEnabled ? "On" : "Off")
        }
    }

    private func displayModeButton(_ mode: FileDisplayMode) -> some View {
        let isSelected = displayMode == mode
        let label = mode.accessibilityLabel(isSVG: isSVGFile)

        return HoverStateView { isHovered in
            Button {
                displayMode = mode
            } label: {
                Image(systemName: mode.systemImage(isSVG: isSVGFile))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .accessibilityHidden(true)
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? ChromeColors.activeTabFill : Color.clear)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)
                            }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }

    @ViewBuilder
    private func sourceContent(_ document: FileSourceDocument?) -> some View {
        if let document {
            FileSourceTextView(
                document: document,
                wrapsLines: lineWrapEnabled,
                fontSize: documentTextSize,
                accessibilityLabel: "Source of \(panel.relativePath)"
            )
        }
    }

    private func fileMessage(_ message: String, systemImage: String) -> some View {
        SurfaceMessageView(systemImage: systemImage, title: message)
    }

    private func loadFile() async {
        let url = panel.fileURL
        let fileName = panel.relativePath
        preparedContent = .loading
        let loadedContent = await Task.detached(priority: .userInitiated) {
            let loadedState = FilePanelContentLoader.load(url: url)
            guard !Task.isCancelled else { return FilePanelPreparedContent.loading }
            return FilePanelPreparedContent(
                state: loadedState,
                fileURL: url,
                fileName: fileName
            )
        }.value
        guard !Task.isCancelled,
            panel.fileURL == url,
            panel.relativePath == fileName
        else {
            return
        }
        preparedContent = loadedContent
    }
}

// MARK: - Source Text View

/// UTF-16 offsets of every source line start, matching NSString paragraph
/// boundaries so gutter numbers follow the text system's line breaks.
struct FileSourceLineIndex: Equatable, Sendable {
    let lineStarts: [Int]

    init(text: String) {
        let string = text as NSString
        var starts = [0]
        var start = 0
        while start < string.length {
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(
                nil,
                end: &end,
                contentsEnd: &contentsEnd,
                for: NSRange(location: start, length: 0)
            )
            guard contentsEnd < end else { break }
            starts.append(end)
            start = end
        }
        lineStarts = starts
    }

    var lineCount: Int { lineStarts.count }

    /// One-based line number when `characterIndex` starts a line.
    func lineNumber(startingAt characterIndex: Int) -> Int? {
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] < characterIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < lineStarts.count, lineStarts[lower] == characterIndex else { return nil }
        return lower + 1
    }
}

/// Highlighted source prepared off the main actor. The attributed text is an
/// immutable `NSAttributedString` that is never mutated after creation, which
/// Foundation documents as safe to share across threads.
struct FileSourceDocument: @unchecked Sendable {
    let highlightedText: NSAttributedString
    let lineIndex: FileSourceLineIndex

    init(text: String, fileName: String) {
        highlightedText = FileSyntaxHighlighter.highlightedText(for: text, fileName: fileName)
        lineIndex = FileSourceLineIndex(text: text)
    }
}

struct FileSourceTextView: NSViewRepresentable {
    let document: FileSourceDocument
    let wrapsLines: Bool
    let fontSize: CGFloat
    let accessibilityLabel: String

    func makeNSView(context: Context) -> FileSourceScrollView {
        FileSourceScrollView()
    }

    func updateNSView(_ scrollView: FileSourceScrollView, context: Context) {
        scrollView.update(document: document, fontSize: fontSize, wrapsLines: wrapsLines)
        scrollView.textView.setAccessibilityLabel(accessibilityLabel)
    }
}

/// Plain-text, read-only NSTextView host. It never requests first responder
/// itself; it only takes keyboard focus when the user clicks into the text.
final class FileSourceScrollView: NSScrollView {
    static let textInset = NSSize(width: 12, height: 12)
    static let lineSpacing: CGFloat = 2

    let textView: NSTextView
    private let lineNumberRuler: FileSourceLineNumberRulerView
    private var document: FileSourceDocument?
    private var fontSize: CGFloat?
    private(set) var wrapsLines: Bool?

    override init(frame frameRect: NSRect) {
        textView = NSTextView(usingTextLayoutManager: false)
        lineNumberRuler = FileSourceLineNumberRulerView(textView: textView)
        super.init(frame: frameRect)

        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        contentView.drawsBackground = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesRuler = false
        textView.drawsBackground = false
        textView.textContainerInset = Self.textInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.frame = NSRect(origin: .zero, size: contentSize)
        documentView = textView

        verticalRulerView = lineNumberRuler
        hasVerticalRuler = true
        rulersVisible = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(document: FileSourceDocument, fontSize: CGFloat, wrapsLines: Bool) {
        let documentChanged = self.document?.highlightedText !== document.highlightedText
        if documentChanged {
            textView.textStorage?.setAttributedString(document.highlightedText)
            self.document = document
            lineNumberRuler.lineIndex = document.lineIndex
        }
        if documentChanged || fontSize != self.fontSize {
            applyFont(size: fontSize)
        }
        if wrapsLines != self.wrapsLines {
            applyLineWrap(wrapsLines)
        }
        lineNumberRuler.needsDisplay = true
    }

    /// Width visible beside the line-number ruler; the clip view insets its content by the ruler width.
    private var visibleTextWidth: CGFloat {
        let insets = contentView.contentInsets
        return max(contentView.bounds.width - insets.left - insets.right, 0)
    }

    /// Keeps wrapped text exactly as wide as the visible text area after ruler or frame changes.
    override func tile() {
        super.tile()
        guard wrapsLines == true, textView.frame.width != visibleTextWidth else { return }
        textView.setFrameSize(NSSize(width: visibleTextWidth, height: textView.frame.height))
    }

    var visibleLineNumbers: [FileSourceLineNumberRulerView.LineNumber] {
        lineNumberRuler.visibleLineNumbers()
    }

    private func applyFont(size: CGFloat) {
        fontSize = size
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = Self.lineSpacing
        if let textStorage = textView.textStorage {
            textStorage.addAttributes(
                [.font: font, .paragraphStyle: paragraphStyle],
                range: NSRange(location: 0, length: textStorage.length)
            )
        }
        textView.font = font
        textView.defaultParagraphStyle = paragraphStyle
        lineNumberRuler.font = font
    }

    private func applyLineWrap(_ wraps: Bool) {
        wrapsLines = wraps
        guard let textContainer = textView.textContainer else { return }
        hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textContainer.widthTracksTextView = wraps
        // Unwrapped text sizes to its longest line; clip-view resizing must not shrink it.
        textView.autoresizingMask = wraps ? [.width] : []
        if wraps {
            textView.setFrameSize(NSSize(width: visibleTextWidth, height: textView.frame.height))
            textContainer.containerSize = NSSize(
                width: max(visibleTextWidth - Self.textInset.width * 2, 0),
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textContainer.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.sizeToFit()
    }
}

/// Gutter drawn beside the clip view. Numbers mark the first line fragment of
/// each source line, so wrapped continuation fragments stay unnumbered.
final class FileSourceLineNumberRulerView: NSRulerView {
    struct LineNumber: Equatable {
        let number: Int
        let minY: CGFloat
    }

    private static let minimumGutterWidth: CGFloat = 36
    private static let numberTrailingPadding: CGFloat = 8

    var lineIndex = FileSourceLineIndex(text: "") {
        didSet { updateThickness() }
    }
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet { updateThickness() }
    }

    init(textView: NSTextView) {
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        updateThickness()

        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clientGeometryDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let contentView = scrollView?.contentView else { return }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clientGeometryDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }

    @objc private func clientGeometryDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gutterWidth = ruleThickness - 1
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        NSRect(x: 0, y: dirtyRect.minY, width: gutterWidth, height: dirtyRect.height).fill(using: .sourceOver)
        ChromeColors.separatorNSColor.setFill()
        NSRect(x: gutterWidth, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill(using: .sourceOver)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.7)
        ]
        for line in visibleLineNumbers() {
            let label = String(line.number) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(
                at: NSPoint(x: gutterWidth - Self.numberTrailingPadding - width, y: line.minY),
                withAttributes: attributes
            )
        }
    }

    func visibleLineNumbers() -> [LineNumber] {
        guard let textView = clientView as? NSTextView,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return [] }

        let origin = textView.textContainerOrigin
        let visibleRect = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        var lines: [LineNumber] = []

        func append(characterIndex: Int, fragmentMinY: CGFloat) {
            guard let number = lineIndex.lineNumber(startingAt: characterIndex) else { return }
            let point = convert(NSPoint(x: 0, y: fragmentMinY + origin.y), from: textView)
            lines.append(LineNumber(number: number, minY: point.y))
        }

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentRange, _ in
            append(
                characterIndex: layoutManager.characterIndexForGlyph(at: fragmentRange.location),
                fragmentMinY: rect.minY
            )
        }
        let extraLineRect = layoutManager.extraLineFragmentRect
        if !extraLineRect.isEmpty, extraLineRect.intersects(visibleRect) {
            append(characterIndex: textView.textStorage?.length ?? 0, fragmentMinY: extraLineRect.minY)
        }
        return lines
    }

    private func updateThickness() {
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        let digitCount = CGFloat(String(lineIndex.lineCount).count)
        let gutterWidth = max(Self.minimumGutterWidth, ceil(digitCount * digitWidth + 18))
        ruleThickness = gutterWidth + 1
        needsDisplay = true
    }
}
