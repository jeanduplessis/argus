import Foundation
import Testing

struct SourceContract {
    private let text: String

    init(_ relativePath: String, filePath: String = #filePath) throws {
        let testsDirectory = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(relativePath)
        let companionURLs = try Self.companionURLs(for: sourceURL)
        text = try ([sourceURL] + companionURLs)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private static func companionURLs(for sourceURL: URL) throws -> [URL] {
        guard sourceURL.pathExtension == "swift" else { return [] }
        let stem = sourceURL.deletingPathExtension().lastPathComponent
        return try FileManager.default
            .contentsOfDirectory(
                at: sourceURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
            .filter {
                $0.pathExtension == "swift"
                    && $0.lastPathComponent.hasPrefix("\(stem)+")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func contains(_ fragment: String, _ message: String) {
        #expect(text.contains(fragment), Comment(rawValue: message))
    }

    func containsAll(_ fragments: [String], _ message: String) {
        for fragment in fragments {
            #expect(
                text.contains(fragment),
                Comment(rawValue: "\(message): missing \(fragment)")
            )
        }
    }

    func excludes(_ fragment: String, _ message: String) {
        #expect(!text.contains(fragment), Comment(rawValue: message))
    }

    func section(after start: String, before end: String) throws -> String {
        let startRange = try #require(text.range(of: start))
        let remainder = text[startRange.upperBound...]
        let endRange = try #require(remainder.range(of: end))
        return String(remainder[..<endRange.lowerBound])
    }
}
