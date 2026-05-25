import Foundation

@main
struct GitDiffStatParserTests {
    static func main() {
        parsesTextBinaryAndRenamedStats()
    }

    private static func parsesTextBinaryAndRenamedStats() {
        let output = """
12	3	Sources/App.swift
-	-	Assets/logo.png
1	2	old name.txt => new name.txt
"""

        let stats = GitDiffStatParser.parse(output)

        assertEqual(stats["Sources/App.swift"], GitDiffStat(additions: 12, deletions: 3, isBinary: false), "text stats parse")
        assertEqual(stats["Assets/logo.png"], GitDiffStat(additions: nil, deletions: nil, isBinary: true), "binary stats parse")
        assertEqual(stats["new name.txt"], GitDiffStat(additions: 1, deletions: 2, isBinary: false), "renamed path stats parse by destination")
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(String(describing: expected)), got \(String(describing: actual))\n", stderr)
            exit(1)
        }
    }
}
