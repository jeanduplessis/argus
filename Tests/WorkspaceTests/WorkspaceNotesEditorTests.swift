import AppKit
import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceNotesHighlighterTests {
    @Test
    func highlightsMarkdownConstructsWithoutHighlightingInsideCodeBlocks() {
        let text = """
            # Title
            Some **bold**, *it*, `**code**` and [link](https://example.com)
            - item
            > quote
            ```swift
            **not bold**
            ```
            after
            """
        let string = text as NSString

        let spans = WorkspaceNotesHighlighter.spans(in: text)

        func span(_ kind: WorkspaceNotesHighlightKind, _ fragment: String) -> WorkspaceNotesHighlightSpan {
            WorkspaceNotesHighlightSpan(kind: kind, range: string.range(of: fragment))
        }
        #expect(spans.contains(span(.heading, "# Title")))
        #expect(spans.contains(span(.bold, "**bold**")))
        #expect(spans.contains(span(.italic, "*it*")))
        #expect(spans.contains(span(.inlineCode, "`**code**`")))
        #expect(spans.contains(span(.link, "[link](https://example.com)")))
        let listMarker = NSRange(location: string.range(of: "- item").location, length: 1)
        #expect(spans.contains(WorkspaceNotesHighlightSpan(kind: .listMarker, range: listMarker)))
        #expect(spans.contains(span(.blockquote, "> quote")))
        #expect(spans.contains(span(.codeBlock, "```swift\n**not bold**\n```")))
        #expect(spans.filter { $0.kind == .bold }.count == 1)
        #expect(!spans.contains { NSIntersectionRange($0.range, string.range(of: "after")).length > 0 })
    }

    @Test
    func unclosedFenceHighlightsToTheEndOfTheNotes() {
        let text = "intro\n```\ncode"
        let spans = WorkspaceNotesHighlighter.spans(in: text)

        #expect(spans == [WorkspaceNotesHighlightSpan(kind: .codeBlock, range: NSRange(location: 6, length: 8))])
    }
}

@Suite
@MainActor
struct WorkspaceNotesEditorTests {
    @Test
    func editorDisablesTextSubstitutionsAndSupportsUndo() {
        let editor = WorkspaceNotesScrollView()
        let textView = editor.textView

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isRichText)
        #expect(textView.allowsUndo)
        #expect(!textView.isEditable, "no Selected Workspace means no editable notes")
        #expect(textView.accessibilityPlaceholderValue() == "Notes for this Workspace")
    }

    @Test
    func editsReportTheWorkspaceThatProducedThem() throws {
        let editor = WorkspaceNotesScrollView()
        let first = UUID()
        let second = UUID()
        var changes: [(String, UUID)] = []
        editor.onNotesChange = { changes.append(($0, $1)) }

        editor.showNotes("one", for: first)
        insert("!", into: editor)
        #expect(editor.textView.undoManager?.canUndo == true)

        editor.showNotes("two", for: second)
        #expect(editor.textView.string == "two")
        #expect(editor.textView.undoManager?.canUndo == false, "undo history never crosses Workspaces")
        insert("?", into: editor)

        #expect(changes.map(\.0) == ["one!", "two?"])
        #expect(changes.map(\.1) == [first, second])
    }

    @Test
    func editorRefusesEditsBeyondTheNotesLimit() {
        let editor = WorkspaceNotesScrollView()
        var changes: [String] = []
        editor.onNotesChange = { notes, _ in changes.append(notes) }
        let nearlyFull = String(repeating: "a", count: WorkspaceNotes.maximumUTF8ByteCount - 1)
        editor.showNotes(nearlyFull, for: UUID())

        insert("é", into: editor)
        #expect(editor.notesUTF8ByteCount == WorkspaceNotes.maximumUTF8ByteCount - 1)
        #expect(changes.isEmpty)

        insert("b", into: editor)
        #expect(editor.notesUTF8ByteCount == WorkspaceNotes.maximumUTF8ByteCount)
        #expect(changes.count == 1)
    }

    @Test
    func replacementBoundCountsRemovedAndInsertedUTF8Bytes() {
        let limit = WorkspaceNotes.maximumUTF8ByteCount
        #expect(WorkspaceNotes.fitsAfterReplacing(currentUTF8ByteCount: limit, removedText: "ab", insertedText: "é"))
        #expect(!WorkspaceNotes.fitsAfterReplacing(currentUTF8ByteCount: limit, removedText: "a", insertedText: "é"))
    }

    private func insert(_ text: String, into editor: WorkspaceNotesScrollView) {
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}

@Suite
@MainActor
struct RightSidebarNotesViewTests {
    @Test
    func rightSidebarViewDecodesNotesAndExistingRawValues() throws {
        #expect(AppSettings.RightSidebarView.allCases == [.files, .changes, .notes])
        #expect(AppSettings.RightSidebarView(rawValue: "notes") == .notes)
        #expect(AppSettings.RightSidebarView.notes.title == "Notes")

        for view in AppSettings.RightSidebarView.allCases {
            let suiteName = "ArgusTests.RightSidebarNotes.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(view.rawValue, forKey: "Argus.gitSidebar.selectedView")
            defaults.set(view.rawValue, forKey: "Argus.settings.general.defaultRightSidebarView")

            #expect(GitSidebarState(defaults: defaults).selectedView == view)
            #expect(AppSettings(defaults: defaults).defaultRightSidebarView == view)
        }
    }

    @Test
    func headerFallsBackToIconOnlyTabsAndHidesRefreshForNotes() throws {
        let rightView = try SourceContract("Argus/Views/GitSidebar/RightSidebarView.swift")
        rightView.containsAll(
            [
                "ViewThatFits(in: .horizontal)",
                "tabButtons(titles: .all)",
                "tabButtons(titles: .selectedOnly)",
                "tabButtons(titles: .none)",
                ".accessibilityLabel(tabAccessibilityLabel(panel))",
                ".opacity(gitSidebarState.selectedView == .notes ? 0 : 1)",
                ".allowsHitTesting(gitSidebarState.selectedView != .notes)",
                "if gitSidebarState.selectedView == .notes {",
                "WorkspaceNotesView()"
            ],
            "Notes View header and mounting"
        )
        try SourceContract("Argus/Views/GitSidebar/WorkspaceNotesView.swift").containsAll(
            [
                "fontSize: CGFloat(appSettings.documentTextSize)",
                ".background(ChromeColors.contentBackground)",
                "workspaceManager.flushWorkspaceNotesCheckpoint()"
            ],
            "Notes View uses document text size, focus-aware content background, and flushes on end of editing"
        )
    }
}
