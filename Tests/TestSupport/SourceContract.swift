import Foundation
import Testing

struct SourceContract {
  private let text: String

  init(_ relativePath: String, filePath: String = #filePath) throws {
    let testsDirectory = URL(fileURLWithPath: filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let repositoryRoot = testsDirectory.deletingLastPathComponent()
    text = try String(
      contentsOf: repositoryRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
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
