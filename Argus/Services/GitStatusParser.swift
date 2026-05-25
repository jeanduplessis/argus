import Foundation

struct GitStatusPorcelainParser: Sendable {
    static func parse(_ output: String, rootPath: String) -> GitStatusSummary {
        var branchName: String?
        var upstreamName: String?
        var aheadCount = 0
        var behindCount = 0
        var stagedFiles: [GitFileChange] = []
        var unstagedFiles: [GitFileChange] = []
        var untrackedFiles: [GitFileChange] = []

        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                branchName = value == "(detached)" ? nil : value
            } else if line.hasPrefix("# branch.upstream ") {
                upstreamName = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+") {
                        aheadCount = Int(part.dropFirst()) ?? 0
                    } else if part.hasPrefix("-") {
                        behindCount = Int(part.dropFirst()) ?? 0
                    }
                }
            } else if line.hasPrefix("? ") {
                let path = String(line.dropFirst(2))
                untrackedFiles.append(GitFileChange(path: path, status: .untracked, sectionKey: "untracked"))
            } else if line.hasPrefix("1 ") {
                appendOrdinaryChange(line, stagedFiles: &stagedFiles, unstagedFiles: &unstagedFiles)
            } else if line.hasPrefix("2 ") {
                appendRenamedOrCopiedChange(line, stagedFiles: &stagedFiles, unstagedFiles: &unstagedFiles)
            } else if line.hasPrefix("u ") {
                if let path = pathFromUnmergedLine(line) {
                    unstagedFiles.append(GitFileChange(path: path, status: .unmerged, sectionKey: "unstaged"))
                }
            }
        }

        return cappedSummary(
            rootPath: rootPath,
            branchName: branchName,
            upstreamName: upstreamName,
            aheadCount: aheadCount,
            behindCount: behindCount,
            stagedFiles: stagedFiles,
            unstagedFiles: unstagedFiles,
            untrackedFiles: untrackedFiles
        )
    }

    private static func appendOrdinaryChange(
        _ line: String,
        stagedFiles: inout [GitFileChange],
        unstagedFiles: inout [GitFileChange]
    ) {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return }
        appendChanges(
            xy: String(fields[1]),
            path: String(fields[8]),
            originalPath: nil,
            stagedFiles: &stagedFiles,
            unstagedFiles: &unstagedFiles
        )
    }

    private static func appendRenamedOrCopiedChange(
        _ line: String,
        stagedFiles: inout [GitFileChange],
        unstagedFiles: inout [GitFileChange]
    ) {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: true)
        guard fields.count >= 10 else { return }
        let paths = String(fields[9]).components(separatedBy: "\t")
        appendChanges(
            xy: String(fields[1]),
            path: paths.first ?? String(fields[9]),
            originalPath: paths.dropFirst().first,
            stagedFiles: &stagedFiles,
            unstagedFiles: &unstagedFiles
        )
    }

    private static func pathFromUnmergedLine(_ line: String) -> String? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
        return fields.last.map(String.init)
    }

    private static func appendChanges(
        xy: String,
        path: String,
        originalPath: String?,
        stagedFiles: inout [GitFileChange],
        unstagedFiles: inout [GitFileChange]
    ) {
        let characters = Array(xy)
        guard characters.count >= 2 else { return }
        if characters[0] != "." {
            stagedFiles.append(GitFileChange(
                path: path,
                originalPath: originalPath,
                status: status(for: characters[0]),
                sectionKey: "staged"
            ))
        }
        if characters[1] != "." {
            unstagedFiles.append(GitFileChange(
                path: path,
                originalPath: originalPath,
                status: status(for: characters[1]),
                sectionKey: "unstaged"
            ))
        }
    }

    private static func status(for code: Character) -> GitFileStatus {
        switch code {
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .unmerged
        default: return .modified
        }
    }

    private static func cappedSummary(
        rootPath: String,
        branchName: String?,
        upstreamName: String?,
        aheadCount: Int,
        behindCount: Int,
        stagedFiles: [GitFileChange],
        unstagedFiles: [GitFileChange],
        untrackedFiles: [GitFileChange]
    ) -> GitStatusSummary {
        let total = stagedFiles.count + unstagedFiles.count + untrackedFiles.count
        var remaining = GitStatusSummary.displayFileLimit
        let cappedStaged = Array(stagedFiles.prefix(remaining))
        remaining -= cappedStaged.count
        let cappedUnstaged = Array(unstagedFiles.prefix(max(remaining, 0)))
        remaining -= cappedUnstaged.count
        let cappedUntracked = Array(untrackedFiles.prefix(max(remaining, 0)))

        return GitStatusSummary(
            rootPath: rootPath,
            branchName: branchName,
            upstreamName: upstreamName,
            aheadCount: aheadCount,
            behindCount: behindCount,
            stagedCount: stagedFiles.count,
            unstagedCount: unstagedFiles.count,
            untrackedCount: untrackedFiles.count,
            stagedFiles: cappedStaged,
            unstagedFiles: cappedUnstaged,
            untrackedFiles: cappedUntracked,
            isFileDisplayCapped: total > GitStatusSummary.displayFileLimit,
            totalFileCount: total
        )
    }
}
