import Darwin
import Foundation

struct DependentWorktreeRegistration: Sendable {
    let path: String
    let branch: String?
    let head: String?
    let locked: Bool
    let prunable: Bool
}

extension WorktreeService {
    func rollbackDependentAttempt(_ attempt: DependentWorktreeAttempt) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            (try? removeDependentAttempt(attempt)) == true
        }.value
    }

    func dependentRecoveryError(_ attempt: DependentWorktreeAttempt) -> DependentWorkspaceError {
        .retainedResources(
            repositoryPath: attempt.repositoryPath, branchName: attempt.branchName,
            worktreePath: attempt.worktreePath, configurationPath: attempt.expectedParent.configuration.path)
    }

    func validateDependentResources(_ attempt: DependentWorktreeAttempt) throws {
        let expected = attempt.expectedParent
        let git = stackParentService.git
        guard try StackFileIdentity.directory(at: attempt.repositoryPath) == expected.checkout.repositoryIdentity,
            try git.path("--git-common-dir", at: attempt.repositoryPath) == expected.checkout.gitCommonDirectory,
            try StackFileIdentity.directory(at: expected.checkout.gitCommonDirectory)
                == expected.checkout.commonDirectoryIdentity,
            try StackFileVersion.read(at: expected.configuration.path).version
                == (attempt.configurationWrite?.after ?? expected.configuration.version)
        else { throw DependentWorkspaceError.resourcesChanged }
        _ = try ownedDependentBranchLog(attempt)
        let registrations = try dependentRegistrations(at: attempt.repositoryPath)
        let branchCheckouts = registrations.filter { $0.branch == attempt.branchName }
        guard branchCheckouts.allSatisfy({ $0.path == attempt.worktreePath }) else {
            throw DependentWorkspaceError.resourcesChanged
        }
        if let path = attempt.worktreePath {
            try validateDependentCheckout(path, attempt: attempt, registrations: registrations)
        } else if !branchCheckouts.isEmpty {
            throw DependentWorkspaceError.resourcesChanged
        }
        try validateDependentMetadata(attempt)
    }

    func ownedDependentBranchLog(_ attempt: DependentWorktreeAttempt) throws -> StackFileVersion {
        let git = stackParentService.git
        let version = try StackFileVersion.read(at: attempt.branchLogPath).version
        let symbolic = try git.run(["symbolic-ref", "--quiet", attempt.branchReference], at: attempt.repositoryPath)
        guard symbolic.terminationStatus == 1,
            try git.commit(attempt.branchReference + "^{commit}", at: attempt.repositoryPath) == attempt.headCommitID
        else { throw DependentWorkspaceError.resourcesChanged }
        let log = try git.output(
            ["reflog", "show", "--max-count=1", "--format=%H%x00%gs", attempt.branchReference],
            at: attempt.repositoryPath)
        guard log == attempt.headCommitID + "\0" + attempt.reflogMessage + "\n",
            attempt.branchLogVersion == nil || attempt.branchLogVersion == version,
            try StackFileVersion.read(at: attempt.branchLogPath).version == version
        else { throw DependentWorkspaceError.resourcesChanged }
        return version
    }

    func dependentRegistrations(at path: String) throws -> [DependentWorktreeRegistration] {
        let output = try stackParentService.git.output(["worktree", "list", "--porcelain", "-z"], at: path)
        guard output.hasSuffix("\0\0") else { throw StackParentError.checkoutUnavailable }
        return try output.components(separatedBy: "\0\0").dropLast().map { record in
            let fields = record.components(separatedBy: "\0")
            guard let pathField = fields.first, pathField.hasPrefix("worktree /") else {
                throw StackParentError.checkoutUnavailable
            }
            return DependentWorktreeRegistration(
                path: StackGitCommand.canonicalPath(String(pathField.dropFirst("worktree ".count))),
                branch: fields.first(where: { $0.hasPrefix("branch refs/heads/") })
                    .map { String($0.dropFirst("branch refs/heads/".count)) },
                head: fields.first(where: { $0.hasPrefix("HEAD ") }).map { String($0.dropFirst("HEAD ".count)) },
                locked: fields.contains { $0 == "locked" || $0.hasPrefix("locked ") },
                prunable: fields.contains { $0 == "prunable" || $0.hasPrefix("prunable ") })
        }
    }

    func dependentPathExists(_ path: String) -> Bool {
        var information = stat()
        return lstat(path, &information) == 0 || errno != ENOENT
    }

    private func validateDependentCheckout(
        _ path: String, attempt: DependentWorktreeAttempt, registrations: [DependentWorktreeRegistration]
    ) throws {
        guard try StackFileIdentity.directory(at: path) == attempt.directoryIdentity else {
            throw DependentWorkspaceError.resourcesChanged
        }
        let matches = registrations.filter { $0.path == path }
        guard let registration = matches.first else {
            guard attempt.childContext == nil, try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
                throw DependentWorkspaceError.resourcesChanged
            }
            return
        }
        guard matches.count == 1, registration.branch == attempt.branchName,
            registration.head == attempt.headCommitID, !registration.locked, !registration.prunable
        else { throw DependentWorkspaceError.resourcesChanged }
        let git = stackParentService.git
        let checkout = try git.checkout(repositoryPath: attempt.repositoryPath, worktreePath: path)
        guard checkout.branchName == attempt.branchName, checkout.headCommitID == attempt.headCommitID,
            attempt.childContext == nil || checkout == attempt.childContext?.checkout
        else { throw DependentWorkspaceError.resourcesChanged }
        if let headVersion = attempt.worktreeHeadVersion {
            guard try StackFileVersion.read(at: checkout.gitDirectory + "/HEAD").version == headVersion else {
                throw DependentWorkspaceError.resourcesChanged
            }
        }
        let tracked = try git.output(["ls-files", "-v", "-z"], at: path)
        guard tracked.split(separator: "\0").allSatisfy({ $0.hasPrefix("H ") }) else {
            throw DependentWorkspaceError.resourcesChanged
        }
        let safety = DependentCheckoutSafety(git: git)
        try safety.requireUnchangedIndex(at: path, headCommitID: attempt.headCommitID)
        try safety.requireUnpopulatedSubmodules(at: path, headCommitID: attempt.headCommitID)
        let filters = try safety.filterBlockingArguments(at: path)
        let status = try git.output(
            filters + [
                "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored", "--ignore-submodules=all"
            ],
            at: path)
        guard status.isEmpty else { throw DependentWorkspaceError.resourcesChanged }
    }

    private func validateDependentMetadata(_ attempt: DependentWorktreeAttempt) throws {
        let providers = try DependentProviderSnapshot.read(
            commonDirectory: attempt.expectedParent.checkout.gitCommonDirectory,
            repositoryPath: attempt.repositoryPath, git: stackParentService.git)
        guard providers == attempt.providerSnapshot else { throw DependentWorkspaceError.resourcesChanged }
        let metadata = try stackParentService.reader.read(repositoryPath: attempt.repositoryPath)
        let original = attempt.expectedParent.metadata
        var parents = original.parents
        if attempt.configurationWrite != nil { parents[attempt.branchName] = attempt.expectedParent.branchName }
        guard metadata.parents == parents, metadata.conflicts == original.conflicts,
            metadata.trunkBranches == original.trunkBranches, metadata.diagnostics == original.diagnostics
        else { throw DependentWorkspaceError.resourcesChanged }
    }

    private func removeDependentAttempt(_ attempt: DependentWorktreeAttempt) throws -> Bool {
        guard attempt.branchCreationAttempted else { return true }
        let git = stackParentService.git
        if !(try git.referenceExists(attempt.branchReference, at: attempt.repositoryPath)) {
            return attempt.worktreePath == nil && attempt.configurationWrite == nil
        }
        try validateDependentResources(attempt)
        if let path = attempt.worktreePath {
            let registration = try dependentRegistrations(at: attempt.repositoryPath).first { $0.path == path }
            if registration != nil {
                let safety = DependentCheckoutSafety(git: git)
                guard try safety.gitlinkPaths(at: path, sourceCommit: attempt.headCommitID).isEmpty,
                    try safety.gitlinkPaths(at: path).isEmpty
                else { return false }
                let filters = try safety.filterBlockingArguments(at: path)
                try validateDependentMetadata(attempt)
                let result = try git.run(
                    filters + ["worktree", "remove", "--", path],
                    at: attempt.repositoryPath, timeout: Self.worktreeRemovalTimeout)
                guard result.terminationStatus == 0, !dependentPathExists(path) else { return false }
            } else {
                guard try StackFileIdentity.directory(at: path) == attempt.directoryIdentity, rmdir(path) == 0 else {
                    return false
                }
            }
        }
        guard
            try StackFileVersion.read(at: attempt.expectedParent.configuration.path).version
                == (attempt.configurationWrite?.after ?? attempt.expectedParent.configuration.version),
            try dependentRegistrations(at: attempt.repositoryPath).allSatisfy({ $0.branch != attempt.branchName })
        else { return false }
        _ = try ownedDependentBranchLog(attempt)
        try validateDependentMetadata(attempt)
        let removed = try git.run(
            ["update-ref", "--no-deref", "-d", attempt.branchReference, attempt.headCommitID],
            at: attempt.repositoryPath)
        guard removed.terminationStatus == 0,
            !(try git.referenceExists(attempt.branchReference, at: attempt.repositoryPath))
        else { return false }
        if let write = attempt.configurationWrite {
            return try StackLocalConfiguration(git: git).restore(write)
        }
        return true
    }
}
