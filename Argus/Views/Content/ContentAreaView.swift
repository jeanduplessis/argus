// ContentAreaView.swift
// Argus

import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let workspace = workspaceManager.selectedWorkspace {
            WorkspaceContentView(workspace: workspace)
                .id(workspace.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No panels open")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observes a single workspace and renders its tab bar + panel content.
/// This MUST be a separate view with `@ObservedObject` so that changes
/// to `workspace.activePanelId` trigger a re-render.
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        VStack(spacing: 0) {
            TitlebarView()
                .allowsHitTesting(false)

            TabBarView(workspace: workspace)

            if let tabId = workspace.activeTabId,
               let layout = workspace.activeTabLayout {
                PanelSplitLayoutView(
                    workspace: workspace,
                    tabId: tabId,
                    node: layout
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Recursively renders the pane layout for the active tab.
struct PanelSplitLayoutView: View {
    @ObservedObject var workspace: Workspace
    let tabId: UUID
    let node: PanelLayoutNode
    var path: [PanelLayoutBranch] = []

    var body: some View {
        switch node {
        case .leaf(let panelId):
            if let panel = workspace.panels[panelId] {
                let active = panelId == workspace.activePanelId
                PanelContentView(
                    panel: panel,
                    isActive: active
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if panel.panelType == .terminal {
                        workspace.selectPanel(panelId)
                    }
                }
            }
        case .split(let direction, let ratio, let first, let second):
            GeometryReader { geometry in
                switch direction {
                case .vertical:
                    let availableLength = max(geometry.size.width - 1, 0)
                    HStack(spacing: 0) {
                        child(first, branch: .first)
                            .frame(width: availableLength * ratio)
                        PanelSplitDivider(
                            direction: direction,
                            ratio: ratio,
                            availableLength: availableLength,
                            onChange: setRatio
                        )
                        child(second, branch: .second)
                            .frame(width: availableLength * (1 - ratio))
                    }
                case .horizontal:
                    let availableLength = max(geometry.size.height - 1, 0)
                    VStack(spacing: 0) {
                        child(first, branch: .first)
                            .frame(height: availableLength * ratio)
                        PanelSplitDivider(
                            direction: direction,
                            ratio: ratio,
                            availableLength: availableLength,
                            onChange: setRatio
                        )
                        child(second, branch: .second)
                            .frame(height: availableLength * (1 - ratio))
                    }
                }
            }
        }
    }

    private func child(_ childNode: PanelLayoutNode, branch: PanelLayoutBranch) -> some View {
        PanelSplitLayoutView(
            workspace: workspace,
            tabId: tabId,
            node: childNode,
            path: path + [branch]
        )
    }

    private func setRatio(_ ratio: CGFloat) {
        withTransaction(Transaction(animation: nil)) {
            workspace.setSplitRatio(ratio, for: tabId, at: path)
        }
    }
}

/// One-point split separator with a 12-point invisible direct-manipulation target.
private struct PanelSplitDivider: View {
    let direction: PanelSplitDirection
    let ratio: CGFloat
    let availableLength: CGFloat
    let onChange: (CGFloat) -> Void

    @State private var dragStartRatio: CGFloat?

    var body: some View {
        separator
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: direction == .vertical ? 12 : nil,
                        height: direction == .horizontal ? 12 : nil
                    )
                    .contentShape(Rectangle())
                    .cursor(direction == .vertical ? .resizeLeftRight : .resizeUpDown)
                    .gesture(dragGesture)
            }
            .zIndex(1)
    }

    @ViewBuilder
    private var separator: some View {
        if direction == .vertical {
            ChromeColors.separator.frame(width: 1)
        } else {
            ChromeColors.separator.frame(height: 1)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard availableLength > 0 else { return }
                if dragStartRatio == nil {
                    dragStartRatio = ratio
                }

                let translation = direction == .vertical
                    ? value.translation.width
                    : value.translation.height
                let minimumPaneLength = min(80, availableLength * 0.5)
                let minimumRatio = minimumPaneLength / availableLength
                let proposedRatio = (dragStartRatio ?? ratio) + translation / availableLength
                let clampedRatio = min(max(proposedRatio, minimumRatio), 1 - minimumRatio)

                withTransaction(Transaction(animation: nil)) {
                    onChange(clampedRatio)
                }
            }
            .onEnded { _ in
                dragStartRatio = nil
            }
    }
}

// MARK: - Panel Content View

struct PanelContentView: View {
    let panel: any Panel
    var isActive: Bool = true

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                GeometryReader { geometry in
                    TerminalView(
                        surface: terminalPanel.surface,
                        isActive: isActive,
                        targetSize: geometry.size
                    )
                        // The representable occupies the same structural position
                        // for every tab. Key it by surface so SwiftUI cannot reuse
                        // the previous tab's TerminalNSView for a new surface.
                        .id(terminalPanel.surface.id)
                }
            }
        case .browser:
            if let browserPanel = panel as? BrowserPanel {
                BrowserView(panel: browserPanel, isActive: isActive)
                    .id(browserPanel.id)
            }
        case .file:
            if let filePanel = panel as? FilePanel {
                FilePanelContentView(panel: filePanel)
                    .id(filePanel.id)
            }
        case .gitPreview:
            if let previewPanel = panel as? GitPreviewPanel {
                GitPreviewPanelContentView(panel: previewPanel)
                    .id(previewPanel.id)
            }
        }
    }
}

private enum FilePanelContentState: Equatable {
    case loading
    case loaded(String)
    case binary
    case failed(String)
}

enum FileSourceText {
    static func lines(in text: String, fileName: String) -> [AttributedString] {
        let highlighted = FileSyntaxHighlighter.highlightedText(
            for: text,
            fileName: fileName
        )
        var lines: [AttributedString] = []
        var lineStart = highlighted.startIndex

        for index in highlighted.characters.indices where highlighted.characters[index].isNewline {
            lines.append(AttributedString(highlighted[lineStart..<index]))
            lineStart = highlighted.characters.index(after: index)
        }
        lines.append(AttributedString(highlighted[lineStart..<highlighted.endIndex]))
        return lines
    }
}

private enum MarkdownDisplayMode: CaseIterable {
    case source
    case rendered

    var systemImage: String {
        switch self {
        case .source:
            return "doc.plaintext"
        case .rendered:
            return "doc.richtext"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .source:
            return "Show Markdown source"
        case .rendered:
            return "Show rendered Markdown"
        }
    }
}

private struct FilePanelContentView: View {
    @ObservedObject var panel: FilePanel
    @State private var state: FilePanelContentState = .loading
    @State private var markdownDisplayMode: MarkdownDisplayMode = .source
    @State private var hoveredMarkdownDisplayMode: MarkdownDisplayMode?
    @State private var lineWrapEnabled = true
    @State private var isLineWrapButtonHovered = false

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

    private var fileHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(panel.relativePath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)

            if !isMarkdownFile || markdownDisplayMode == .source {
                lineWrapButton
            }

            if isMarkdownFile {
                ForEach(MarkdownDisplayMode.allCases, id: \.self) { mode in
                    markdownDisplayButton(mode)
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
        case .loaded(let text):
            if isMarkdownFile, markdownDisplayMode == .rendered {
                MarkdownRenderedView(
                    source: text,
                    baseURL: panel.fileURL.deletingLastPathComponent()
                )
            } else {
                sourceContent(text)
            }
        case .binary:
            fileMessage("Binary file", systemImage: "doc.fill")
        case .failed(let message):
            fileMessage(message, systemImage: "exclamationmark.triangle")
        }
    }

    private var isMarkdownFile: Bool {
        ["md", "markdown"].contains(panel.fileURL.pathExtension.lowercased())
    }

    private var lineWrapButton: some View {
        Button {
            lineWrapEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 10, weight: .medium))
                Text("Wrap")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(lineWrapEnabled ? .primary : .secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(lineWrapEnabled
                          ? ChromeColors.activeTabFill
                          : (isLineWrapButtonHovered
                             ? ChromeColors.hoveredTabFill
                             : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(lineWrapEnabled ? "Disable line wrap" : "Enable line wrap")
        .accessibilityLabel("Line wrap")
        .accessibilityValue(lineWrapEnabled ? "On" : "Off")
        .onHover { hovering in
            isLineWrapButtonHovered = hovering
        }
    }

    private func markdownDisplayButton(_ mode: MarkdownDisplayMode) -> some View {
        let isSelected = markdownDisplayMode == mode
        let isHovered = hoveredMarkdownDisplayMode == mode

        return Button {
            markdownDisplayMode = mode
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected
                              ? ChromeColors.activeTabFill
                              : (isHovered ? ChromeColors.hoveredTabFill : Color.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(mode.accessibilityLabel)
        .accessibilityLabel(mode.accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "")
        .onHover { hovering in
            hoveredMarkdownDisplayMode = hovering ? mode : nil
        }
    }

    private func sourceContent(_ text: String) -> some View {
        let lines = FileSourceText.lines(in: text, fileName: panel.relativePath)
        let digitCount = String(lines.count).count
        let gutterWidth = max(36, CGFloat(digitCount * 7 + 18))

        return GeometryReader { proxy in
            if lineWrapEnabled {
                ScrollView(.vertical) {
                    sourceLines(
                        lines,
                        gutterWidth: gutterWidth,
                        viewportSize: proxy.size,
                        wrapsLines: true
                    )
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    sourceLines(
                        lines,
                        gutterWidth: gutterWidth,
                        viewportSize: proxy.size,
                        wrapsLines: false
                    )
                }
            }
        }
    }

    private func sourceLines(
        _ lines: [AttributedString],
        gutterWidth: CGFloat,
        viewportSize: CGSize,
        wrapsLines: Bool
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                sourceLine(
                    lines[index],
                    number: index + 1,
                    gutterWidth: gutterWidth,
                    wrapsLines: wrapsLines
                )
            }
        }
        .padding(.vertical, 12)
        .frame(
            width: wrapsLines ? viewportSize.width : nil,
            alignment: .topLeading
        )
        .frame(
            minWidth: viewportSize.width,
            minHeight: viewportSize.height,
            alignment: .topLeading
        )
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Color.primary.opacity(0.025)
                    .frame(width: gutterWidth)
                ChromeColors.separator
                    .frame(width: 1)
            }
        }
    }

    private func sourceLine(
        _ line: AttributedString,
        number: Int,
        gutterWidth: CGFloat,
        wrapsLines: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(number))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: gutterWidth - 8, alignment: .trailing)
                .padding(.trailing, 8)
                .accessibilityLabel("Line \(number)")

            Group {
                if wrapsLines {
                    sourceLineText(line)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    sourceLineText(line)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
    }

    private func sourceLineText(_ line: AttributedString) -> some View {
        Text(line.characters.isEmpty ? AttributedString(" ") : line)
            .textSelection(.enabled)
    }

    private func fileMessage(_ message: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFile() async {
        state = .loading
        let url = panel.fileURL
        state = await Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url)
                if data.contains(0) {
                    return .binary
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    return .binary
                }
                return .loaded(text)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }
}

enum MarkdownRenderedBlock {
    case heading(level: Int, content: AttributedString)
    case paragraph(AttributedString)
    case listItem(marker: String, depth: Int, content: AttributedString)
    case quote(AttributedString)
    case code(language: String?, content: AttributedString)
    case thematicBreak
    case table([MarkdownRenderedTableRow])
}

struct MarkdownRenderedTableRow {
    let isHeader: Bool
    var cells: [AttributedString]
}

private struct MarkdownRunGroup {
    let identity: Int
    let components: [PresentationIntent.IntentType]
    var content: AttributedString
}

enum MarkdownRenderer {
    static func blocks(source: String, baseURL: URL?) -> [MarkdownRenderedBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let markdown = try? AttributedString(
            markdown: source,
            options: options,
            baseURL: baseURL
        ) else {
            return [.paragraph(AttributedString(source))]
        }

        var groups: [MarkdownRunGroup] = []
        for run in markdown.runs {
            guard let components = run.presentationIntent?.components,
                  let leaf = components.first
            else { continue }

            let content = AttributedString(markdown[run.range])
            if groups.last?.identity == leaf.identity {
                groups[groups.count - 1].content.append(content)
            } else {
                groups.append(MarkdownRunGroup(
                    identity: leaf.identity,
                    components: components,
                    content: content
                ))
            }
        }

        var result: [MarkdownRenderedBlock] = []
        var index = 0
        while index < groups.count {
            let group = groups[index]
            if let currentTableIdentity = tableIdentity(in: group.components) {
                var tableGroups: [MarkdownRunGroup] = []
                while index < groups.count,
                      tableIdentity(in: groups[index].components) == currentTableIdentity
                {
                    tableGroups.append(groups[index])
                    index += 1
                }
                result.append(.table(tableRows(from: tableGroups)))
                continue
            }

            result.append(block(from: group))
            index += 1
        }

        return result
    }

    private static func block(from group: MarkdownRunGroup) -> MarkdownRenderedBlock {
        guard let leafKind = group.components.first?.kind else {
            return .paragraph(group.content)
        }

        switch leafKind {
        case .header(let level):
            return .heading(level: level, content: group.content)
        case .codeBlock(let language):
            return .code(language: language, content: group.content)
        case .thematicBreak:
            return .thematicBreak
        default:
            break
        }

        if let listItem = group.components.first(where: {
            if case .listItem = $0.kind { return true }
            return false
        }) {
            let ordinal: Int
            if case .listItem(let value) = listItem.kind {
                ordinal = value
            } else {
                ordinal = 1
            }
            let listKinds = group.components.compactMap { component -> Bool? in
                switch component.kind {
                case .unorderedList:
                    return false
                case .orderedList:
                    return true
                default:
                    return nil
                }
            }
            let marker = listKinds.first == true ? "\(ordinal)." : "•"
            return .listItem(
                marker: marker,
                depth: max(0, listKinds.count - 1),
                content: group.content
            )
        }

        if group.components.contains(where: {
            if case .blockQuote = $0.kind { return true }
            return false
        }) {
            return .quote(group.content)
        }

        return .paragraph(group.content)
    }

    private static func tableIdentity(
        in components: [PresentationIntent.IntentType]
    ) -> Int? {
        components.first(where: {
            if case .table = $0.kind { return true }
            return false
        })?.identity
    }

    private static func tableRows(
        from groups: [MarkdownRunGroup]
    ) -> [MarkdownRenderedTableRow] {
        let columnCount = groups.first?.components.compactMap { component -> Int? in
            if case .table(let columns) = component.kind { return columns.count }
            return nil
        }.first ?? 0

        var rows: [(identity: Int, row: MarkdownRenderedTableRow)] = []
        for group in groups {
            guard let rowComponent = group.components.first(where: { component in
                switch component.kind {
                case .tableHeaderRow, .tableRow:
                    return true
                default:
                    return false
                }
            }),
            let column = group.components.compactMap({ component -> Int? in
                if case .tableCell(let value) = component.kind { return value }
                return nil
            }).first
            else { continue }

            let isHeader: Bool
            if case .tableHeaderRow = rowComponent.kind {
                isHeader = true
            } else {
                isHeader = false
            }

            if rows.last?.identity != rowComponent.identity {
                rows.append((
                    rowComponent.identity,
                    MarkdownRenderedTableRow(
                        isHeader: isHeader,
                        cells: Array(
                            repeating: AttributedString(""),
                            count: max(columnCount, column + 1)
                        )
                    )
                ))
            }

            if column >= rows[rows.count - 1].row.cells.count {
                rows[rows.count - 1].row.cells.append(contentsOf: Array(
                    repeating: AttributedString(""),
                    count: column - rows[rows.count - 1].row.cells.count + 1
                ))
            }
            rows[rows.count - 1].row.cells[column] = group.content
        }

        return rows.map(\.row)
    }
}

private struct MarkdownRenderedView: View {
    let blocks: [MarkdownRenderedBlock]

    init(source: String, baseURL: URL?) {
        blocks = MarkdownRenderer.blocks(source: source, baseURL: baseURL)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 760, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownRenderedBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(content)
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 4 : 10)
                .padding(.bottom, level <= 2 ? 10 : 6)
        case .paragraph(let content):
            Text(content)
                .font(.system(size: 14))
                .lineSpacing(3)
                .padding(.bottom, 12)
        case .listItem(let marker, let depth, let content):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 24, alignment: .trailing)
                Text(content)
                    .font(.system(size: 14))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(depth) * 20)
            .padding(.bottom, 6)
        case .quote(let content):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.top, 3)
                Text(content)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
            }
            .padding(.bottom, 12)
        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
            .padding(.bottom, 14)
        case .thematicBreak:
            ChromeColors.separator
                .frame(height: 1)
                .padding(.vertical, 14)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 13, weight: row.isHeader ? .semibold : .regular))
                                    .padding(8)
                                    .frame(minWidth: 100, maxWidth: 260, alignment: .leading)
                                    .background(row.isHeader ? Color.primary.opacity(0.055) : Color.clear)
                                    .overlay {
                                        Rectangle().stroke(ChromeColors.separator, lineWidth: 1)
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1:
            return .system(size: 26, weight: .bold)
        case 2:
            return .system(size: 22, weight: .bold)
        case 3:
            return .system(size: 18, weight: .semibold)
        case 4:
            return .system(size: 16, weight: .semibold)
        default:
            return .system(size: 14, weight: .semibold)
        }
    }
}

enum FileSyntaxHighlightKind: Equatable {
    case keyword
    case literal
    case string
    case comment
    case number
    case property
    case typeName
    case tag
}

struct FileSyntaxHighlightToken: Equatable {
    let kind: FileSyntaxHighlightKind
    let text: String
}

enum FileSyntaxHighlighter {
    static func highlightedText(for text: String, fileName: String) -> AttributedString {
        var attributed = AttributedString(text)

        for span in spans(in: text, fileName: fileName) {
            guard let range = Range(span.range, in: attributed) else { continue }
            attributed[range].foregroundColor = color(for: span.kind)
        }
        return attributed
    }

    static func tokens(in text: String, fileName: String) -> [FileSyntaxHighlightToken] {
        spans(in: text, fileName: fileName).map { span in
            FileSyntaxHighlightToken(
                kind: span.kind,
                text: String(text[span.range])
            )
        }
    }

    private static func spans(in text: String, fileName: String) -> [FileSyntaxHighlightSpan] {
        guard let language = language(for: fileName) else { return [] }

        var spans: [FileSyntaxHighlightSpan] = []
        var cursor = text.startIndex
        let keywordWords = language.keywordWords
        let literalWords = language.literalWords
        let typeWords = language.typeWords

        while cursor < text.endIndex {
            if language == .markdown,
               isLineStart(cursor, in: text),
               text[cursor] == "#"
            {
                let range = lineRange(in: text, from: cursor)
                spans.append(FileSyntaxHighlightSpan(kind: .keyword, range: range))
                cursor = range.upperBound
                continue
            }

            if language.supportsHTMLComments,
               hasPrefix("<!--", in: text, at: cursor)
            {
                let range = rangeUntilTerminator(
                    in: text,
                    from: cursor,
                    openingLength: 4,
                    terminator: "-->"
                )
                spans.append(FileSyntaxHighlightSpan(kind: .comment, range: range))
                cursor = range.upperBound
                continue
            }

            if language.highlightsTags,
               text[cursor] == "<"
            {
                let range = tagRange(in: text, from: cursor)
                spans.append(FileSyntaxHighlightSpan(kind: .tag, range: range))
                cursor = range.upperBound
                continue
            }

            if language.supportsSlashLineComments,
               hasPrefix("//", in: text, at: cursor)
            {
                let range = lineRange(in: text, from: cursor)
                spans.append(FileSyntaxHighlightSpan(kind: .comment, range: range))
                cursor = range.upperBound
                continue
            }

            if language.supportsBlockComments,
               hasPrefix("/*", in: text, at: cursor)
            {
                let range = rangeUntilTerminator(
                    in: text,
                    from: cursor,
                    openingLength: 2,
                    terminator: "*/"
                )
                spans.append(FileSyntaxHighlightSpan(kind: .comment, range: range))
                cursor = range.upperBound
                continue
            }

            if language.supportsHashLineComments,
               text[cursor] == "#"
            {
                let range = lineRange(in: text, from: cursor)
                spans.append(FileSyntaxHighlightSpan(kind: .comment, range: range))
                cursor = range.upperBound
                continue
            }

            if isStringDelimiter(text[cursor], language: language) {
                let range = quotedStringRange(in: text, from: cursor)
                let kind: FileSyntaxHighlightKind = language.stylesQuotedProperties
                    && isFollowedByColon(after: range.upperBound, in: text)
                    ? .property
                    : .string
                spans.append(FileSyntaxHighlightSpan(kind: kind, range: range))
                cursor = range.upperBound
                continue
            }

            if isNumberStart(in: text, at: cursor) {
                let range = numberRange(in: text, from: cursor)
                spans.append(FileSyntaxHighlightSpan(kind: .number, range: range))
                cursor = range.upperBound
                continue
            }

            if isIdentifierStart(text[cursor]) {
                let range = identifierRange(
                    in: text,
                    from: cursor,
                    allowsHyphen: language.allowsHyphenatedIdentifiers
                )
                let word = String(text[range])
                if language.stylesUnquotedProperties,
                   isFollowedByColon(after: range.upperBound, in: text)
                {
                    spans.append(FileSyntaxHighlightSpan(kind: .property, range: range))
                } else if let kind = tokenKind(
                    for: word,
                    language: language,
                    keywordWords: keywordWords,
                    literalWords: literalWords,
                    typeWords: typeWords
                ) {
                    spans.append(FileSyntaxHighlightSpan(kind: kind, range: range))
                }
                cursor = range.upperBound
                continue
            }

            text.formIndex(after: &cursor)
        }

        return spans
    }

    private static func language(for fileName: String) -> FileSyntaxLanguage? {
        FileSyntaxLanguage(fileName: fileName)
    }

    private static func color(for kind: FileSyntaxHighlightKind) -> Color {
        switch kind {
        case .keyword:
            return Color(nsColor: .systemPurple)
        case .literal, .number:
            return Color(nsColor: .systemOrange)
        case .string:
            return Color(nsColor: .systemGreen)
        case .comment:
            return Color(nsColor: .secondaryLabelColor)
        case .property:
            return Color(nsColor: .systemBlue)
        case .typeName:
            return Color(nsColor: .systemTeal)
        case .tag:
            return Color(nsColor: .systemPink)
        }
    }

    private static func tokenKind(
        for word: String,
        language: FileSyntaxLanguage,
        keywordWords: Set<String>,
        literalWords: Set<String>,
        typeWords: Set<String>
    ) -> FileSyntaxHighlightKind? {
        if literalWords.contains(word) || literalWords.contains(word.lowercased()) {
            return .literal
        }
        if keywordWords.contains(word) || keywordWords.contains(word.lowercased()) {
            return .keyword
        }
        if typeWords.contains(word) || typeWords.contains(word.lowercased()) {
            return .typeName
        }
        if language.highlightsCapitalizedTypes,
           let first = word.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(first)
        {
            return .typeName
        }
        return nil
    }

    private static func isStringDelimiter(
        _ character: Character,
        language: FileSyntaxLanguage
    ) -> Bool {
        character == "\"" || character == "'" || (character == "`" && language.supportsBacktickStrings)
    }

    private static func isLineStart(_ index: String.Index, in text: String) -> Bool {
        index == text.startIndex || text[text.index(before: index)] == "\n"
    }

    private static func lineRange(in text: String, from start: String.Index) -> Range<String.Index> {
        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
        return start..<end
    }

    private static func tagRange(in text: String, from start: String.Index) -> Range<String.Index> {
        var cursor = text.index(after: start)
        while cursor < text.endIndex {
            if text[cursor] == ">" {
                return start..<text.index(after: cursor)
            }
            text.formIndex(after: &cursor)
        }
        return start..<text.endIndex
    }

    private static func rangeUntilTerminator(
        in text: String,
        from start: String.Index,
        openingLength: Int,
        terminator: String
    ) -> Range<String.Index> {
        var cursor = text.index(start, offsetBy: openingLength, limitedBy: text.endIndex)
            ?? text.endIndex
        while cursor < text.endIndex {
            if hasPrefix(terminator, in: text, at: cursor) {
                let end = text.index(cursor, offsetBy: terminator.count, limitedBy: text.endIndex)
                    ?? text.endIndex
                return start..<end
            }
            text.formIndex(after: &cursor)
        }
        return start..<text.endIndex
    }

    private static func quotedStringRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index> {
        let quote = text[start]
        var cursor = text.index(after: start)
        var escaped = false

        while cursor < text.endIndex {
            let character = text[cursor]
            if escaped {
                escaped = false
                text.formIndex(after: &cursor)
                continue
            }
            if character == "\\" {
                escaped = true
                text.formIndex(after: &cursor)
                continue
            }
            if character == quote {
                return start..<text.index(after: cursor)
            }
            if character == "\n", quote != "`" {
                return start..<cursor
            }
            text.formIndex(after: &cursor)
        }

        return start..<text.endIndex
    }

    private static func numberRange(
        in text: String,
        from start: String.Index
    ) -> Range<String.Index> {
        var cursor = start
        if text[cursor] == "-" {
            text.formIndex(after: &cursor)
        }
        while cursor < text.endIndex, isNumberPart(text[cursor]) {
            text.formIndex(after: &cursor)
        }
        return start..<cursor
    }

    private static func identifierRange(
        in text: String,
        from start: String.Index,
        allowsHyphen: Bool
    ) -> Range<String.Index> {
        var cursor = start
        while cursor < text.endIndex,
              isIdentifierPart(text[cursor], allowsHyphen: allowsHyphen)
        {
            text.formIndex(after: &cursor)
        }
        return start..<cursor
    }

    private static func isFollowedByColon(after index: String.Index, in text: String) -> Bool {
        var cursor = index
        while cursor < text.endIndex {
            if text[cursor].isWhitespace {
                text.formIndex(after: &cursor)
                continue
            }
            return text[cursor] == ":"
        }
        return false
    }

    private static func isNumberStart(in text: String, at index: String.Index) -> Bool {
        if isDigit(text[index]) { return true }
        guard text[index] == "-" else { return false }
        let next = text.index(after: index)
        return next < text.endIndex && isDigit(text[next])
    }

    private static func isNumberPart(_ character: Character) -> Bool {
        guard let scalar = character.singleScalar else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return scalar.value == 46 || scalar.value == 95 || scalar.value == 43 || scalar.value == 45
    }

    private static func isDigit(_ character: Character) -> Bool {
        guard let scalar = character.singleScalar else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        guard let scalar = character.singleScalar else { return false }
        return CharacterSet.letters.contains(scalar) || scalar.value == 95 || scalar.value == 36
    }

    private static func isIdentifierPart(
        _ character: Character,
        allowsHyphen: Bool
    ) -> Bool {
        guard let scalar = character.singleScalar else { return false }
        if CharacterSet.alphanumerics.contains(scalar) || scalar.value == 95 || scalar.value == 36 {
            return true
        }
        return allowsHyphen && scalar.value == 45
    }

    private static func hasPrefix(
        _ prefix: String,
        in text: String,
        at index: String.Index
    ) -> Bool {
        text[index...].hasPrefix(prefix)
    }
}

private struct FileSyntaxHighlightSpan {
    let kind: FileSyntaxHighlightKind
    let range: Range<String.Index>
}

private enum FileSyntaxLanguage {
    case swift
    case javascript
    case json
    case markdown
    case yaml
    case shell
    case python
    case ruby
    case go
    case rust
    case cFamily
    case java
    case kotlin
    case html
    case css

    init?(fileName: String) {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension

        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name == "makefile" {
            self = .shell
            return
        }

        switch ext {
        case "swift":
            self = .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            self = .javascript
        case "json":
            self = .json
        case "md", "markdown":
            self = .markdown
        case "yml", "yaml":
            self = .yaml
        case "sh", "bash", "zsh", "fish", "env":
            self = .shell
        case "py", "pyw":
            self = .python
        case "rb":
            self = .ruby
        case "go":
            self = .go
        case "rs":
            self = .rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hxx", "m", "mm":
            self = .cFamily
        case "java":
            self = .java
        case "kt", "kts":
            self = .kotlin
        case "html", "htm", "xml", "svg":
            self = .html
        case "css", "scss", "sass":
            self = .css
        default:
            return nil
        }
    }

    var supportsSlashLineComments: Bool {
        switch self {
        case .swift, .javascript, .rust, .cFamily, .java, .kotlin:
            return true
        case .json, .markdown, .yaml, .shell, .python, .ruby, .go, .html, .css:
            return false
        }
    }

    var supportsHashLineComments: Bool {
        switch self {
        case .markdown, .json, .swift, .javascript, .go, .rust, .cFamily, .java, .kotlin, .html, .css:
            return false
        case .yaml, .shell, .python, .ruby:
            return true
        }
    }

    var supportsBlockComments: Bool {
        switch self {
        case .swift, .javascript, .go, .rust, .cFamily, .java, .kotlin, .css:
            return true
        case .json, .markdown, .yaml, .shell, .python, .ruby, .html:
            return false
        }
    }

    var supportsHTMLComments: Bool {
        switch self {
        case .html, .markdown:
            return true
        case .swift, .javascript, .json, .yaml, .shell, .python, .ruby, .go, .rust,
             .cFamily, .java, .kotlin, .css:
            return false
        }
    }

    var supportsBacktickStrings: Bool {
        switch self {
        case .javascript, .shell, .markdown:
            return true
        case .swift, .json, .yaml, .python, .ruby, .go, .rust, .cFamily, .java,
             .kotlin, .html, .css:
            return false
        }
    }

    var stylesQuotedProperties: Bool {
        self == .json
    }

    var stylesUnquotedProperties: Bool {
        switch self {
        case .yaml, .css:
            return true
        case .swift, .javascript, .json, .markdown, .shell, .python, .ruby, .go, .rust,
             .cFamily, .java, .kotlin, .html:
            return false
        }
    }

    var allowsHyphenatedIdentifiers: Bool {
        switch self {
        case .yaml, .css:
            return true
        case .swift, .javascript, .json, .markdown, .shell, .python, .ruby, .go, .rust,
             .cFamily, .java, .kotlin, .html:
            return false
        }
    }

    var highlightsCapitalizedTypes: Bool {
        switch self {
        case .swift, .java, .kotlin:
            return true
        case .javascript, .json, .markdown, .yaml, .shell, .python, .ruby, .go, .rust,
             .cFamily, .html, .css:
            return false
        }
    }

    var highlightsTags: Bool {
        self == .html
    }

    var keywordWords: Set<String> {
        switch self {
        case .swift:
            return [
                "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
                "break", "case", "catch", "class", "consuming", "continue", "default",
                "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
                "inout", "internal", "is", "let", "nonisolated", "open", "operator",
                "private", "protocol", "public", "repeat", "rethrows", "return",
                "sending", "some", "static", "struct", "subscript", "switch", "throw",
                "throws", "try", "typealias", "var", "where", "while",
            ]
        case .javascript:
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends",
                "finally", "for", "from", "function", "if", "import", "in", "instanceof",
                "interface", "let", "new", "of", "return", "switch", "throw", "try",
                "type", "typeof", "var", "void", "while", "yield",
            ]
        case .json:
            return []
        case .markdown:
            return []
        case .yaml:
            return []
        case .shell:
            return [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for",
                "function", "if", "in", "local", "readonly", "return", "set", "shift",
                "then", "until", "while",
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from",
                "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                "or", "pass", "raise", "return", "try", "while", "with", "yield",
            ]
        case .ruby:
            return [
                "begin", "break", "case", "class", "def", "defined", "do", "else",
                "elsif", "end", "ensure", "for", "if", "in", "module", "next", "redo",
                "rescue", "retry", "return", "then", "unless", "until", "when", "while",
                "yield",
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                "map", "package", "range", "return", "select", "struct", "switch", "type",
                "var",
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
                "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
                "where", "while",
            ]
        case .cFamily:
            return [
                "auto", "break", "case", "class", "const", "continue", "default", "do",
                "else", "enum", "extern", "for", "goto", "if", "namespace", "private",
                "protected", "public", "return", "sizeof", "static", "struct", "switch",
                "template", "typedef", "typename", "union", "using", "virtual", "void",
                "while",
            ]
        case .java, .kotlin:
            return [
                "abstract", "break", "case", "catch", "class", "continue", "data",
                "default", "do", "else", "enum", "extends", "final", "finally", "for",
                "fun", "if", "implements", "import", "in", "interface", "new", "object",
                "override", "package", "private", "protected", "public", "return", "sealed",
                "static", "super", "switch", "this", "throw", "throws", "try", "val",
                "var", "when", "while",
            ]
        case .html:
            return []
        case .css:
            return [
                "important", "media", "supports", "keyframes", "from", "to",
            ]
        }
    }

    var literalWords: Set<String> {
        switch self {
        case .swift:
            return ["false", "nil", "self", "Self", "super", "true"]
        case .javascript:
            return ["false", "null", "this", "true", "undefined"]
        case .json:
            return ["false", "null", "true"]
        case .markdown, .yaml:
            return ["false", "null", "true"]
        case .shell:
            return ["false", "true"]
        case .python:
            return ["False", "None", "True", "self"]
        case .ruby:
            return ["false", "nil", "self", "true"]
        case .go:
            return ["false", "iota", "nil", "true"]
        case .rust:
            return ["false", "None", "Some", "true"]
        case .cFamily:
            return ["false", "nullptr", "NULL", "true"]
        case .java, .kotlin:
            return ["false", "null", "this", "true"]
        case .html, .css:
            return []
        }
    }

    var typeWords: Set<String> {
        switch self {
        case .swift:
            return [
                "Any", "Array", "Bool", "Character", "Dictionary", "Double", "Float",
                "Int", "Never", "Optional", "Set", "String", "UInt", "Void",
            ]
        case .javascript, .json, .markdown, .yaml, .shell, .python, .ruby, .html, .css:
            return []
        case .go:
            return ["bool", "byte", "complex64", "complex128", "error", "float32", "float64",
                    "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
                    "uint8", "uint16", "uint32", "uint64", "uintptr"]
        case .rust:
            return ["bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128",
                    "isize", "str", "String", "u8", "u16", "u32", "u64", "u128",
                    "usize"]
        case .cFamily:
            return ["bool", "char", "double", "float", "int", "long", "short", "signed",
                    "unsigned"]
        case .java, .kotlin:
            return ["Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Short",
                    "String", "Unit", "Void", "boolean", "byte", "char", "double",
                    "float", "int", "long", "short", "void"]
        }
    }
}

private extension Character {
    var singleScalar: UnicodeScalar? {
        unicodeScalars.count == 1 ? unicodeScalars.first : nil
    }
}
