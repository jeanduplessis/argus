import Foundation
import Testing

@testable import Argus

@Suite
struct GitStatusParserTests {
  @Test
  func coveredBehaviors() throws {
    parsesBranchMetadataForCleanRepository()
    parsesChangedFilesIntoSections()
    parsesRenamedAndCopiedFilesWithOriginalPaths()
    parsesTypeChangedFiles()
    parsesUnmergedFilesWithPathSpaces()
    capsDisplayedFileRowsAtLimit()
  }

  private func parsesBranchMetadataForCleanRepository() {
    let output = """
      # branch.oid 0123456789abcdef
      # branch.head feature/git-sidebar
      # branch.upstream origin/feature/git-sidebar
      # branch.ab +3 -2
      """

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(status.rootPath, "/tmp/repo", "root path is preserved")
    assertEqual(status.branchName, "feature/git-sidebar", "branch name parses")
    assertEqual(status.upstreamName, "origin/feature/git-sidebar", "upstream name parses")
    assertEqual(status.aheadCount, 3, "ahead count parses")
    assertEqual(status.behindCount, 2, "behind count parses")
    assertEqual(status.stagedCount, 0, "clean repo has no staged files")
    assertEqual(status.unstagedCount, 0, "clean repo has no unstaged files")
    assertEqual(status.untrackedCount, 0, "clean repo has no untracked files")
    assertEqual(status.isClean, true, "clean repo is clean")
  }

  private func parsesChangedFilesIntoSections() {
    let output = """
      # branch.head main
      1 M. N... 100644 100644 100644 aaaaaa bbbbbb staged.txt
      1 .M N... 100644 100644 100644 aaaaaa bbbbbb unstaged.txt
      1 D. N... 100644 000000 000000 aaaaaa 000000 deleted.txt
      ? new file.txt
      """

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(
      status.stagedFiles.map(\.path), ["staged.txt", "deleted.txt"], "staged paths parse")
    assertEqual(status.unstagedFiles.map(\.path), ["unstaged.txt"], "unstaged paths parse")
    assertEqual(status.untrackedFiles.map(\.path), ["new file.txt"], "untracked paths parse")
    assertEqual(status.stagedFiles.first?.status, .modified, "staged status parses")
    assertEqual(status.stagedFiles.last?.status, .deleted, "deleted status parses")
    assertEqual(status.untrackedFiles.first?.status, .untracked, "untracked status parses")
    assertEqual(status.isClean, false, "changed repo is dirty")
  }

  private func parsesRenamedAndCopiedFilesWithOriginalPaths() {
    let output = """
      # branch.head main
      2 R. N... 100644 100644 100644 aaaaaa bbbbbb R100 renamed folder/new file.txt	old folder/old file.txt
      2 C. N... 100644 100644 100644 aaaaaa bbbbbb C75 copied file.txt	template file.txt
      2 RM N... 100644 100644 100644 aaaaaa bbbbbb R86 moved and edited.txt	old edited.txt
      """

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(
      status.stagedFiles.map(\.path),
      ["renamed folder/new file.txt", "copied file.txt", "moved and edited.txt"],
      "renamed and copied staged paths parse")
    assertEqual(
      status.stagedFiles.map(\.originalPath),
      ["old folder/old file.txt", "template file.txt", "old edited.txt"],
      "renamed and copied original paths parse")
    assertEqual(
      status.stagedFiles.map(\.status), [.renamed, .copied, .renamed],
      "renamed and copied staged statuses parse")
    assertEqual(
      status.unstagedFiles.map(\.path), ["moved and edited.txt"],
      "renamed file with worktree edits appears in unstaged section")
    assertEqual(
      status.unstagedFiles.first?.originalPath, "old edited.txt",
      "unstaged rename companion preserves original path")
    assertEqual(
      status.unstagedFiles.first?.status, .modified, "unstaged rename companion status parses")
  }

  private func parsesTypeChangedFiles() {
    let output = """
      # branch.head main
      1 T. N... 100644 120000 120000 aaaaaa bbbbbb staged-symlink
      1 .T N... 100644 100644 120000 aaaaaa bbbbbb unstaged-symlink
      """

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(
      status.stagedFiles,
      [
        GitFileChange(path: "staged-symlink", status: .typeChanged, sectionKey: "staged")
      ], "staged type-changed file parses")
    assertEqual(
      status.unstagedFiles,
      [
        GitFileChange(path: "unstaged-symlink", status: .typeChanged, sectionKey: "unstaged")
      ], "unstaged type-changed file parses")
  }

  private func parsesUnmergedFilesWithPathSpaces() {
    let output = """
      # branch.head feature/conflict
      u UU N... 100644 100644 100644 100644 aaaaaa bbbbbb cccccc conflict folder/file with spaces.txt
      """

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(status.stagedFiles.isEmpty, true, "unmerged file is not treated as staged")
    assertEqual(
      status.unstagedFiles,
      [
        GitFileChange(
          path: "conflict folder/file with spaces.txt", status: .unmerged, sectionKey: "unstaged")
      ], "unmerged path with spaces parses")
  }

  private func capsDisplayedFileRowsAtLimit() {
    let output = (0..<501)
      .map { "? file-\($0).txt" }
      .joined(separator: "\n")

    let status = GitStatusPorcelainParser.parse(output, rootPath: "/tmp/repo")

    assertEqual(status.untrackedCount, 501, "total untracked count is preserved")
    assertEqual(
      status.untrackedFiles.count, GitStatusSummary.displayFileLimit, "display rows are capped")
    assertEqual(status.isFileDisplayCapped, true, "capped flag is set")
    assertEqual(status.totalFileCount, 501, "total file count is preserved")
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}
