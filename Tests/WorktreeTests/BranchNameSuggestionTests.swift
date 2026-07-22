import Foundation
import Testing

@testable import Argus

@Suite
struct BranchNameSuggestionTests {
    @Test
    func coveredBehaviors() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-branch-suggestion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run("git", ["init", "."], cwd: root.path)
        try run("git", ["config", "user.email", "test@example.com"], cwd: root.path)
        try run("git", ["config", "user.name", "Test User"], cwd: root.path)
        try "hello".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run("git", ["add", "README.md"], cwd: root.path)
        try run("git", ["commit", "-m", "initial"], cwd: root.path)
        try run("git", ["branch", "taken-branch"], cwd: root.path)
        try run("git", ["update-ref", "refs/remotes/origin/also-taken", "HEAD"], cwd: root.path)

        let service = WorktreeService()

        let untouched = try await service.suggestAvailableBranchName(
            preferring: "totally-free-name",
            prefix: "",
            repositoryPath: root.path
        )
        assertEqual(untouched, "totally-free-name", "an available candidate is returned unchanged")

        let replaced = try await service.suggestAvailableBranchName(
            preferring: "taken-branch",
            prefix: "",
            repositoryPath: root.path
        )
        assertFalse(replaced == "taken-branch", "a locally colliding candidate is replaced")
        assertFalse(replaced.isEmpty, "a replacement suggestion is always produced")

        let replacedRemote = try await service.suggestAvailableBranchName(
            preferring: "also-taken",
            prefix: "",
            repositoryPath: root.path
        )
        assertFalse(replacedRemote == "also-taken", "a remote-tracking collision is also replaced")

        let prefixed = try await service.suggestAvailableBranchName(
            preferring: "taken-branch",
            prefix: "eshurakov",
            repositoryPath: root.path
        )
        assertTrue(
            prefixed == "taken-branch" || prefixed.hasPrefix("eshurakov/"),
            "replacement suggestions honor the configured prefix"
        )
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
                domain: "BranchNameSuggestionTests",
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

    private func assertTrue(_ condition: Bool, _ message: String) {
        #expect(condition, Comment(rawValue: message))
    }

    private func assertFalse(_ condition: Bool, _ message: String) {
        assertTrue(!condition, message)
    }
}
