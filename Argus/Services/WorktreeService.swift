import Foundation

// MARK: - Error Type

/// Errors originating from git worktree operations.
enum WorktreeError: LocalizedError {
    case notAGitRepository(String)
    case branchAlreadyExists(String)
    case worktreeCreationFailed(String)
    case worktreeRemovalFailed(String)
    case mainBranchDetectionFailed
    case gitCommandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .notAGitRepository(let path):
            "Not a git repository: \(path)"
        case .branchAlreadyExists(let branch):
            "Branch already exists: \(branch)"
        case .worktreeCreationFailed(let detail):
            "Worktree creation failed: \(detail)"
        case .worktreeRemovalFailed(let detail):
            "Worktree removal failed: \(detail)"
        case .mainBranchDetectionFailed:
            "Could not detect the main branch of the repository"
        case .gitCommandFailed(let command, let exitCode):
            "Git command failed (exit \(exitCode)): \(command)"
        }
    }
}

// MARK: - Supporting Types

/// Information about an existing git worktree, parsed from `git worktree list --porcelain`.
struct WorktreeInfo: Sendable {
    let path: String
    let branch: String
    let commitHash: String
    let isHead: Bool
}

/// An orphaned worktree on disk that has no corresponding workspace.
struct OrphanedWorktreeInfo: Identifiable, Sendable {
    let id = UUID()
    let path: String
    let branchName: String?
    let projectId: UUID
}

// MARK: - WorktreeService

/// Manages git worktrees via the git CLI (`/usr/bin/git`).
///
/// All git operations are performed by spawning `Process` instances.
/// This service is intentionally NOT `@MainActor` — git commands run
/// on background threads to avoid blocking the UI.
///
/// Worktree storage: `~/.argus/worktrees/<project-uuid>/<branch-slug>/`
final class WorktreeService: Sendable {

    // MARK: - Constants

    /// Base directory for all Argus-managed worktrees.
    static let worktreeBaseURL: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".argus/worktrees", isDirectory: true)
    }()

    /// Path to the git binary.
    private static let gitPath = "/usr/bin/git"

    // MARK: - Private Helpers

    /// Runs a git command and returns the trimmed stdout output.
    ///
    /// - Parameters:
    ///   - args: Arguments to pass to git (e.g. `["status", "--porcelain"]`).
    ///   - workingDirectory: Optional working directory for the process.
    /// - Throws: `WorktreeError.gitCommandFailed` on non-zero exit code.
    /// - Returns: The trimmed standard output of the command.
    func runGit(
        args: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_ASKPASS": "echo"
        ]) { _, new in new }

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outputReader = WorktreeProcessOutputReader(stdout: stdout, stderr: stderr)
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        let processOutput = await outputReader.readToEnd()

        let output =
            String(data: processOutput.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let errorOutput =
                String(data: processOutput.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let detail = errorOutput.isEmpty ? output : errorOutput
            throw WorktreeError.gitCommandFailed(
                "git \(args.joined(separator: " ")): \(detail)",
                process.terminationStatus
            )
        }

        return output
    }

    /// Runs a git command and returns whether it succeeded (exit code 0).
    func runGitQuiet(
        args: [String],
        workingDirectory: String? = nil
    ) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.gitPath)
        process.arguments = args

        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        // Discard all output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Slug Generation

    /// Converts a branch name into a filesystem-safe, git-compatible slug.
    ///
    /// Rules: lowercase, `/` and spaces become `-`, non-alphanumeric/non-hyphen
    /// characters are stripped, consecutive hyphens collapsed, leading/trailing
    /// hyphens trimmed.
    func slugify(_ branchName: String) -> String {
        var slug = branchName.lowercased()

        // Replace `/` and spaces with hyphens.
        slug = slug.replacingOccurrences(of: "/", with: "-")
        slug = slug.replacingOccurrences(of: " ", with: "-")

        // Strip characters that are not alphanumeric or hyphens.
        slug = String(
            slug.unicodeScalars.filter { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
            })

        // Collapse consecutive hyphens into a single hyphen.
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }

        // Trim leading and trailing hyphens.
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return slug.isEmpty ? "workspace" : slug
    }

    /// Returns a unique slug for the given branch name under the project's
    /// worktree directory, appending `-1`, `-2`, etc. if needed.
    func uniqueSlug(_ branchName: String, projectId: UUID) -> String {
        let base = slugify(branchName)
        let projectDir = Self.worktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)

        let fm = FileManager.default

        // Fast path: no collision.
        let candidatePath = projectDir.appendingPathComponent(base).path
        if !fm.fileExists(atPath: candidatePath) {
            return base
        }

        // Append numeric suffix until unique.
        var counter = 1
        while true {
            let candidate = "\(base)-\(counter)"
            let path = projectDir.appendingPathComponent(candidate).path
            if !fm.fileExists(atPath: path) {
                return candidate
            }
            counter += 1
        }
    }

    private final class WorktreeProcessDataBox: @unchecked Sendable {
        var data = Data()
    }

    private final class WorktreeProcessOutputReader: @unchecked Sendable {
        private let outputGroup = DispatchGroup()
        private let stdoutBox = WorktreeProcessDataBox()
        private let stderrBox = WorktreeProcessDataBox()

        init(stdout: Pipe, stderr: Pipe) {
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async { [stdoutBox, outputGroup] in
                stdoutBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async { [stderrBox, outputGroup] in
                stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
        }

        func readToEnd() async -> (stdout: Data, stderr: Data) {
            await withCheckedContinuation { continuation in
                outputGroup.notify(queue: .global(qos: .utility)) {
                    continuation.resume()
                }
            }
            return (stdoutBox.data, stderrBox.data)
        }
    }

    // MARK: - Main Branch Detection

    /// Detects the main branch of a repository using a cascading strategy.
    ///
    /// 1. Symbolic ref `refs/remotes/origin/HEAD` → parse branch name
    /// 2. `git show-ref --verify refs/heads/main` → "main"
    /// 3. `git show-ref --verify refs/heads/master` → "master"
    /// 4. `git rev-parse --abbrev-ref HEAD` → current branch
    /// 5. Throw `mainBranchDetectionFailed`
    ///
    /// Spec §Projects rule 4: try symbolic references first, then common
    /// branch names, then current HEAD.
    func detectMainBranch(repositoryPath: String) async throws -> String {
        // Strategy 1: symbolic-ref for origin/HEAD.
        if let output = try? await runGit(
            args: ["symbolic-ref", "refs/remotes/origin/HEAD"],
            workingDirectory: repositoryPath
        ) {
            // Output is e.g. "refs/remotes/origin/main" — extract the branch name.
            let components = output.split(separator: "/")
            if let branchName = components.last, !branchName.isEmpty {
                return String(branchName)
            }
        }

        // Strategy 2: check for refs/heads/main.
        if await runGitQuiet(
            args: ["show-ref", "--verify", "refs/heads/main"],
            workingDirectory: repositoryPath
        ) {
            return "main"
        }

        // Strategy 3: check for refs/heads/master.
        if await runGitQuiet(
            args: ["show-ref", "--verify", "refs/heads/master"],
            workingDirectory: repositoryPath
        ) {
            return "master"
        }

        // Strategy 4: current HEAD branch name.
        if let output = try? await runGit(
            args: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: repositoryPath
        ), !output.isEmpty, output != "HEAD" {
            return output
        }

        // Spec §Error Handling rule 3: return a specific error rather than
        // silently defaulting.
        throw WorktreeError.mainBranchDetectionFailed
    }

    /// Returns the repository's currently checked-out branch, or `(detached)`
    /// when HEAD is detached.
    func currentBranchName(repositoryPath: String) async throws -> String {
        let output = try await runGit(
            args: ["rev-parse", "--abbrev-ref", "HEAD"],
            workingDirectory: repositoryPath
        )
        return output == "HEAD" ? "(detached)" : output
    }

    // MARK: - Repository Validation

    /// Returns `true` if the given path is inside a git repository.
    func isGitRepository(path: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", path, "rev-parse", "--git-dir"]
        )
    }

    /// Resolves any path inside a git repository to the canonical repository root.
    func canonicalRepositoryRoot(for path: String) async throws -> String {
        do {
            let root = try await runGit(
                args: ["-C", path, "rev-parse", "--show-toplevel"],
                workingDirectory: path
            )
            return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        } catch {
            throw WorktreeError.notAGitRepository(path)
        }
    }

}
