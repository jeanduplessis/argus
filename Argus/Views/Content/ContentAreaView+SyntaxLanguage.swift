// ContentAreaView+SyntaxLanguage.swift
// Argus

import Foundation

struct FileSyntaxScanContext {
    let language: FileSyntaxLanguage
    let keywordWords: Set<String>
    let literalWords: Set<String>
    let typeWords: Set<String>

    init(language: FileSyntaxLanguage) {
        self.language = language
        keywordWords = language.keywordWords
        literalWords = language.literalWords
        typeWords = language.typeWords
    }
}

enum FileSyntaxLanguage {
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

    private static let fileExtensionMap: [String: FileSyntaxLanguage] = [
        "swift": .swift,
        "js": .javascript,
        "jsx": .javascript,
        "mjs": .javascript,
        "cjs": .javascript,
        "ts": .javascript,
        "tsx": .javascript,
        "json": .json,
        "md": .markdown,
        "markdown": .markdown,
        "yml": .yaml,
        "yaml": .yaml,
        "sh": .shell,
        "bash": .shell,
        "zsh": .shell,
        "fish": .shell,
        "env": .shell,
        "py": .python,
        "pyw": .python,
        "rb": .ruby,
        "go": .go,
        "rs": .rust,
        "c": .cFamily,
        "h": .cFamily,
        "cc": .cFamily,
        "cpp": .cFamily,
        "cxx": .cFamily,
        "hpp": .cFamily,
        "hxx": .cFamily,
        "m": .cFamily,
        "mm": .cFamily,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "html": .html,
        "htm": .html,
        "xml": .html,
        "svg": .html,
        "css": .css,
        "scss": .css,
        "sass": .css
    ]

    init?(fileName: String) {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension

        if name == "dockerfile" || name.hasPrefix("dockerfile.") || name == "makefile" {
            self = .shell
            return
        }

        guard let language = Self.fileExtensionMap[ext] else { return nil }
        self = language
    }
}

extension FileSyntaxLanguage {
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
                "throws", "try", "typealias", "var", "where", "while"
            ]
        case .javascript:
            return [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends",
                "finally", "for", "from", "function", "if", "import", "in", "instanceof",
                "interface", "let", "new", "of", "return", "switch", "throw", "try",
                "type", "typeof", "var", "void", "while", "yield"
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
                "then", "until", "while"
            ]
        case .python:
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from",
                "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                "or", "pass", "raise", "return", "try", "while", "with", "yield"
            ]
        case .ruby:
            return [
                "begin", "break", "case", "class", "def", "defined", "do", "else",
                "elsif", "end", "ensure", "for", "if", "in", "module", "next", "redo",
                "rescue", "retry", "return", "then", "unless", "until", "when", "while",
                "yield"
            ]
        case .go:
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                "map", "package", "range", "return", "select", "struct", "switch", "type",
                "var"
            ]
        case .rust:
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
                "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
                "where", "while"
            ]
        case .cFamily:
            return [
                "auto", "break", "case", "class", "const", "continue", "default", "do",
                "else", "enum", "extern", "for", "goto", "if", "namespace", "private",
                "protected", "public", "return", "sizeof", "static", "struct", "switch",
                "template", "typedef", "typename", "union", "using", "virtual", "void",
                "while"
            ]
        case .java, .kotlin:
            return [
                "abstract", "break", "case", "catch", "class", "continue", "data",
                "default", "do", "else", "enum", "extends", "final", "finally", "for",
                "fun", "if", "implements", "import", "in", "interface", "new", "object",
                "override", "package", "private", "protected", "public", "return", "sealed",
                "static", "super", "switch", "this", "throw", "throws", "try", "val",
                "var", "when", "while"
            ]
        case .html:
            return []
        case .css:
            return [
                "important", "media", "supports", "keyframes", "from", "to"
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
                "Int", "Never", "Optional", "Set", "String", "UInt", "Void"
            ]
        case .javascript, .json, .markdown, .yaml, .shell, .python, .ruby, .html, .css:
            return []
        case .go:
            return [
                "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
                "int", "int8", "int16", "int32", "int64", "rune", "string", "uint",
                "uint8", "uint16", "uint32", "uint64", "uintptr"
            ]
        case .rust:
            return [
                "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128",
                "isize", "str", "String", "u8", "u16", "u32", "u64", "u128",
                "usize"
            ]
        case .cFamily:
            return [
                "bool", "char", "double", "float", "int", "long", "short", "signed",
                "unsigned"
            ]
        case .java, .kotlin:
            return [
                "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long", "Short",
                "String", "Unit", "Void", "boolean", "byte", "char", "double",
                "float", "int", "long", "short", "void"
            ]
        }
    }
}

extension Character {
    var singleScalar: UnicodeScalar? {
        unicodeScalars.count == 1 ? unicodeScalars.first : nil
    }
}
