import AppKit
import Foundation
import SwiftDiffs
import Testing

@testable import Argus

@Suite
struct ArgusDiffRenderingTests {
    @Test
    func mapsOldAndNewFilesToNativePackageInput() {
        let input = sampleInput()

        guard case .files(let oldFile, let newFile) = input.packageInput else {
            Issue.record("expected old/new file input")
            return
        }

        #expect(oldFile?.path == "file.swift")
        #expect(oldFile?.contents == "old\n")
        #expect(oldFile?.language == .swift)
        #expect(newFile?.path == "file.swift")
        #expect(newFile?.contents == "new\n")
        #expect(newFile?.language == .swift)
    }

    @Test
    func mapsSplitDarkPreviewToNativeConfiguration() {
        let configuration = sampleInput().packageConfiguration

        #expect(configuration.layout == .sideBySide)
        #expect(configuration.appearance == .dark)
        #expect(configuration.context == .collapsible())
    }

    @Test
    func mapsUnifiedLightPreviewToNativeConfiguration() {
        let input = ArgusDiffInput(
            oldFile: sampleInput().oldFile,
            newFile: sampleInput().newFile,
            options: ArgusDiffOptions(theme: .light, style: .unified)
        )

        #expect(input.packageConfiguration.layout == .unified)
        #expect(input.packageConfiguration.appearance == .light)
        #expect(input.packageConfiguration.context == .collapsible())
    }

    @Test
    func ignoresUnknownLanguageHintsWithoutRejectingTheDiff() {
        let file = ArgusDiffFile(
            name: "notes.txt",
            contents: "plain\n",
            language: "unknown-language"
        )

        #expect(file.packageFile.language == nil)
    }

    @Test
    func previewHeaderExposesSplitAndUnifiedWithoutOverflowControls() throws {
        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").containsAll(
            [
                "Picker(\"Layout\", selection: diffStyleBinding)",
                "Text(\"Split\").tag(ArgusDiffStyle.split)",
                "Text(\"Unified\").tag(ArgusDiffStyle.unified)",
                "ArgusDiffView("
            ],
            "native Git Preview layout controls"
        )
        try SourceContract("Argus/Views/GitSidebar/GitPreviewPanel.swift").excludes(
            "Overflow",
            "native diffs do not expose wrap or scroll overflow"
        )
        try SourceContract("Argus/Settings/SettingsView.swift").excludes(
            "Default diff overflow",
            "native diffs do not persist an overflow default"
        )
    }

    private func sampleInput() -> ArgusDiffInput {
        ArgusDiffInput(
            oldFile: ArgusDiffFile(name: "file.swift", contents: "old\n", language: "swift"),
            newFile: ArgusDiffFile(name: "file.swift", contents: "new\n", language: "swift"),
            options: ArgusDiffOptions(theme: .dark, style: .split))
    }
}

@Suite
struct FileTabUIContractTests {
    @Test
    func fileTabsShowLineNumbersAndWrapSourceByDefault() throws {
        let lineIndex = FileSourceLineIndex(text: "first\r\n/* second\ncontinued */\n")

        #expect(lineIndex.lineStarts == [0, 7, 17, 30])
        #expect(lineIndex.lineNumber(startingAt: 17) == 3)
        #expect(lineIndex.lineNumber(startingAt: 30) == 4)
        #expect(lineIndex.lineNumber(startingAt: 8) == nil)
        #expect(FileSourceLineIndex(text: "").lineStarts == [0])
        #expect(FileSourceLineIndex(text: "a\n\nb").lineStarts == [0, 2, 3])
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "FilePanelInitialPresentation.resolve(",
                "private var lineWrapButton: some View",
                "Text(\"Wrap\")",
                ".accessibilityLabel(\"Line wrap\")",
                ".accessibilityValue(lineWrapEnabled ? \"On\" : \"Off\")",
                "final class FileSourceLineNumberRulerView: NSRulerView",
                "NSColor.labelColor.withAlphaComponent(0.025)"
            ], "File Tab source gutter and line wrap control")
    }

    @Test
    func filePanelSyntaxHighlighterStylesRecognizedSourceFiles() throws {
        let swiftTokens = FileSyntaxHighlighter.tokens(
            in: "import SwiftUI\nlet title = \"Argus\" // app name\n",
            fileName: "Sources/App.swift")

        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "import")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .keyword, text: "let")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .typeName, text: "SwiftUI")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
        #expect(swiftTokens.contains(FileSyntaxHighlightToken(kind: .comment, text: "// app name")))

        let jsonTokens = FileSyntaxHighlighter.tokens(
            in: "{\n  \"name\": \"Argus\",\n  \"enabled\": true\n}",
            fileName: "config.json")

        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .property, text: "\"name\"")))
        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .string, text: "\"Argus\"")))
        #expect(jsonTokens.contains(FileSyntaxHighlightToken(kind: .literal, text: "true")))

        #expect(
            FileSyntaxHighlighter.tokens(
                in: "let title = \"plain\"",
                fileName: "notes.txt"
            ).isEmpty)
    }

    @Test
    func markdownFileTabsExposeSourceAndRenderedDisplays() throws {
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "enum FileDisplayMode", "case source", "case preview",
                "return \"doc.plaintext\"", "isSVG ? \"photo\" : \"doc.richtext\"",
                "Show Markdown source", "Show rendered Markdown",
                "if isMarkdownFile, displayMode == .preview",
                "MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)",
                ".cursor(.pointingHand)",
                ".accessibilityValue(isSelected ? \"Selected\" : \"\")"
            ], "Markdown File Tab display controls")
    }

    @Test
    func fileTabDisplayIconsKeepSelectionAndHoverDistinct() throws {
        let view = try SourceContract("Argus/Views/Content/ContentAreaView.swift")
        let displayModeButton = try view.section(
            after: "private func displayModeButton(",
            before: "private func sourceContent")

        for expected in [
            ".frame(width: 20, height: 20)",
            ".fill(isSelected ? ChromeColors.activeTabFill : Color.clear)",
            ".fill(isHovered ? ChromeColors.hoveredTabFill : Color.clear)",
            ".contentShape(Rectangle())",
            ".cursor(.pointingHand)",
            ".help(label)",
            ".accessibilityLabel(label)",
            "HoverStateView { isHovered in"
        ] {
            #expect(displayModeButton.contains(expected))
        }

        view.excludes("hoveredDisplayMode", "display hover state must remain control-local")
        view.excludes("isLineWrapButtonHovered", "line-wrap hover state must remain control-local")
    }

    @Test
    func filePanelCachesDerivedRenderingOutsideBody() throws {
        let filePanel = try SourceContract("Argus/Views/Content/ContentAreaView.swift")
        filePanel.containsAll(
            [
                "struct FilePanelPreparedContent",
                "let source: FileSourceDocument?",
                "let markdownBlocks: [MarkdownRenderedBlock]",
                "source = FileSourceDocument(text: text, fileName: fileName)",
                "markdownBlocks = MarkdownRenderer.blocks(",
                "sourceContent(preparedContent.source)",
                "MarkdownRenderedView(blocks: preparedContent.markdownBlocks, documentTextSize: documentTextSize)"
            ], "File Tab derived rendering cache")

        let previews = try SourceContract("Argus/Views/Content/ContentAreaView+Previews.swift")
        let markdownView = try previews.section(
            after: "struct MarkdownRenderedView: View",
            before: "var body: some View")
        #expect(!markdownView.contains("MarkdownRenderer.blocks("))
    }

    @Test
    func filePanelClassifiesRasterImagesAndSVGContent() throws {
        let pngData = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let pngURL = URL(fileURLWithPath: "/tmp/pixel.png")
        #expect(FilePanelContentLoader.content(data: pngData, url: pngURL) == .loaded(.image(pngData)))
        let unknownImageURL = URL(fileURLWithPath: "/tmp/pixel.data")
        #expect(FilePanelContentLoader.content(data: pngData, url: unknownImageURL) == .loaded(.image(pngData)))
        #expect(NSImage(data: pngData) != nil)

        let svgSource = """
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
              <rect width="20" height="20" fill="red"/>
            </svg>
            """
        let svgData = Data(svgSource.utf8)
        let svgURL = URL(fileURLWithPath: "/tmp/icon.svg")
        #expect(
            FilePanelContentLoader.content(data: svgData, url: svgURL)
                == .loaded(.svg(source: svgSource, data: svgData)))
        #expect(NSImage(data: svgData) != nil)
    }

    @Test
    func filePanelClassifiesUTF8ConfigurationFilesAsText() {
        let samples = [
            ("workflow.yml", "name: CI\n"),
            ("config.yaml", "enabled: true\n"),
            ("config.json", "{\"name\":\"Argus\"}\n"),
            (".gitignore", ".build/\n")
        ]

        for (fileName, source) in samples {
            let data = Data(source.utf8)
            let url = URL(fileURLWithPath: "/tmp/\(fileName)")
            #expect(FilePanelContentLoader.content(data: data, url: url) == .loaded(.text(source)))
        }
    }

    @Test
    func filePanelRejectsOversizedAndNonRegularFilesBeforeReading() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-file-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let largeFile = directory.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: FilePanelContentLoader.maximumFileSize + 1).write(to: largeFile)

        #expect(FilePanelContentLoader.load(url: largeFile) == .oversized)
        guard case .failed = FilePanelContentLoader.load(url: directory) else {
            Issue.record("directories must not be loaded as file content")
            return
        }
    }

    @Test
    func imageFileTabsPreviewRasterImagesAndOfferSVGSourceMode() throws {
        try SourceContract("Argus/Views/Content/ContentAreaView.swift").containsAll(
            [
                "case image(Data)",
                "case svg(source: String, data: Data)",
                "type.conforms(to: .image)",
                "CGImageSourceCreateWithData",
                "FileImagePreview(data: data, accessibilityLabel: panel.displayTitle)",
                "Show SVG source", "Show SVG preview",
                "if displayMode == .preview",
                "Image(nsImage: image)",
                ".scaledToFit()",
                "Image preview is unavailable"
            ], "image File Tab previews")
    }

    @Test
    func markdownRendererPreservesCommonBlockStructure() {
        let blocks = MarkdownRenderer.blocks(
            source: """
                # Heading

                Paragraph with **bold** text.

                - First

                > Quote

                ```swift
                let value = 1
                ```

                | Name | Value |
                | --- | --- |
                | Argus | One |
                """,
            baseURL: URL(fileURLWithPath: "/tmp"))

        guard case .heading(let level, let heading) = blocks[0] else {
            Issue.record("expected heading block")
            return
        }
        #expect(level == 1)
        #expect(String(heading.characters) == "Heading")

        #expect(
            blocks.contains { block in
                guard case .listItem(let marker, _, let content) = block else { return false }
                return marker == "•" && String(content.characters) == "First"
            })
        #expect(
            blocks.contains { block in
                guard case .quote(let content) = block else { return false }
                return String(content.characters) == "Quote"
            })
        #expect(
            blocks.contains { block in
                guard case .code(let language, let content) = block else { return false }
                return language == "swift" && String(content.characters).contains("let value = 1")
            })
        #expect(
            blocks.contains { block in
                guard case .table(let rows) = block else { return false }
                return rows.count == 2
                    && rows[0].isHeader
                    && String(rows[1].cells[0].characters) == "Argus"
            })
    }
}

@Suite
@MainActor
struct FileTabSourceSelectionTests {
    @Test
    func sourceSelectionCopiesPlainFileTextAcrossLines() throws {
        let text = "let first = 1\n// second\nthird\n"
        let scrollView = makeSourceView(text: text, wrapsLines: true)
        let textView = scrollView.textView

        #expect(!textView.isEditable)
        #expect(textView.isSelectable)
        let keywordColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keywordColor == .systemPurple)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArgusTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        textView.setSelectedRange(NSRange(location: 4, length: 16))
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == "first = 1\n// sec")

        textView.selectAll(nil)
        #expect(textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        #expect(pasteboard.string(forType: .string) == text)
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test
    func lineNumbersStayOnFirstFragmentOfWrappedLines() throws {
        let text = String(repeating: "word ", count: 80) + "\nshort\n"
        let scrollView = makeSourceView(text: text, wrapsLines: true)
        let lineHeight = try #require(scrollView.textView.layoutManager)
            .defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))

        let wrapped = scrollView.visibleLineNumbers
        #expect(wrapped.map(\.number) == [1, 2, 3])
        #expect(!scrollView.hasHorizontalScroller)
        #expect(wrapped[1].minY - wrapped[0].minY > lineHeight * 2)
        scrollView.setFrameSize(NSSize(width: 300, height: 300))
        let clipView = scrollView.contentView
        let visibleTextWidth = clipView.bounds.width - clipView.contentInsets.left - clipView.contentInsets.right
        #expect(clipView.contentInsets.left > 0)
        #expect(scrollView.textView.frame.width == visibleTextWidth)

        scrollView.update(
            document: FileSourceDocument(text: text, fileName: "notes.txt"),
            fontSize: 12,
            wrapsLines: false)
        layOut(scrollView)

        let unwrapped = scrollView.visibleLineNumbers
        #expect(unwrapped.map(\.number) == [1, 2, 3])
        #expect(scrollView.hasHorizontalScroller)
        #expect(unwrapped[1].minY - unwrapped[0].minY < lineHeight * 2)
        #expect(scrollView.textView.frame.width > scrollView.contentSize.width)
    }

    @Test
    func mountingSourceViewKeepsExistingFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        let probe = FirstResponderProbeView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(probe)
        #expect(window.makeFirstResponder(probe))

        let scrollView = makeSourceView(text: "one\ntwo\n", wrapsLines: true)
        window.contentView?.addSubview(scrollView)
        layOut(scrollView)

        #expect(window.firstResponder === probe)
    }

    private func makeSourceView(text: String, wrapsLines: Bool) -> FileSourceScrollView {
        let scrollView = FileSourceScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.update(
            document: FileSourceDocument(text: text, fileName: "Example.swift"),
            fontSize: 12,
            wrapsLines: wrapsLines)
        layOut(scrollView)
        return scrollView
    }

    private func layOut(_ scrollView: FileSourceScrollView) {
        scrollView.tile()
        if let layoutManager = scrollView.textView.layoutManager,
            let textContainer = scrollView.textView.textContainer
        {
            layoutManager.ensureLayout(for: textContainer)
        }
        scrollView.layoutSubtreeIfNeeded()
    }
}

private final class FirstResponderProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@Suite
@MainActor
struct FilePanelPasteboardContentTests {
    @Test
    func copyFileContentMapsLoadedFilesToPasteboardContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-copy-file-content-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func content(_ name: String, _ data: Data) throws -> FilePanelPasteboardContent? {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            return FilePanelPasteboardContent(state: FilePanelContentLoader.load(url: url))
        }

        let svgSource = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>"
        #expect(try content("notes.txt", Data("one\ntwo\n".utf8)) == .string("one\ntwo\n"))
        #expect(try content("icon.svg", Data(svgSource.utf8)) == .string(svgSource))
        #expect(try content("pixel.png", Self.pngData) == .image(Self.pngData))
        #expect(FilePanelPasteboardContent(state: .binary) == nil)
        #expect(
            try content("large.txt", Data(repeating: 65, count: FilePanelContentLoader.maximumFileSize + 1))
                == nil)
        #expect(FilePanelPasteboardContent(state: FilePanelContentLoader.load(url: directory)) == nil)
    }

    @Test
    func copyFileContentWritesTextOrImageAndLeavesPasteboardOnFailure() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ArgusTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(FilePanelPasteboardContent.string("source").write(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "source")

        // The loader can classify undecodable binary data as an image; copying it must still fail.
        #expect(!FilePanelPasteboardContent.image(Data([0x00, 0x01, 0xFF, 0x00])).write(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "source")

        #expect(FilePanelPasteboardContent.image(Self.pngData).write(to: pasteboard))
        #expect(pasteboard.canReadObject(forClasses: [NSImage.self]))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    private static let pngData = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}  // swiftlint:disable:this file_length
