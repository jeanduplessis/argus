import Foundation

@main
struct BranchAvailabilityTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-branch-availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run("git", ["init", "."], cwd: root.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
        try run("git", ["config", "user.name", "Test User"], cwd: root.path)
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: root.path)
        try run("git", ["commit", "-m", "initial"], cwd: root.path)
        try run("git", ["branch", "feature"], cwd: root.path)
        try run("git", ["update-ref", "refs/remotes/origin/remote-only", "HEAD"], cwd: root.path)

        let service = WorktreeService()
        try await service.ensureBranchNameAvailable("new-feature", repositoryPath: root.path)

        do {
            try await service.ensureBranchNameAvailable("feature", repositoryPath: root.path)
            fail("local duplicate branch should throw")
        } catch WorktreeError.branchAlreadyExists(let branch) {
            assertEqual(branch, "feature", "local duplicate branch is reported")
        }

        do {
            try await service.ensureBranchNameAvailable("remote-only", repositoryPath: root.path)
            fail("remote duplicate branch should throw")
        } catch WorktreeError.branchAlreadyExists(let branch) {
            assertEqual(branch, "remote-only", "remote duplicate branch is reported")
        }
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
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "BranchAvailabilityTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(detail)"]
            )
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
