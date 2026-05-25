import Foundation

@main
struct ExistingWorktreeBranchChoiceTests {
    static func main() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-existing-worktree-choice-\(UUID().uuidString)", isDirectory: true)
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let existingWorktree = temp.appendingPathComponent("existing-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)
        try run("git", ["branch", "external-worktree"], cwd: repo.path)
        try run("git", ["worktree", "add", existingWorktree.path, "external-worktree"], cwd: repo.path)

        let service = WorktreeService()
        let availableForNewWorktree = try await service.listAvailableBranches(repositoryPath: repo.path)
        assertFalse(availableForNewWorktree.contains("external-worktree"), "checked-out worktree branch remains unavailable for creating another worktree")

        let pickerChoices = try await service.listWorkspaceBranchChoices(repositoryPath: repo.path)
        assertTrue(pickerChoices.contains("external-worktree"), "workspace branch picker includes local branches checked out in external worktrees")

        let resolvedPath = try await service.createWorktree(
            projectId: UUID(),
            repositoryPath: repo.path,
            branchName: "external-worktree",
            createNewBranch: false
        )
        assertEqual(
            URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath().path,
            existingWorktree.resolvingSymlinksInPath().path,
            "selecting a checked-out worktree branch reuses the existing worktree path"
        )
    }

    private static func run(_ executable: String, _ args: [String], cwd: String) throws {
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
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ExistingWorktreeBranchChoiceTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(detail)"])
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    private static func assertTrue(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
