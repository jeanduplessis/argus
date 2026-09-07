import Darwin
import Foundation

private struct DependentWorktreePreparationFailure: Error {
    let cause: any Error
    let attempt: DependentWorktreeAttempt
}

extension WorktreeService {
    func createDependentWorktree(
        projectId: UUID, repositoryPath: String, branchName: String, expectedParent: StackParentContext
    ) async throws -> DependentWorktreeCreation {
        let prepared: DependentWorktreeAttempt
        do {
            prepared = try await StackGitCommand.perform { [self] in
                try prepareDependentWorktree(
                    projectId: projectId, repositoryPath: repositoryPath,
                    branchName: branchName, expectedParent: expectedParent)
            }
        } catch let failure as DependentWorktreePreparationFailure {
            try await discardDependentAttempt(failure.attempt, cause: failure.cause)
            throw failure.cause
        }
        var attempt = prepared
        do {
            guard let child = attempt.childContext else { throw DependentWorkspaceError.worktreeCreationFailed }
            do {
                let edit = try await stackParentService.prepareEdit(expectedParent.branchName, expected: child)
                attempt.configurationWrite = edit.write
                attempt.childContext = edit.context
            } catch let failure as UnverifiedStackParentEdit {
                attempt.configurationWrite = failure.write
                throw failure.cause
            }
            let completed = attempt
            return try await StackGitCommand.perform { [self] in
                let parent = try validateDependentParent(completed)
                guard let child = completed.childContext, let path = completed.worktreePath else {
                    throw DependentWorkspaceError.worktreeCreationFailed
                }
                _ = try stackParentService.validateExpected(child)
                try validateDependentResources(completed)
                return DependentWorktreeCreation(
                    branchName: branchName, worktreePath: path, headCommitID: expectedParent.headCommitID,
                    parentContext: parent, childContext: child, attempt: completed)
            }
        } catch {
            try await discardDependentAttempt(attempt, cause: error)
            throw error
        }
    }

    func validateDependentWorktree(_ creation: DependentWorktreeCreation) async throws {
        try await StackGitCommand.perform { [self] in
            _ = try stackParentService.validateExpected(creation.parentContext)
            _ = try stackParentService.validateExpected(creation.childContext)
            try validateDependentResources(creation.attempt)
        }
    }

    func rollbackDependentWorktree(_ creation: DependentWorktreeCreation) async -> Bool {
        await rollbackDependentAttempt(creation.attempt)
    }

    private func discardDependentAttempt(_ attempt: DependentWorktreeAttempt, cause: any Error) async throws {
        guard await rollbackDependentAttempt(attempt) else {
            let recovery = dependentRecoveryError(attempt)
            if let error = cause as? DependentWorkspaceError, case .checkoutFiltersUnsupported = error {
                throw DependentWorkspaceError.checkoutFiltersUnsupported(recovery: recovery.localizedDescription)
            }
            throw recovery
        }
        if cause is CancellationError { throw CancellationError() }
    }

    private func prepareDependentWorktree(
        projectId: UUID, repositoryPath: String, branchName: String, expectedParent: StackParentContext
    ) throws -> DependentWorktreeAttempt {
        var attempt = DependentWorktreeAttempt(
            identifier: UUID(), branchName: branchName,
            repositoryPath: expectedParent.repositoryPath, expectedParent: expectedParent)
        do {
            guard StackGitCommand.canonicalPath(repositoryPath) == expectedParent.repositoryPath else {
                throw StackParentError.contextChanged
            }
            let parent = try stackParentService.validateExpected(expectedParent)
            let git = stackParentService.git
            attempt.providerSnapshot = try DependentProviderSnapshot.read(
                commonDirectory: parent.checkout.gitCommonDirectory, repositoryPath: repositoryPath, git: git)
            try git.validateBranch(branchName, at: repositoryPath)
            try requireAvailableDependentBranch(branchName, repositoryPath: repositoryPath)
            try stackParentService.requireUnusedBranchMetadata(branchName, context: parent)
            _ = try DependentCheckoutSafety(git: git).filterBlockingArguments(
                at: parent.worktreePath, sourceCommit: parent.headCommitID)
            guard !dependentPathExists(attempt.branchLogPath) else { throw DependentWorkspaceError.branchAlreadyExists }
            _ = try stackParentService.validateExpected(expectedParent)
            attempt.branchCreationAttempted = true
            let result = try git.run(
                [
                    "update-ref", "--create-reflog", "-m", attempt.reflogMessage,
                    attempt.branchReference, parent.headCommitID,
                    String(repeating: "0", count: parent.headCommitID.count)
                ], at: repositoryPath)
            guard result.terminationStatus == 0 else { throw DependentWorkspaceError.branchAlreadyExists }
            attempt.branchLogVersion = try ownedDependentBranchLog(attempt)
            let reserved = try reserveDependentDirectory(projectId: projectId, branchName: branchName, parent: parent)
            attempt.worktreePath = reserved.path
            attempt.directoryIdentity = reserved.identity
            _ = try stackParentService.validateExpected(expectedParent)
            let added = try git.run(
                ["worktree", "add", "--no-checkout", "--", reserved.path, branchName], at: repositoryPath)
            guard added.terminationStatus == 0 else { throw DependentWorkspaceError.worktreeCreationFailed }
            try materializeDependentCheckout(&attempt)
            _ = try stackParentService.validateExpected(expectedParent, allowingInventoryChange: true)
            try validateDependentResources(attempt)
            return attempt
        } catch {
            throw DependentWorktreePreparationFailure(cause: error, attempt: attempt)
        }
    }

    private func materializeDependentCheckout(_ attempt: inout DependentWorktreeAttempt) throws {
        guard let path = attempt.worktreePath else { throw DependentWorkspaceError.worktreeCreationFailed }
        let git = stackParentService.git
        let child = try stackParentService.inspectSynchronously(
            repositoryPath: attempt.repositoryPath, worktreePath: path)
        attempt.childContext = child
        attempt.worktreeHeadVersion = try StackFileVersion.read(at: child.checkout.gitDirectory + "/HEAD").version
        guard child.branchName == attempt.branchName, child.headCommitID == attempt.headCommitID,
            child.checkout.worktreeIdentity == attempt.directoryIdentity
        else { throw DependentWorkspaceError.resourcesChanged }
        try stackParentService.requireUnusedBranchMetadata(attempt.branchName, context: child)
        let filters = try DependentCheckoutSafety(git: git).filterBlockingArguments(
            at: path, sourceCommit: attempt.headCommitID)
        guard try FileManager.default.contentsOfDirectory(atPath: path) == [".git"],
            try git.checkout(repositoryPath: attempt.repositoryPath, worktreePath: path) == child.checkout
        else { throw DependentWorkspaceError.resourcesChanged }
        _ = try git.output(["read-tree", attempt.headCommitID], at: path)
        let result = try git.run(filters + ["checkout-index", "--all", "--index"], at: path)
        guard result.terminationStatus == 0 else { throw DependentWorkspaceError.worktreeCreationFailed }
    }

    private func requireAvailableDependentBranch(_ name: String, repositoryPath: String) throws {
        let git = stackParentService.git
        guard !(try git.referenceExists("refs/heads/\(name)", at: repositoryPath)) else {
            throw DependentWorkspaceError.branchAlreadyExists
        }
        let remotes = try git.output(["remote"], at: repositoryPath).split(separator: "\n").map(String.init)
        for remote in Set(remotes + ["origin"])
        where try git.referenceExists("refs/remotes/\(remote)/\(name)", at: repositoryPath) {
            throw DependentWorkspaceError.branchAlreadyExists
        }
    }

    private func reserveDependentDirectory(
        projectId: UUID, branchName: String, parent: StackParentContext
    ) throws -> (path: String, identity: StackFileIdentity) {
        let directory = managedWorktreeBaseURL.appendingPathComponent(projectId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try StackFileIdentity.directory(at: directory.path)
        let directoryPath = StackGitCommand.canonicalPath(directory.path)
        let registered = Set(try dependentRegistrations(at: parent.repositoryPath).map(\.path))
        let slug = slugify(branchName)
        for suffix in 0..<10_000 {
            try Task.checkCancellation()
            let name = suffix == 0 ? slug : "\(slug)-\(suffix)"
            let path = directoryPath + "/" + name
            guard !registered.contains(path), !dependentPathExists(path) else { continue }
            if mkdir(path, 0o700) == 0 {
                return (path, try StackFileIdentity.directory(at: path))
            }
            if errno != EEXIST { throw DependentWorkspaceError.worktreeCreationFailed }
        }
        throw DependentWorkspaceError.worktreeCreationFailed
    }

    private func validateDependentParent(_ attempt: DependentWorktreeAttempt) throws -> StackParentContext {
        let original = attempt.expectedParent
        let current = try stackParentService.inspectSynchronously(
            repositoryPath: attempt.repositoryPath, worktreePath: original.worktreePath)
        var expectedParents = original.metadata.parents
        expectedParents[attempt.branchName] = original.branchName
        guard current.hasSameCheckout(as: original),
            current.configuration.localValues == original.configuration.localValues,
            current.configuration.effectiveEntries == original.configuration.effectiveEntries,
            current.configuration.version == attempt.configurationWrite?.after,
            current.metadata.parents == expectedParents,
            current.metadata.conflicts == original.metadata.conflicts,
            current.metadata.diagnostics == original.metadata.diagnostics,
            current.metadata.trunkBranches == original.metadata.trunkBranches
        else { throw StackParentError.contextChanged }
        return current
    }
}
