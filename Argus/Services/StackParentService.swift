import Foundation

struct StackParentEdit: Sendable {
    let context: StackParentContext
    let write: StackLocalConfigurationWrite?
}

struct UnverifiedStackParentEdit: Error {
    let cause: any Error
    let write: StackLocalConfigurationWrite
}

struct StackParentService: Sendable {
    let git: StackGitCommand
    let reader: RecordedBaseBranchReader

    init(
        environment: [String: String] = GitCommandEnvironment.standard,
        commandRunner: any StackGitCommandRunning = StackGitProcessRunner()
    ) {
        let git = StackGitCommand(environment: environment, runner: commandRunner)
        self.git = git
        self.reader = RecordedBaseBranchReader(environment: git.environment)
    }

    func inspect(repositoryPath: String, worktreePath: String) async throws -> StackParentContext {
        try await StackGitCommand.perform {
            try inspectSynchronously(repositoryPath: repositoryPath, worktreePath: worktreePath)
        }
    }

    @discardableResult
    func setParent(_ parent: String?, expected: StackParentContext) async throws -> StackParentContext {
        try await editParent(parent, expected: expected).context
    }

    func editParent(_ parent: String?, expected: StackParentContext) async throws -> StackParentEdit {
        do {
            return try await prepareEdit(parent, expected: expected)
        } catch let failure as UnverifiedStackParentEdit {
            guard await restore(failure.write) else {
                throw StackParentError.retainedConfiguration(failure.write.path)
            }
            throw failure.cause
        }
    }

    func prepareEdit(_ parent: String?, expected: StackParentContext) async throws -> StackParentEdit {
        try await StackGitCommand.perform {
            try editParentSynchronously(parent, expected: expected)
        }
    }

    func restore(_ write: StackLocalConfigurationWrite) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? StackLocalConfiguration(git: git).restore(write)) == true
        }.value
    }

    func inspectSynchronously(repositoryPath: String, worktreePath: String) throws -> StackParentContext {
        let checkout = try git.checkout(repositoryPath: repositoryPath, worktreePath: worktreePath)
        let configuration = try StackParentConfiguration.read(checkout: checkout, git: git)
        let metadata = try reader.read(repositoryPath: checkout.repositoryPath)
        let bindings = metadata.worktrees.filter { $0.path == checkout.worktreePath }
        guard metadata.gitCommonDirectory == checkout.gitCommonDirectory,
            bindings.count == 1, bindings.first?.branch == checkout.branchName,
            try git.checkout(repositoryPath: checkout.repositoryPath, worktreePath: checkout.worktreePath) == checkout
        else { throw StackParentError.contextChanged }
        guard try StackParentConfiguration.read(checkout: checkout, git: git) == configuration else {
            throw StackParentError.configurationChanged
        }
        let parent = metadata.parents[checkout.branchName]
        let effectiveValue = configuration.effectiveEntries.last?.value
        let configuredParent = effectiveValue.flatMap {
            try? RecordedBaseBranchReader.parentName($0, branch: checkout.branchName, failure: .invalidConfig)
        }
        let source: String
        if parent != nil, configuredParent == parent {
            source = configuration.sourceDescription
        } else if parent != nil {
            source = "Graphite / gh-stack metadata"
        } else if metadata.conflicts[checkout.branchName] != nil {
            source = "Conflicting recorded parent metadata"
        } else {
            source = configuration.effectiveEntries.isEmpty ? "No recorded parent" : configuration.sourceDescription
        }
        let local = configuration.localValues.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        let localOverride = local.flatMap {
            GitReferenceValidation.isValidBranchName($0) ? $0 : nil
        }
        return StackParentContext(
            repositoryPath: checkout.repositoryPath, worktreePath: checkout.worktreePath,
            branchName: checkout.branchName, headCommitID: checkout.headCommitID,
            recordedParent: parent, localOverride: localOverride,
            hasLocalOverride: !configuration.localValues.isEmpty,
            sourceDescription: source,
            editingIssue: configuration.editingIssue
                ?? (metadata.diagnostics.isEmpty ? nil : StackParentError.metadataUnavailable.localizedDescription),
            parentIssue: metadata.conflicts[checkout.branchName],
            checkout: checkout, configuration: configuration, metadata: metadata)
    }

    func validateExpected(_ expected: StackParentContext, allowingInventoryChange: Bool = false) throws
        -> StackParentContext
    {
        let current = try inspectSynchronously(
            repositoryPath: expected.repositoryPath, worktreePath: expected.worktreePath)
        guard current.hasSameCheckout(as: expected), current.hasSameMetadata(as: expected),
            allowingInventoryChange || current.metadata.worktrees == expected.metadata.worktrees
        else { throw StackParentError.contextChanged }
        guard current.configuration == expected.configuration else { throw StackParentError.configurationChanged }
        return current
    }

    func requireUnusedBranchMetadata(_ branch: String, context: StackParentContext) throws {
        guard context.metadata.diagnostics.isEmpty else { throw StackParentError.metadataUnavailable }
        guard context.metadata.parents[branch] == nil, context.metadata.conflicts[branch] == nil,
            !context.metadata.parents.values.contains(branch), !context.metadata.trunkBranches.contains(branch),
            !(try git.referenceExists("refs/branch-metadata/\(branch)", at: context.repositoryPath))
        else { throw DependentWorkspaceError.preexistingMetadata }
        let result = try git.run(
            ["config", "--null", "--includes", "--get-regexp", Self.branchConfigurationPattern(branch)],
            at: context.worktreePath)
        guard try StackParentConfiguration.fields(result).isEmpty else {
            throw DependentWorkspaceError.preexistingMetadata
        }
        let local = try git.run(
            ["config", "--local", "--no-includes", "--null", "--get-regexp", Self.branchConfigurationPattern(branch)],
            at: context.worktreePath)
        guard try StackParentConfiguration.fields(local).isEmpty else {
            throw DependentWorkspaceError.preexistingMetadata
        }
    }

    private static func branchConfigurationPattern(_ branch: String) -> String {
        let escaped = branch.reduce(into: "") { result, character in
            if ".[]\\*^$+?{}()|".contains(character) { result.append("\\") }
            result.append(character)
        }
        return "^branch\\.\(escaped)\\."
    }

    func validateParent(_ parent: String, for branch: String, context: StackParentContext) throws {
        try git.validateBranch(parent, at: context.worktreePath)
        guard parent != branch else { throw StackParentError.selfParent }
        _ = try git.resolveParent(parent, at: context.worktreePath)
        var visited: Set<String> = [branch]
        var current: String? = parent
        while let candidate = current {
            try Task.checkCancellation()
            guard visited.insert(candidate).inserted else { throw StackParentError.parentCycle }
            guard context.metadata.conflicts[candidate] == nil else { throw StackParentError.ambiguousParent }
            current = context.metadata.parents[candidate]
        }
    }

    private func editParentSynchronously(_ parent: String?, expected: StackParentContext) throws -> StackParentEdit {
        let current = try validateExpected(expected)
        if let issue = current.editingIssue { throw StackParentError.configurationNotEditable(issue) }
        if let parent { try validateParent(parent, for: current.branchName, context: current) }
        if current.configuration.localValues == (parent.map { [$0] } ?? []) {
            return StackParentEdit(context: current, write: nil)
        }
        let write = try StackLocalConfiguration(git: git).replace(
            parent: parent, branch: current.branchName, expected: current.configuration,
            worktreePath: current.worktreePath
        ) {
            let validated = try validateExpected(expected)
            if let issue = validated.editingIssue { throw StackParentError.configurationNotEditable(issue) }
            if let parent { try validateParent(parent, for: validated.branchName, context: validated) }
        }
        do {
            let after = try inspectSynchronously(
                repositoryPath: current.repositoryPath, worktreePath: current.worktreePath)
            guard after.hasSameCheckout(as: current), after.configuration.version == write.after,
                after.configuration.localValues == (parent.map { [$0] } ?? []),
                after.parentIssue == nil, after.editingIssue == nil,
                parent == nil || after.recordedParent == parent
            else { throw StackParentError.readbackFailed }
            if let resultingParent = after.recordedParent {
                try validateParent(resultingParent, for: after.branchName, context: after)
            }
            try Task.checkCancellation()
            return StackParentEdit(context: after, write: write)
        } catch {
            throw UnverifiedStackParentEdit(cause: error, write: write)
        }
    }
}
