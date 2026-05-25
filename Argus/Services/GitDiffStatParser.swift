import Foundation

struct GitDiffStatParser: Sendable {
    static func parse(_ output: String) -> [String: GitDiffStat] {
        var stats: [String: GitDiffStat] = [:]

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }

            let path = normalizedPath(String(fields[2]))
            let additions = Int(fields[0])
            let deletions = Int(fields[1])
            let isBinary = fields[0] == "-" || fields[1] == "-"

            stats[path] = GitDiffStat(
                additions: additions,
                deletions: deletions,
                isBinary: isBinary
            )
        }

        return stats
    }

    private static func normalizedPath(_ path: String) -> String {
        if let range = path.range(of: " => ") {
            return String(path[range.upperBound...])
        }
        return path
    }
}
