import Foundation
import Testing

@testable import Argus

@Suite
struct GitPreviewServiceTests {
  @Test
  func coveredBehaviors() async throws {
    selectsDiffCommandsForFileSections()
    usesDifftasticForDiffOnlyWhenAvailable()
    selectsBlameCommandOnlyForTrackedRows()
    try await runsDiffPreviewWithColorizedOutput()
    try await runsBlamePreviewWithColorizedOutput()
    await reportsPreviewCommandFailureWithoutThrowing()
  }

  private func runsBlamePreviewWithColorizedOutput() async throws {
    let repo = try TemporaryDirectory(prefix: "argus-git-preview-blame")
    defer { repo.remove() }
    try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
    try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
    try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
    let fileURL = repo.url.appendingPathComponent("file.txt")
    try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
    try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
    try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)

    let service = GitPreviewService(
      commandBuilder: GitPreviewCommandBuilder(difftasticPathProvider: { nil }))
    let result = await service.preview(
      kind: .blame, rootPath: repo.url.path,
      file: GitFileChange(path: "file.txt", status: .modified, sectionKey: "unstaged"))

    guard case .loaded(let preview) = result else {
      fail("expected loaded blame preview, got \(result)")
    }
    assertEqual(preview.kind, .blame, "loaded preview keeps blame kind")
    assertEqual(
      preview.output.contains("Argus Test"), true, "blame output includes git blame content")
    assertEqual(preview.output.contains("\u{001B}["), true, "blame output is colorized")
  }

  private func reportsPreviewCommandFailureWithoutThrowing() async {
    let service = GitPreviewService(
      commandBuilder: GitPreviewCommandBuilder(difftasticPathProvider: { nil }))

    let result = await service.preview(
      kind: .blame,
      rootPath: "/tmp/not-a-real-argus-preview-repo",
      file: GitFileChange(path: "missing.txt", status: .modified, sectionKey: "unstaged")
    )

    guard case .failed(let kind, let path, let message) = result else {
      fail("expected recoverable preview failure, got \(result)")
    }
    assertEqual(kind, .blame, "failure keeps preview kind")
    assertEqual(path, "missing.txt", "failure keeps file path")
    assertEqual(message.isEmpty, false, "failure includes command message")
  }

  private func runsDiffPreviewWithColorizedOutput() async throws {
    let repo = try TemporaryDirectory(prefix: "argus-git-preview-diff")
    defer { repo.remove() }
    try run("/usr/bin/git", ["init", "-b", "main"], in: repo.url)
    try run("/usr/bin/git", ["config", "user.email", "argus@example.test"], in: repo.url)
    try run("/usr/bin/git", ["config", "user.name", "Argus Test"], in: repo.url)
    let fileURL = repo.url.appendingPathComponent("file.txt")
    try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
    try run("/usr/bin/git", ["add", "file.txt"], in: repo.url)
    try run("/usr/bin/git", ["commit", "-m", "initial"], in: repo.url)
    try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)

    let service = GitPreviewService(
      commandBuilder: GitPreviewCommandBuilder(difftasticPathProvider: { nil }))
    let result = await service.preview(
      kind: .diff, rootPath: repo.url.path,
      file: GitFileChange(path: "file.txt", status: .modified, sectionKey: "unstaged"))

    guard case .loaded(let preview) = result else {
      fail("expected loaded diff preview, got \(result)")
    }
    assertEqual(preview.kind, .diff, "loaded preview keeps requested kind")
    assertEqual(preview.path, "file.txt", "loaded preview keeps displayed path")
    assertEqual(preview.output.contains("two"), true, "diff output includes changed content")
    assertEqual(preview.output.contains("\u{001B}["), true, "diff output is colorized")
  }

  private func selectsDiffCommandsForFileSections() {
    let builder = GitPreviewCommandBuilder(difftasticPathProvider: { nil })
    let rootPath = "/tmp/repo"

    let staged = builder.command(
      kind: .diff,
      rootPath: rootPath,
      file: GitFileChange(path: "Sources/App.swift", status: .modified, sectionKey: "staged")
    )
    assertEqual(staged?.executablePath, "/usr/bin/git", "staged diff runs through git")
    assertEqual(
      staged?.arguments,
      [
        "-C", rootPath, "diff", "--no-ext-diff", "--color=always", "--cached", "--",
        "Sources/App.swift",
      ], "staged diff uses cached diff from status root")

    let unstaged = builder.command(
      kind: .diff,
      rootPath: rootPath,
      file: GitFileChange(path: "Sources/App.swift", status: .modified, sectionKey: "unstaged")
    )
    assertEqual(
      unstaged?.arguments,
      ["-C", rootPath, "diff", "--no-ext-diff", "--color=always", "--", "Sources/App.swift"],
      "unstaged diff uses working-tree diff from status root")

    let untracked = builder.command(
      kind: .diff,
      rootPath: rootPath,
      file: GitFileChange(path: "Scratch.txt", status: .untracked, sectionKey: "untracked")
    )
    assertEqual(
      untracked?.arguments,
      [
        "-C", rootPath, "diff", "--no-ext-diff", "--no-index", "--color=always", "--", "/dev/null",
        "Scratch.txt",
      ], "untracked diff compares file against empty input")
  }

  private func selectsBlameCommandOnlyForTrackedRows() {
    let builder = GitPreviewCommandBuilder(difftasticPathProvider: { "/opt/homebrew/bin/difft" })
    let rootPath = "/tmp/repo"

    let tracked = builder.command(
      kind: .blame,
      rootPath: rootPath,
      file: GitFileChange(path: "Sources/App.swift", status: .modified, sectionKey: "unstaged")
    )
    assertEqual(tracked?.executablePath, "/usr/bin/git", "tracked blame runs through git")
    assertEqual(
      tracked?.arguments,
      ["-C", rootPath, "blame", "--color-lines", "--color-by-age", "--", "Sources/App.swift"],
      "tracked blame uses colorized git blame from status root")

    let untracked = builder.command(
      kind: .blame,
      rootPath: rootPath,
      file: GitFileChange(path: "Scratch.txt", status: .untracked, sectionKey: "untracked")
    )
    assertEqual(untracked, nil, "untracked rows do not expose meaningless blame previews")
  }

  private func usesDifftasticForDiffOnlyWhenAvailable() {
    let rootPath = "/tmp/repo"
    let file = GitFileChange(path: "Sources/App.swift", status: .modified, sectionKey: "unstaged")

    let withDifftastic = GitPreviewCommandBuilder(difftasticPathProvider: {
      "/opt/homebrew/bin/difft"
    })
    .command(kind: .diff, rootPath: rootPath, file: file)
    assertEqual(
      withDifftastic?.arguments,
      [
        "-C", rootPath, "-c", "diff.external=/opt/homebrew/bin/difft", "diff", "--color=always",
        "--", "Sources/App.swift",
      ],
      "available difftastic is selected as git's external diff command"
    )

    let withoutDifftastic = GitPreviewCommandBuilder(difftasticPathProvider: { nil })
      .command(kind: .diff, rootPath: rootPath, file: file)
    assertEqual(
      withoutDifftastic?.arguments,
      ["-C", rootPath, "diff", "--no-ext-diff", "--color=always", "--", "Sources/App.swift"],
      "missing difftastic falls back to built-in colorized git diff"
    )
  }

  private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw NSError(domain: "GitPreviewServiceTests", code: Int(process.terminationStatus))
    }
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }

  private func fail(_ message: String) -> Never {
    Issue.record(Comment(rawValue: message))
    fatalError(message)
  }
}

private struct TemporaryDirectory {
  let url: URL

  init(prefix: String) throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
