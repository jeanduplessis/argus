import Foundation
import Testing

@testable import Argus

@Suite
struct ExistingBranchWorktreeTests {
  @Test
  func coveredBehaviors() async throws {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("argus-existing-branch-\(UUID().uuidString)", isDirectory: true)
    let repo = temp.appendingPathComponent("repo", isDirectory: true)
    let origin = temp.appendingPathComponent("origin.git", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try run("git", ["init", "--bare", origin.path], cwd: temp.path)
    try run("git", ["init", "-b", "main", "."], cwd: repo.path)
    try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
    try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
    try "hello".write(
      to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try run("git", ["add", "README.md"], cwd: repo.path)
    try run("git", ["commit", "-m", "initial"], cwd: repo.path)
    try run("git", ["checkout", "-b", "remote-only"], cwd: repo.path)
    try "remote".write(
      to: repo.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
    try run("git", ["add", "remote.txt"], cwd: repo.path)
    try run("git", ["commit", "-m", "remote branch"], cwd: repo.path)
    try run("git", ["checkout", "main"], cwd: repo.path)
    try run("git", ["remote", "add", "origin", origin.path], cwd: repo.path)
    try run("git", ["push", "-u", "origin", "main", "remote-only"], cwd: repo.path)
    try run("git", ["branch", "-D", "remote-only"], cwd: repo.path)
    try run("git", ["fetch", "origin"], cwd: repo.path)

    let service = WorktreeService()
    let available = try await service.listAvailableBranches(repositoryPath: repo.path)
    assertFalse(available.contains("origin/main"), "remote branch for checked-out main is excluded")
    assertTrue(
      available.contains("origin/remote-only"),
      "remote-only branch remains available with remote label")

    let projectId = UUID()
    let worktreePath = try await service.createWorktree(
      projectId: projectId,
      repositoryPath: repo.path,
      branchName: "origin/remote-only",
      createNewBranch: false
    )
    defer { try? FileManager.default.removeItem(atPath: worktreePath) }

    let checkedOutBranch = try capture("git", ["branch", "--show-current"], cwd: worktreePath)
    assertEqual(
      checkedOutBranch, "remote-only",
      "remote-only worktree is on a local tracking branch, not detached")
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
        domain: "ExistingBranchWorktreeTests", code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey:
            "\(executable) \(args.joined(separator: " ")) failed: \(detail)"
        ])
    }
    return output
  }

  private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    #expect(actual == expected, Comment(rawValue: message))
  }

  private func assertTrue(_ condition: Bool, _ message: String) {
    #expect(condition, Comment(rawValue: message))
  }

  private func assertFalse(_ condition: Bool, _ message: String) {
    assertTrue(!condition, message)
  }
}
