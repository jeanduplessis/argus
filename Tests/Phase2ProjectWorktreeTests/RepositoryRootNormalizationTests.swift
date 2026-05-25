import Foundation

@main
struct RepositoryRootNormalizationTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-repo-root-\(UUID().uuidString)", isDirectory: true)
        let subdir = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try run("git", ["init", "."], cwd: root.path)
        let service = WorktreeService()
        let canonicalRoot = try await service.canonicalRepositoryRoot(for: subdir.path)
        assertEqual(canonicalRoot, root.resolvingSymlinksInPath().path, "subdirectory resolves to canonical repo root")

        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("argus-not-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        do {
            _ = try await service.canonicalRepositoryRoot(for: outside.path)
            fputs("FAIL: non-repository path should throw\n", stderr)
            exit(1)
        } catch WorktreeError.notAGitRepository(let path) {
            assertEqual(path, outside.path, "invalid path is reported as not a git repository")
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
            throw NSError(domain: "RepositoryRootNormalizationTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail])
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
