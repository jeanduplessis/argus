import Foundation

struct ArgusDiffInput: Codable, Sendable, Equatable {
    let oldFile: ArgusDiffFile
    let newFile: ArgusDiffFile
    let options: ArgusDiffOptions
}

struct ArgusDiffFile: Codable, Sendable, Equatable {
    let name: String
    let contents: String
    let language: String?

    init(name: String, contents: String, language: String? = nil) {
        self.name = name
        self.contents = contents
        self.language = language
    }
}

struct ArgusDiffOptions: Codable, Sendable, Equatable {
    let theme: ArgusDiffTheme
    let style: ArgusDiffStyle
    let overflow: ArgusDiffOverflow
}

enum ArgusDiffTheme: String, Codable, Sendable {
    case light
    case dark
}

enum ArgusDiffStyle: String, Codable, Sendable {
    case split
    case unified
}

enum ArgusDiffOverflow: String, Codable, Sendable {
    case scroll
    case wrap
}
