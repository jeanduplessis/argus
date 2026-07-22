import Foundation
import Testing

@testable import Argus

@Suite
struct RandomBranchNameGeneratorTests {
    @Test
    func coveredBehaviors() {
        for _ in 0..<50 {
            let name = RandomBranchNameGenerator.generate()
            assertTrue(isValidTwoWordName(name), "generated name '\(name)' is two lowercase words joined by a hyphen")
        }

        assertTrue(
            isValidTwoWordName(RandomBranchNameGenerator.generate(prefix: "   ")),
            "a blank prefix is equivalent to no prefix and produces a bare two-word name"
        )
        assertTrue(
            !RandomBranchNameGenerator.generate(prefix: "").contains("/"),
            "an empty prefix produces a bare two-word name with no slash"
        )

        let prefixed = RandomBranchNameGenerator.generate(prefix: "eshurakov")
        assertTrue(prefixed.hasPrefix("eshurakov/"), "prefix is joined with a single slash")
        assertTrue(
            isValidTwoWordName(String(prefixed.dropFirst("eshurakov/".count))),
            "the suffix after the prefix is still a valid two-word name"
        )

        let trailingSlashPrefixed = RandomBranchNameGenerator.generate(prefix: "eshurakov/")
        assertTrue(
            trailingSlashPrefixed.hasPrefix("eshurakov/") && !trailingSlashPrefixed.hasPrefix("eshurakov//"),
            "a prefix with a trailing slash is not double-slashed"
        )

        let variations = Set((0..<20).map { _ in RandomBranchNameGenerator.generate() })
        assertTrue(variations.count > 1, "repeated calls produce varied names rather than a constant one")

        assertTrue(
            RandomBranchNameGenerator.combinationCount >= 10_000,
            "the word lists are large enough that random collisions stay rare"
        )
    }

    private func isValidTwoWordName(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLowercase && $0.isLetter }
        }
    }

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }
}
