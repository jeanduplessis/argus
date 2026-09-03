import Darwin
import Foundation

extension WorktreeService {
    func createWorktree(
        projectId: UUID,
        repositoryPath: String,
        branchName: String,
        createNewBranch: Bool = true,
        parentBranch: String? = nil
    ) async throws -> String {
        // Stack creation requires a new branch; reject existing-branch mode at the service boundary.
        if parentBranch != nil, !createNewBranch {
            throw WorktreeError.worktreeCreationFailed("Stack creation requires a new branch")
        }
        let configuredRemotes = (try? await remoteNames(repositoryPath: repositoryPath)) ?? []
        let remoteNames = Set(configuredRemotes + ["origin"])
        if !createNewBranch,
            let existingPath = try await existingWorktreePath(
                for: branchName,
                repositoryPath: repositoryPath,
                remoteNames: remoteNames
            )
        {
            return existingPath
        }
        let resolvedBranchName =
            createNewBranch
            ? branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            : try await resolveExistingBranchForWorktree(branchName, repositoryPath: repositoryPath)
        let worktreeURL =
            managedWorktreeBaseURL
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(uniqueSlug(resolvedBranchName, projectId: projectId), isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            var arguments = ["-C", repositoryPath, "worktree", "add"]
            if createNewBranch {
                if let parent = parentBranch {
                    // Stack creation: start at the exact local parent commit with --no-track
                    // to avoid inheriting tracking configuration from the parent branch.
                    arguments += ["--no-track", "-b", resolvedBranchName, worktreeURL.path, "refs/heads/\(parent)"]
                } else {
                    arguments += ["-b", resolvedBranchName, worktreeURL.path]
                }
            } else {
                arguments += [worktreeURL.path, resolvedBranchName]
            }
            _ = try await runGit(args: arguments, workingDirectory: repositoryPath)
        } catch let error as WorktreeError {
            if case .gitCommandFailed(let detail, _) = error, detail.contains("already exists") {
                throw WorktreeError.branchAlreadyExists(branchName)
            }
            throw WorktreeError.worktreeCreationFailed(error.localizedDescription)
        }
        // Publish the recorded parent only after Git has created the new branch.
        if let parent = parentBranch {
            try await recordStackParent(
                parent, branchName: resolvedBranchName, worktreePath: worktreeURL.path, repositoryPath: repositoryPath)
        }
        return worktreeURL.path
    }

    private func recordStackParent(
        _ parent: String, branchName: String, worktreePath: String, repositoryPath: String
    ) async throws {
        do {
            _ = try await runGit(
                args: ["config", "--local", "branch.\(branchName).base", parent],
                workingDirectory: worktreePath
            )
        } catch {
            let configError = error.localizedDescription
            let recovery: String
            do {
                // Hooks or another process may already have modified this checkout.
                // Never force removal or delete the branch on a metadata-write failure.
                try await removeWorktree(repositoryPath: repositoryPath, worktreePath: worktreePath)
                recovery = "The clean worktree was removed. Branch '\(branchName)' was retained."
            } catch {
                recovery =
                    "The worktree was retained at \(worktreePath). "
                    + "Cleanup failed: \(error.localizedDescription)"
            }
            throw WorktreeError.worktreeCreationFailed(
                "Could not record stack parent '\(parent)' for '\(branchName)': \(configError) "
                    + recovery + " Fix the Git configuration before retrying. "
                    + "An existing branch can be opened from the Project's New Workspace sheet."
            )
        }
    }

    /// Deleting a Managed Worktree has to survive a partially completed
    /// earlier attempt. `git worktree remove` deletes the worktree's `.git`
    /// link before it finishes, so an attempt that was killed midway (for
    /// example by this service's own command timeout) leaves a directory that
    /// every later `git worktree remove` refuses with "validation failed".
    /// Retrying the same command can therefore never succeed on its own.
    ///
    /// A forced removal owns the outcome rather than the exact command: when
    /// Git cannot complete it, the worktree files are deleted directly and the
    /// stale registration is pruned. Pruning matters beyond tidiness, because a
    /// leftover registration keeps the branch marked as checked out and blocks
    /// creating that Worktree Workspace again.
    ///
    /// A non-forced removal keeps deferring to Git, so an unexpectedly dirty
    /// worktree still fails loudly instead of silently discarding user work.
    func removeWorktree(
        repositoryPath: String,
        worktreePath: String,
        force: Bool = false,
        managedOrphanProjectId: UUID? = nil
    ) async throws {
        let canonicalWorktreePath = try await authorizedRemovalPath(
            repositoryPath: repositoryPath,
            worktreePath: worktreePath,
            force: force,
            managedOrphanProjectId: managedOrphanProjectId
        )

        var arguments = ["-C", repositoryPath, "worktree", "remove"]
        if force {
            // Git requires --force twice to remove a locked worktree.
            arguments += ["--force", "--force"]
        }
        arguments.append(canonicalWorktreePath)

        let gitRemovalError: Error?
        do {
            _ = try await runGit(
                args: arguments,
                workingDirectory: repositoryPath,
                timeout: Self.worktreeRemovalTimeout
            )
            gitRemovalError = nil
        } catch {
            guard force else {
                throw WorktreeError.worktreeRemovalFailed(error.localizedDescription)
            }
            gitRemovalError = error
        }

        do {
            if FileManager.default.fileExists(atPath: canonicalWorktreePath) {
                try FileManager.default.removeItem(atPath: canonicalWorktreePath)
            }
        } catch {
            throw WorktreeError.worktreeRemovalFailed(
                (gitRemovalError ?? error).localizedDescription
            )
        }

        guard gitRemovalError != nil else { return }

        // The files are gone, so the registration must go too or the branch
        // stays unusable for a new Worktree Workspace.
        _ = try? await runGit(
            args: ["-C", repositoryPath, "worktree", "prune"],
            workingDirectory: repositoryPath
        )
    }

    private func authorizedRemovalPath(
        repositoryPath: String,
        worktreePath: String,
        force: Bool,
        managedOrphanProjectId: UUID?
    ) async throws -> String {
        let canonicalRepositoryPath = canonicalRemovalPath(repositoryPath)
        let canonicalWorktreePath = canonicalRemovalPath(worktreePath)
        let canonicalStorageRoot = canonicalRemovalPath(managedWorktreeBaseURL.path)
        let registeredWorktree = try await listWorktrees(repositoryPath: repositoryPath).first {
            canonicalRemovalPath($0.path) == canonicalWorktreePath
        }
        let managedOrphanIsAuthorized =
            managedOrphanProjectId.map { projectId in
                guard force else { return false }
                let projectStorageRoot = canonicalRemovalPath(
                    managedWorktreeBaseURL
                        .appendingPathComponent(projectId.uuidString, isDirectory: true)
                        .path
                )
                let targetParent = URL(fileURLWithPath: canonicalWorktreePath)
                    .deletingLastPathComponent()
                    .path
                var isDirectory: ObjCBool = false
                return targetParent == projectStorageRoot
                    && FileManager.default.fileExists(
                        atPath: canonicalWorktreePath,
                        isDirectory: &isDirectory
                    )
                    && isDirectory.boolValue
            } ?? false
        guard canonicalWorktreePath != canonicalRepositoryPath,
            canonicalWorktreePath != canonicalStorageRoot,
            registeredWorktree?.isHead == false || managedOrphanIsAuthorized
        else {
            throw WorktreeError.worktreeRemovalFailed(
                "Refusing to remove a path that is not an authorized secondary worktree"
            )
        }
        return canonicalWorktreePath
    }

    private func canonicalRemovalPath(_ path: String) -> String {
        guard let resolvedPath = realpath(path, nil) else {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    func listBranches(repositoryPath: String) async throws -> [String] {
        let output = try await runGit(
            args: ["-C", repositoryPath, "branch", "--all", "--format=%(refname:short)"],
            workingDirectory: repositoryPath
        )
        let localAndTrackingBranches =
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("HEAD") }
        let remoteHeadBranches = (try? await listRemoteHeadBranches(repositoryPath: repositoryPath)) ?? []
        return Array(Set(localAndTrackingBranches + remoteHeadBranches)).sorted()
    }

    func uniqueBranchName(_ desiredName: String, repositoryPath: String) async throws -> String {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = desiredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return "workspace" }
        if !existingBranches.contains(baseName) {
            return baseName
        }
        for counter in 1..<10_000 {
            let candidate = "\(baseName)-\(counter)"
            if !existingBranches.contains(candidate) {
                return candidate
            }
        }
        throw WorktreeError.branchAlreadyExists(baseName)
    }

    /// Returns `candidate` if it doesn't collide with an existing local or
    /// remote branch, otherwise generates fresh random candidates (falling
    /// back to a numeric suffix) until one is available.
    func suggestAvailableBranchName(
        preferring candidate: String,
        prefix: String,
        repositoryPath: String
    ) async throws -> String {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        if !existingBranches.contains(candidate) {
            return candidate
        }
        for _ in 0..<25 {
            let alternative = RandomBranchNameGenerator.generate(prefix: prefix)
            if !existingBranches.contains(alternative) {
                return alternative
            }
        }
        return try await uniqueBranchName(candidate, repositoryPath: repositoryPath)
    }

    func ensureBranchNameAvailable(_ branchName: String, repositoryPath: String) async throws {
        let existingBranches = try await canonicalBranchNameSet(repositoryPath: repositoryPath)
        let baseName = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseName.isEmpty else { return }
        if existingBranches.contains(baseName) {
            throw WorktreeError.branchAlreadyExists(baseName)
        }
    }

    func remoteNames(repositoryPath: String) async throws -> [String] {
        let output = try? await runGit(
            args: ["-C", repositoryPath, "remote"],
            workingDirectory: repositoryPath
        )
        guard let output, !output.isEmpty else { return [] }
        return
            output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func remoteLocalBranchName(for branchName: String, remoteNames: Set<String>) -> String? {
        for remote in remoteNames where branchName.hasPrefix("\(remote)/") {
            return String(branchName.dropFirst(remote.count + 1))
        }
        return nil
    }

    private func canonicalBranchNameSet(repositoryPath: String) async throws -> Set<String> {
        async let branches = listBranches(repositoryPath: repositoryPath)
        async let remotes = remoteNames(repositoryPath: repositoryPath)
        let remoteNames = Set(try await remotes + ["origin"])
        return Set(
            try await branches.flatMap { branch -> [String] in
                for remote in remoteNames where branch.hasPrefix("\(remote)/") {
                    return [branch, String(branch.dropFirst(remote.count + 1))]
                }
                return [branch]
            })
    }

    private func listRemoteHeadBranches(repositoryPath: String) async throws -> [String] {
        let remotes = try await remoteNames(repositoryPath: repositoryPath)
        var branches: [String] = []
        for remote in remotes {
            guard
                let output = try? await runGit(
                    args: ["-C", repositoryPath, "ls-remote", "--heads", remote],
                    workingDirectory: repositoryPath,
                    timeout: 2
                ), !output.isEmpty
            else { continue }
            for line in output.components(separatedBy: "\n") {
                guard let refRange = line.range(of: "refs/heads/") else { continue }
                let branch = String(line[refRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !branch.isEmpty {
                    branches.append("\(remote)/\(branch)")
                }
            }
        }
        return branches
    }
}
