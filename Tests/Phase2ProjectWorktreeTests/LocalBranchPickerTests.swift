import Foundation

@main
struct LocalBranchPickerTests {
    static func main() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-local-branch-picker-\(UUID().uuidString)", isDirectory: true)
        let repo = temp.appendingPathComponent("repo", isDirectory: true)
        let checkedOutWorktree = temp.appendingPathComponent("checked-out-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try run("git", ["init", "-b", "main", "."], cwd: repo.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: repo.path)
        try run("git", ["config", "user.name", "Test User"], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: repo.path)
        try run("git", ["commit", "-m", "initial"], cwd: repo.path)
        try run("git", ["branch", "local-only"], cwd: repo.path)
        try run("git", ["branch", "checked-out-local"], cwd: repo.path)
        try run("git", ["worktree", "add", checkedOutWorktree.path, "checked-out-local"], cwd: repo.path)

        let service = WorktreeService()
        let available = try await service.listAvailableBranches(repositoryPath: repo.path)

        assertTrue(available.contains("local-only"), "local branch that is not checked out in another worktree is available")
        assertFalse(available.contains("checked-out-local"), "local branch checked out in another worktree remains unavailable")
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
            throw NSError(domain: "LocalBranchPickerTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(detail)"])
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
