import Foundation
import Testing

@testable import Argus

@Suite
struct CurrentBranchDetectionTests {
  @Test
  func coveredBehaviors() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("argus-current-branch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try run("git", ["init", "-b", "main", "."], cwd: root.path)
    try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
    try run("git", ["config", "user.name", "Test User"], cwd: root.path)
    try "hello".write(
      to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try run("git", ["add", "README.md"], cwd: root.path)
    try run("git", ["commit", "-m", "initial"], cwd: root.path)
    try run("git", ["checkout", "-b", "feature/current"], cwd: root.path)

    let service = WorktreeService()
    let mainBranch = try await service.detectMainBranch(repositoryPath: root.path)
    let currentBranch = try await service.currentBranchName(repositoryPath: root.path)

    assertEqual(mainBranch, "main", "main branch detection remains independent")
    assertEqual(currentBranch, "feature/current", "current branch reflects checked-out branch")

    let commit = try capture("git", ["rev-parse", "HEAD"], cwd: root.path)
    try run("git", ["checkout", "--detach", commit], cwd: root.path)
    let detachedBranch = try await service.currentBranchName(repositoryPath: root.path)
    assertEqual(detachedBranch, "(detached)", "detached HEAD has explicit fallback")
  }

  private func run(_ executable: String, _ args: [String], cwd: String) throws {
    _ = try capture(executable, args, cwd: cwd)
  }

  private func capture(_ executable: String, _ args: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/\(executable)")
    process.arguments = args
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output =
      String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      let detail =
        String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw NSError(
        domain: "CurrentBranchDetectionTests", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: detail])
    }
    return output
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }
}
