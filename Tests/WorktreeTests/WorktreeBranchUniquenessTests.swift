import Foundation
import Testing

@testable import Argus

@Suite
struct WorktreeBranchUniquenessTests {
  @Test
  func coveredBehaviors() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("argus-branch-uniqueness-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try run("git", ["init", "."], cwd: root.path)
    try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
    try run("git", ["config", "user.name", "Test User"], cwd: root.path)
    try "hello".write(
      to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try run("git", ["add", "README.md"], cwd: root.path)
    try run("git", ["commit", "-m", "initial"], cwd: root.path)
    try run("git", ["branch", "feature"], cwd: root.path)
    try run("git", ["update-ref", "refs/remotes/origin/feature-1", "HEAD"], cwd: root.path)

    let service = WorktreeService()
    let unique = try await service.uniqueBranchName("feature", repositoryPath: root.path)
    assertEqual(unique, "feature-2", "unique branch name skips local and remote collisions")
  }

  private func run(_ executable: String, _ args: [String], cwd: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/\(executable)")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.standardOutput = FileHandle.nullDevice
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = stderr.fileHandleForReading.readDataToEndOfFile()
      let detail = String(data: data, encoding: .utf8) ?? ""
      throw NSError(
        domain: "WorktreeBranchUniquenessTests",
        code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(detail)"
        ]
      )
    }
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}
