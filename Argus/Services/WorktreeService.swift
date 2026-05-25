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
    private static let worktreeBaseURL: URL = {
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
    private func runGit(
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

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?
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
    private func runGitQuiet(
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
        slug = String(slug.unicodeScalars.filter { scalar in
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

    // MARK: - Worktree CRUD

    /// Creates a new git worktree for the given project and branch.
    ///
    /// - Parameters:
    ///   - projectId: The project's UUID (used for the storage path).
    ///   - repositoryPath: Path to the main repository.
    ///   - branchName: Desired branch name.
    ///   - createNewBranch: If `true`, creates a new branch (`-b`).
    ///     If `false`, checks out an existing branch.
    /// - Returns: The filesystem path of the created worktree.
    func createWorktree(
        projectId: UUID,
        repositoryPath: String,
        branchName: String,
        createNewBranch: Bool = true
    ) async throws -> String {
        let configuredRemotes = (try? await remoteNames(repositoryPath: repositoryPath)) ?? []
        let remoteNames = Set(configuredRemotes + ["origin"])
        if !createNewBranch,
           let existingPath = try await existingWorktreePath(
            for: branchName,
            repositoryPath: repositoryPath,
            remoteNames: remoteNames
           ) {
            return existingPath
        }

        let resolvedBranchName = createNewBranch
            ? branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            : try await resolveExistingBranchForWorktree(branchName, repositoryPath: repositoryPath)
        let slug = uniqueSlug(resolvedBranchName, projectId: projectId)
        let worktreeURL = Self.worktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        let worktreePath = worktreeURL.path

        // Ensure the parent directory exists.
        let parentURL = worktreeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        do {
            if createNewBranch {
                _ = try await runGit(
                    args: ["-C", repositoryPath, "worktree", "add", "-b", resolvedBranchName, worktreePath],
                    workingDirectory: repositoryPath
                )
            } else {
                _ = try await runGit(
                    args: ["-C", repositoryPath, "worktree", "add", worktreePath, resolvedBranchName],
                    workingDirectory: repositoryPath
                )
            }
        } catch let error as WorktreeError {
            switch error {
            case .gitCommandFailed(let detail, _) where detail.contains("already exists"):
                throw WorktreeError.branchAlreadyExists(branchName)
            default:
                throw WorktreeError.worktreeCreationFailed(error.localizedDescription)
            }
        }

        return worktreePath
    }

    /// Removes a git worktree.
    ///
    /// Spec §Git Worktrees rule 5: force removal MUST be used for
    /// programmatic cleanup (e.g. project deletion).
    ///
    /// - Parameters:
    ///   - repositoryPath: Path to the main repository.
    ///   - worktreePath: Path of the worktree to remove.
    ///   - force: If `true`, passes `--force` to git worktree remove.
    func removeWorktree(
        repositoryPath: String,
        worktreePath: String,
        force: Bool = false
    ) async throws {
        var args = ["-C", repositoryPath, "worktree", "remove", worktreePath]
        if force {
            args.insert("--force", at: 4)
        }

        do {
            _ = try await runGit(args: args, workingDirectory: repositoryPath)
        } catch {
            throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
        }

        // Belt-and-suspenders: if the directory still exists, remove it manually.
        let fm = FileManager.default
        if fm.fileExists(atPath: worktreePath) {
            try fm.removeItem(atPath: worktreePath)
        }
    }

    /// Lists all branches (local and remote) in the repository.
    ///
    /// Filters out `HEAD` pointer entries (e.g. `origin/HEAD -> origin/main`).
    func listBranches(repositoryPath: String) async throws -> [String] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "branch", "--all", "--format=%(refname:short)"],
            workingDirectory: repositoryPath
        )
        let localAndTrackingBranches = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
        let remoteHeadBranches = (try? await listRemoteHeadBranches(repositoryPath: repositoryPath)) ?? []

        return Array(Set(localAndTrackingBranches + remoteHeadBranches)).sorted()
    }

    /// Returns a branch name that does not collide with existing local branches
    /// or remote-tracking branches. Appends `-1`, `-2`, etc. when needed.
    func uniqueBranchName(_ desiredName: String, repositoryPath: String) async throws -> String {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return "workspace" }

        if !existingBranches.contains(baseName) {
            return baseName
        }

        var counter = 1
        while counter < 10_000 {
            let candidate = "\(baseName)-\(counter)"
            if !existingBranches.contains(candidate) {
                return candidate
            }
            counter += 1
        }

        throw WorktreeError.branchAlreadyExists(baseName)
    }

    /// Throws if a desired new branch already exists locally or as a remote-tracking branch.
    func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return }
        if existingBranches.contains(baseName) {
            throw WorktreeError.branchAlreadyExists(baseName)
        }
    }

    private func canonicalBranchNameSet(repositoryPath: String) async throws -> Set<String> {
        async let branches = listBranches(repositoryPath: repositoryPath)
        async let remotes = remoteNames(repositoryPath: repositoryPath)

        let remoteNames = Set(try await remotes + ["origin"])
        return Set(try await branches.flatMap { branch -> [String] in
            for remote in remoteNames where branch.hasPrefix("\(remote)/") {
                let remoteBranch = String(branch.dropFirst(remote.count + 1))
                return [branch, remoteBranch]
            }
            return [branch]
        })
    }

    private func remoteNames(repositoryPath: String) async throws -> [String] {
        let output = try? await runGit(
            args: ["-C", repositoryPath, "remote"],
            workingDirectory: repositoryPath
        )
        guard let output, !output.isEmpty else { return [] }
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func listRemoteHeadBranches(repositoryPath: String) async throws -> [String] {
        let remotes = try await remoteNames(repositoryPath: repositoryPath)
        var branches: [String] = []

        for remote in remotes {
            guard let output = try? await runGit(
                args: ["-C", repositoryPath, "ls-remote", "--heads", remote],
                workingDirectory: repositoryPath,
                timeout: 2
            ), !output.isEmpty else { continue }

            for line in output.components(separatedBy: "\n") {
                guard let refRange = line.range(of: "refs/heads/") else { continue }
                let branch = String(line[refRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty else { continue }
                branches.append("\(remote)/\(branch)")
            }
        }

        return branches
    }

    /// Lists all worktrees for the repository by parsing
    /// `git worktree list --porcelain`.
    ///
    /// Porcelain format example:
    /// ```
    /// worktree /path/to/main
    /// HEAD abc1234
    /// branch refs/heads/main
    ///
    /// worktree /path/to/feature
    /// HEAD def5678
    /// branch refs/heads/feature
    /// ```
    func listWorktrees(repositoryPath: String) async throws -> [WorktreeInfo] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "worktree", "list", "--porcelain"],
            workingDirectory: repositoryPath
        )

        guard !output.isEmpty else { return [] }

        var worktrees: [WorktreeInfo] = []
        var currentPath: String?
        var currentCommit: String?
        var currentBranch: String?
        var isFirst = true

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Flush previous entry.
                if let path = currentPath {
                    worktrees.append(WorktreeInfo(
                        path: path,
                        branch: currentBranch ?? "",
                        commitHash: currentCommit ?? "",
                        isHead: isFirst
                    ))
                    if isFirst { isFirst = false }
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentCommit = nil
                currentBranch = nil
            } else if line.hasPrefix("HEAD ") {
                currentCommit = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                // "branch refs/heads/feature" → "feature"
                let fullRef = String(line.dropFirst("branch ".count))
                currentBranch = fullRef.replacingOccurrences(
                    of: "refs/heads/",
                    with: ""
                )
            } else if line.hasPrefix("detached") {
                currentBranch = "(detached)"
            }
        }

        // Flush the last entry.
        if let path = currentPath {
            worktrees.append(WorktreeInfo(
                path: path,
                branch: currentBranch ?? "",
                commitHash: currentCommit ?? "",
                isHead: isFirst
            ))
        }

        return worktrees
    }

    /// Lists branches available for worktree creation — all branches minus
    /// those already checked out in an existing worktree.
    ///
    /// Spec §Git Worktrees rule 7.
    func listAvailableBranches(repositoryPath: String) async throws -> [String] {
        async let allBranches = listBranches(repositoryPath: repositoryPath)
        async let worktrees = listWorktrees(repositoryPath: repositoryPath)
        async let remotes = remoteNames(repositoryPath: repositoryPath)

        let checkedOut = Set(try await worktrees.map(\.branch))
        let remoteNames = Set(try await remotes + ["origin"])
        return try await allBranches.filter { branch in
            if checkedOut.contains(branch) { return false }
            if let localName = remoteLocalBranchName(for: branch, remoteNames: remoteNames),
               checkedOut.contains(localName) {
                return false
            }
            return true
        }
    }

    /// Lists branch choices for workspace creation. This includes regular
    /// available branches plus non-main branches already checked out in external
    /// git worktrees so Argus can adopt those existing worktree paths.
    func listWorkspaceBranchChoices(repositoryPath: String) async throws -> [String] {
        async let availableBranches = listAvailableBranches(repositoryPath: repositoryPath)
        async let worktrees = listWorktrees(repositoryPath: repositoryPath)

        let externalWorktreeBranches = try await worktrees
            .filter { worktree in
                !worktree.isHead && !worktree.branch.isEmpty && worktree.branch != "(detached)"
            }
            .map(\.branch)
        return Array(Set(try await availableBranches + externalWorktreeBranches)).sorted()
    }

    private func existingWorktreePath(
        for branchName: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws -> String? {
        let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames) ?? branchName
        return try await listWorktrees(repositoryPath: repositoryPath)
            .first { worktree in
                !worktree.isHead && worktree.branch == localName
            }?
            .path
    }

    private func resolveExistingBranchForWorktree(
        _ branchName: String,
        repositoryPath: String
    ) async throws -> String {
        if await localBranchExists(branchName, repositoryPath: repositoryPath) {
            return branchName
        }

        let configuredRemotes = (try? await remoteNames(repositoryPath: repositoryPath)) ?? []
        let remoteNames = Set(configuredRemotes + ["origin"])
        if let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames) {
            if !(await remoteTrackingBranchExists(branchName, repositoryPath: repositoryPath)) {
                try await fetchRemoteHead(branchName, repositoryPath: repositoryPath, remoteNames: remoteNames)
            }
            if await remoteTrackingBranchExists(branchName, repositoryPath: repositoryPath) {
                if !((await localBranchExists(localName, repositoryPath: repositoryPath))) {
                    try await createLocalBranchFromRemote(
                        localName: localName,
                        remoteBranch: branchName,
                        repositoryPath: repositoryPath,
                        remoteNames: remoteNames
                    )
                }
                return localName
            }
        }

        for remote in remoteNames {
            let remoteBranch = "\(remote)/\(branchName)"
            if !(await remoteTrackingBranchExists(remoteBranch, repositoryPath: repositoryPath)) {
                try? await fetchRemoteHead(remoteBranch, repositoryPath: repositoryPath, remoteNames: remoteNames)
            }
            guard await remoteTrackingBranchExists(remoteBranch, repositoryPath: repositoryPath) else {
                continue
            }
            if !(await localBranchExists(branchName, repositoryPath: repositoryPath)) {
                try await createLocalBranchFromRemote(
                    localName: branchName,
                    remoteBranch: remoteBranch,
                    repositoryPath: repositoryPath,
                    remoteNames: remoteNames
                )
            }
            return branchName
        }

        throw WorktreeError.worktreeCreationFailed("Branch not found: \(branchName)")
    }

    private func localBranchExists(_ branchName: String, repositoryPath: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", repositoryPath, "show-ref", "--verify", "refs/heads/\(branchName)"],
            workingDirectory: repositoryPath
        )
    }

    private func remoteTrackingBranchExists(_ branchName: String, repositoryPath: String) async -> Bool {
        await runGitQuiet(
            args: ["-C", repositoryPath, "show-ref", "--verify", "refs/remotes/\(branchName)"],
            workingDirectory: repositoryPath
        )
    }

    private func fetchRemoteHead(
        _ branchName: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws {
        guard let localName = remoteLocalBranchName(for: branchName, remoteNames: remoteNames),
              let remote = remoteNames.first(where: { branchName.hasPrefix("\($0)/") })
        else { return }
        _ = try await runGit(
            args: [
                "-C", repositoryPath,
                "fetch", remote,
                "+refs/heads/\(localName):refs/remotes/\(remote)/\(localName)"
            ],
            workingDirectory: repositoryPath
        )
    }

    private func createLocalBranchFromRemote(
        localName: String,
        remoteBranch: String,
        repositoryPath: String,
        remoteNames: Set<String>
    ) async throws {
        if (try? await runGit(
            args: ["-C", repositoryPath, "branch", "--track", localName, "refs/remotes/\(remoteBranch)"],
            workingDirectory: repositoryPath
        )) != nil {
            return
        }

        guard let remoteName = remoteNames.first(where: { remoteBranch.hasPrefix("\($0)/") }),
              let remoteLocalName = remoteLocalBranchName(for: remoteBranch, remoteNames: remoteNames)
        else { throw WorktreeError.worktreeCreationFailed("Branch not found: \(remoteBranch)") }

        _ = try await runGit(
            args: ["-C", repositoryPath, "fetch", remoteName, "refs/heads/\(remoteLocalName)"],
            workingDirectory: repositoryPath
        )
        _ = try await runGit(
            args: ["-C", repositoryPath, "branch", localName, "FETCH_HEAD"],
            workingDirectory: repositoryPath
        )
    }

    private func remoteLocalBranchName(for branchName: String, remoteNames: Set<String>) -> String? {
        for remote in remoteNames where branchName.hasPrefix("\(remote)/") {
            return String(branchName.dropFirst(remote.count + 1))
        }
        return nil
    }

    // MARK: - Orphan Detection

    /// Scans the project's worktree directory for subdirectories that are
    /// not in `knownWorkspacePaths`, returning them as orphans.
    ///
    /// Spec §Git Worktrees rules 6, 8: detect and enumerate orphaned
    /// worktrees on disk that have no corresponding workspace data.
    func detectOrphanedWorktrees(
        projectId: UUID,
        knownWorkspacePaths: Set<String>
    ) -> [OrphanedWorktreeInfo] {
        let projectDir = Self.worktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var orphans: [OrphanedWorktreeInfo] = []

        for entry in entries {
            // Only consider directories.
            guard let resourceValues = try? entry.resourceValues(
                forKeys: [.isDirectoryKey]
            ), resourceValues.isDirectory == true else {
                continue
            }

            let entryPath = entry.path
            if knownWorkspacePaths.contains(entryPath) {
                continue
            }

            // Try to read the branch name from the `.git` file that git
            // worktree creates (it contains `gitdir: /path/to/.git/worktrees/<name>`).
            let branchName = readBranchFromWorktreeDir(entryPath)

            orphans.append(OrphanedWorktreeInfo(
                path: entryPath,
                branchName: branchName,
                projectId: projectId
            ))
        }

        return orphans
    }

    /// Removes an orphaned worktree, with force-removal fallback.
    ///
    /// Spec §Error Handling rule 9: MAY retry with force removal.
    func cleanupOrphanedWorktree(
        repositoryPath: String,
        worktreePath: String
    ) async throws {
        // First attempt: force removal via git.
        do {
            _ = try await runGit(
                args: ["-C", repositoryPath, "worktree", "remove", "--force", worktreePath],
                workingDirectory: repositoryPath
            )
        } catch {
            // Fallback: remove the directory directly.
            let fm = FileManager.default
            if fm.fileExists(atPath: worktreePath) {
                try fm.removeItem(atPath: worktreePath)
            }
        }

        // Also prune stale worktree metadata.
        _ = try? await runGit(
            args: ["-C", repositoryPath, "worktree", "prune"],
            workingDirectory: repositoryPath
        )
    }

    // MARK: - Private Helpers

    /// Attempts to determine the branch name for a worktree directory by
    /// reading its `.git` file and then querying git.
    ///
    /// Returns `nil` if the branch cannot be determined.
    private func readBranchFromWorktreeDir(_ path: String) -> String? {
        let gitFilePath = (path as NSString).appendingPathComponent(".git")
        let fm = FileManager.default

        // A worktree's `.git` is a file (not a directory) containing a
        // `gitdir:` pointer.
        guard fm.fileExists(atPath: gitFilePath),
              let contents = fm.contents(atPath: gitFilePath),
              let text = String(data: contents, encoding: .utf8)
        else {
            return nil
        }

        // Try to read HEAD from the worktree's gitdir to find the branch.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }

        let gitDir = trimmed
            .dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)

        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let headData = fm.contents(atPath: headPath),
              let headContent = String(data: headData, encoding: .utf8)
        else {
            return nil
        }

        let headTrimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // HEAD contains "ref: refs/heads/<branch>" for a non-detached state.
        if headTrimmed.hasPrefix("ref: refs/heads/") {
            return String(headTrimmed.dropFirst("ref: refs/heads/".count))
        }

        return nil
    }
}
