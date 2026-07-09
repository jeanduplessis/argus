// ContentAreaView+SyntaxHighlighter.swift
// Argus

import SwiftUI

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
}

extension FileSyntaxHighlighter {
    private static func spans(in text: String, fileName: String) -> [FileSyntaxHighlightSpan] {
        guard let language = language(for: fileName) else { return [] }

        var spans: [FileSyntaxHighlightSpan] = []
        var cursor = text.startIndex
        let context = FileSyntaxScanContext(language: language)

        while cursor < text.endIndex {
            if let span = nextSpan(in: text, at: cursor, context: context) {
                spans.append(span)
                cursor = span.range.upperBound
            } else {
                text.formIndex(after: &cursor)
            }
        }

        return spans
    }

    private static func nextSpan(
        in text: String,
        at index: String.Index,
        context: FileSyntaxScanContext
    ) -> FileSyntaxHighlightSpan? {
        if let span = markupSpan(in: text, at: index, language: context.language) {
            return span
        }
        if let span = commentSpan(in: text, at: index, language: context.language) {
            return span
        }
        if let span = valueSpan(in: text, at: index, language: context.language) {
            return span
        }
        return identifierSpan(in: text, at: index, context: context)
    }

    private static func markupSpan(
        in text: String,
        at index: String.Index,
        language: FileSyntaxLanguage
    ) -> FileSyntaxHighlightSpan? {
        if language == .markdown, isLineStart(index, in: text), text[index] == "#" {
            return FileSyntaxHighlightSpan(kind: .keyword, range: lineRange(in: text, from: index))
        }
        if language.highlightsTags, text[index] == "<" {
            return FileSyntaxHighlightSpan(kind: .tag, range: tagRange(in: text, from: index))
        }
        return nil
    }

    private static func commentSpan(
        in text: String,
        at index: String.Index,
        language: FileSyntaxLanguage
    ) -> FileSyntaxHighlightSpan? {
        if language.supportsHTMLComments, hasPrefix("<!--", in: text, at: index) {
            let range = rangeUntilTerminator(
                in: text,
                from: index,
                openingLength: 4,
                terminator: "-->"
            )
            return FileSyntaxHighlightSpan(kind: .comment, range: range)
        }
        if language.supportsSlashLineComments, hasPrefix("//", in: text, at: index) {
            return FileSyntaxHighlightSpan(kind: .comment, range: lineRange(in: text, from: index))
        }
        if language.supportsBlockComments, hasPrefix("/*", in: text, at: index) {
            let range = rangeUntilTerminator(
                in: text,
                from: index,
                openingLength: 2,
                terminator: "*/"
            )
            return FileSyntaxHighlightSpan(kind: .comment, range: range)
        }
        if language.supportsHashLineComments, text[index] == "#" {
            return FileSyntaxHighlightSpan(kind: .comment, range: lineRange(in: text, from: index))
        }
        return nil
    }

    private static func valueSpan(
        in text: String,
        at index: String.Index,
        language: FileSyntaxLanguage
    ) -> FileSyntaxHighlightSpan? {
        if isStringDelimiter(text[index], language: language) {
            let range = quotedStringRange(in: text, from: index)
            let kind: FileSyntaxHighlightKind =
                language.stylesQuotedProperties && isFollowedByColon(after: range.upperBound, in: text)
                ? .property
                : .string
            return FileSyntaxHighlightSpan(kind: kind, range: range)
        }
        if isNumberStart(in: text, at: index) {
            return FileSyntaxHighlightSpan(kind: .number, range: numberRange(in: text, from: index))
        }
        return nil
    }

    private static func identifierSpan(
        in text: String,
        at index: String.Index,
        context: FileSyntaxScanContext
    ) -> FileSyntaxHighlightSpan? {
        guard isIdentifierStart(text[index]) else { return nil }
        let range = identifierRange(
            in: text,
            from: index,
            allowsHyphen: context.language.allowsHyphenatedIdentifiers
        )
        if context.language.stylesUnquotedProperties,
            isFollowedByColon(after: range.upperBound, in: text)
        {
            return FileSyntaxHighlightSpan(kind: .property, range: range)
        }
        guard
            let kind = tokenKind(
                for: String(text[range]),
                language: context.language,
                keywordWords: context.keywordWords,
                literalWords: context.literalWords,
                typeWords: context.typeWords
            )
        else { return nil }
        return FileSyntaxHighlightSpan(kind: kind, range: range)
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
        var cursor =
            text.index(start, offsetBy: openingLength, limitedBy: text.endIndex)
            ?? text.endIndex
        while cursor < text.endIndex {
            if hasPrefix(terminator, in: text, at: cursor) {
                let end =
                    text.index(cursor, offsetBy: terminator.count, limitedBy: text.endIndex)
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
