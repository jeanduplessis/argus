import AppKit

enum WorkspaceNotesHighlightKind: Equatable, Sendable {
    case heading
    case bold
    case italic
    case inlineCode
    case codeBlock
    case link
    case listMarker
    case blockquote
}

struct WorkspaceNotesHighlightSpan: Equatable, Sendable {
    let kind: WorkspaceNotesHighlightKind
    /// UTF-16 range in the highlighted text, matching `NSTextStorage` indexing.
    let range: NSRange
}

/// Live Markdown syntax highlighting for Workspace Notes. It only colors and
/// styles the plain text; it never renders or rewrites Markdown.
enum WorkspaceNotesHighlighter {
    /// Returns highlight spans ordered by line, with line-level spans before inline spans.
    static func spans(in text: String) -> [WorkspaceNotesHighlightSpan] {
        let string = text as NSString
        var spans: [WorkspaceNotesHighlightSpan] = []
        var openFenceStart: Int?
        var location = 0

        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = contentRange(of: lineRange, in: string)
            let isFence = matches(fencePattern, in: text, range: contentRange)

            if let fenceStart = openFenceStart {
                if isFence {
                    spans.append(
                        WorkspaceNotesHighlightSpan(
                            kind: .codeBlock,
                            range: NSRange(location: fenceStart, length: NSMaxRange(contentRange) - fenceStart)
                        ))
                    openFenceStart = nil
                }
            } else if isFence {
                openFenceStart = contentRange.location
            } else {
                spans += lineSpans(in: text, contentRange: contentRange)
                spans += inlineSpans(in: text, contentRange: contentRange)
            }
            location = NSMaxRange(lineRange)
        }

        if let fenceStart = openFenceStart {
            spans.append(
                WorkspaceNotesHighlightSpan(
                    kind: .codeBlock,
                    range: NSRange(location: fenceStart, length: string.length - fenceStart)
                ))
        }
        return spans
    }

    /// Replaces every attribute in `textStorage` with base attributes and highlight styling.
    static func apply(to textStorage: NSTextStorage, baseFont: NSFont) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.setAttributes([.font: baseFont, .foregroundColor: NSColor.labelColor], range: fullRange)
        for span in spans(in: textStorage.string) {
            style(span, in: textStorage)
        }
        textStorage.endEditing()
    }
}

extension WorkspaceNotesHighlighter {
    private static let fencePattern = pattern("^ {0,3}(```|~~~)")
    private static let headingPattern = pattern("^ {0,3}#{1,6}(?:[ \\t].*)?$")
    private static let blockquotePattern = pattern("^ {0,3}>.*$")
    private static let listMarkerPattern = pattern("^[ \\t]*(?:[-*+]|\\d{1,9}[.)])(?=[ \\t])")
    private static let inlineCodePattern = pattern("`[^`]+`")
    private static let boldPattern = pattern("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicPattern = pattern(
        "(?<![*\\w])\\*(?![*\\s])(.+?)(?<![*\\s])\\*(?![*\\w])|(?<![_\\w])_(?![_\\s])(.+?)(?<![_\\s])_(?![_\\w])"
    )
    private static let linkPattern = pattern("\\[[^\\]]+\\]\\([^)\\s]+(?:\\s+\"[^\"]*\")?\\)|<https?://[^>\\s]+>")

    private static func pattern(_ source: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: source)
        } catch {
            preconditionFailure("Invalid Workspace Notes highlight pattern \(source): \(error)")
        }
    }

    private static func contentRange(of lineRange: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = string.character(at: end - 1)
            guard character == 0x0A || character == 0x0D else { break }
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String, range: NSRange) -> Bool {
        pattern.firstMatch(in: text, range: range) != nil
    }

    private static func lineSpans(in text: String, contentRange: NSRange) -> [WorkspaceNotesHighlightSpan] {
        if matches(headingPattern, in: text, range: contentRange) {
            return [WorkspaceNotesHighlightSpan(kind: .heading, range: contentRange)]
        }
        if matches(blockquotePattern, in: text, range: contentRange) {
            return [WorkspaceNotesHighlightSpan(kind: .blockquote, range: contentRange)]
        }
        if let marker = listMarkerPattern.firstMatch(in: text, range: contentRange) {
            return [WorkspaceNotesHighlightSpan(kind: .listMarker, range: marker.range)]
        }
        return []
    }

    private static func inlineSpans(in text: String, contentRange: NSRange) -> [WorkspaceNotesHighlightSpan] {
        let codeRanges = inlineCodePattern.matches(in: text, range: contentRange).map(\.range)
        var spans = codeRanges.map { WorkspaceNotesHighlightSpan(kind: .inlineCode, range: $0) }
        for (kind, pattern) in [
            (WorkspaceNotesHighlightKind.link, linkPattern), (.bold, boldPattern), (.italic, italicPattern)
        ] {
            for match in pattern.matches(in: text, range: contentRange)
            where !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                spans.append(WorkspaceNotesHighlightSpan(kind: kind, range: match.range))
            }
        }
        return spans
    }

    private static func style(_ span: WorkspaceNotesHighlightSpan, in textStorage: NSTextStorage) {
        switch span.kind {
        case .heading:
            addTrait(.boldFontMask, range: span.range, in: textStorage)
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: span.range)
        case .bold:
            addTrait(.boldFontMask, range: span.range, in: textStorage)
        case .italic:
            addTrait(.italicFontMask, range: span.range, in: textStorage)
        case .inlineCode, .codeBlock:
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: span.range)
        case .link:
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: span.range)
        case .listMarker:
            textStorage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: span.range)
        case .blockquote:
            textStorage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
        }
    }

    private static func addTrait(_ trait: NSFontTraitMask, range: NSRange, in textStorage: NSTextStorage) {
        let fontManager = NSFontManager.shared
        textStorage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            let converted = fontManager.convert(font, toHaveTrait: trait)
            textStorage.addAttribute(.font, value: converted, range: subrange)
            // Monospaced system fonts may lack an italic face; slant the glyphs instead.
            if trait == .italicFontMask, !fontManager.traits(of: converted).contains(.italicFontMask) {
                textStorage.addAttribute(.obliqueness, value: 0.2, range: subrange)
            }
        }
    }
}
