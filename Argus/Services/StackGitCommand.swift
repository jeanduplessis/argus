import Foundation

protocol StackGitCommandRunning: Sendable {
    func run(
        arguments: [String], repositoryPath: String, environment: [String: String],
        timeout: TimeInterval
    ) throws -> ExternalProcessResult
}

struct StackGitProcessRunner: StackGitCommandRunning {
    func run(
        arguments: [String], repositoryPath: String, environment: [String: String],
        timeout: TimeInterval
    ) throws -> ExternalProcessResult {
        try ExternalProcess.runSynchronously(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: repositoryPath,
            environment: environment,
            maximumOutputBytes: RecordedBaseBranchReader.maximumMetadataBytes,
            timeout: timeout,
            commandDescription: "Validate or update local Stack metadata"
        )
    }
}

struct StackGitCommand: Sendable {
    let environment: [String: String]
    let runner: any StackGitCommandRunning

    init(environment: [String: String], runner: any StackGitCommandRunning) {
        var environment = environment
        for key in [
            "GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
            "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_CONFIG"
        ] {
            environment.removeValue(forKey: key)
        }
        self.environment = environment.merging([
            "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat"
        ]) { _, new in new }
        self.runner = runner
    }

    func run(_ arguments: [String], at path: String, timeout: TimeInterval = 30) throws -> ExternalProcessResult {
        try Task.checkCancellation()
        do {
            let result = try runner.run(
                arguments: [
                    "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                    "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false"
                ] + arguments,
                repositoryPath: path, environment: environment, timeout: timeout)
            guard result.stdout.count + result.stderr.count <= RecordedBaseBranchReader.maximumMetadataBytes else {
                throw StackParentError.outputTooLarge
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch is ExternalProcessOutputLimitError {
            throw StackParentError.outputTooLarge
        } catch is ExternalProcessError {
            throw StackParentError.commandTimedOut
        } catch let error as StackParentError {
            throw error
        } catch {
            throw StackParentError.commandFailed
        }
    }

    func output(_ arguments: [String], at path: String, timeout: TimeInterval = 30) throws -> String {
        let result = try run(arguments, at: path, timeout: timeout)
        guard result.terminationStatus == 0, let value = String(data: result.stdout, encoding: .utf8) else {
            throw StackParentError.commandFailed
        }
        return value
    }

    func validateBranch(_ name: String, at path: String) throws {
        guard name.utf8.count <= RecordedBaseBranchReader.maximumBranchNameBytes,
            GitReferenceValidation.isValidBranchName(name), name != "HEAD"
        else { throw StackParentError.invalidBranchName }
        let result = try run(["check-ref-format", "--branch", name], at: path)
        guard result.terminationStatus == 0 else { throw StackParentError.invalidBranchName }
    }

    func commit(_ reference: String, at path: String) throws -> String? {
        let result = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", reference], at: path)
        if result.terminationStatus == 1 { return nil }
        guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
            output.hasSuffix("\n")
        else { throw StackParentError.commandFailed }
        let value = String(output.dropLast())
        guard value.utf8.count == 40 || value.utf8.count == 64,
            value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw StackParentError.commandFailed }
        return value
    }

    func referenceExists(_ reference: String, at path: String) throws -> Bool {
        let result = try run(["show-ref", "--verify", "--quiet", reference], at: path)
        guard result.terminationStatus == 0 || result.terminationStatus == 1 else {
            throw StackParentError.commandFailed
        }
        return result.terminationStatus == 0
    }

    func resolveParent(_ name: String, at path: String) throws -> String {
        try validateBranch(name, at: path)
        for reference in ["refs/heads/\(name)", "refs/remotes/origin/\(name)"] {
            if let commit = try commit(reference + "^{commit}", at: path) { return commit }
        }
        throw StackParentError.parentNotResolvable
    }

    func path(_ argument: String, at path: String) throws -> String {
        let output = try output(["rev-parse", "--path-format=absolute", argument], at: path)
        guard output.hasPrefix("/"), output.hasSuffix("\n") else { throw StackParentError.checkoutUnavailable }
        return Self.canonicalPath(String(output.dropLast()))
    }

    func checkout(repositoryPath: String, worktreePath: String) throws -> StackCheckoutIdentity {
        let repository = Self.canonicalPath(repositoryPath)
        let worktree = Self.canonicalPath(worktreePath)
        guard repositoryPath.hasPrefix("/"), worktreePath.hasPrefix("/"),
            try path("--show-toplevel", at: repository) == repository,
            try path("--show-toplevel", at: worktree) == worktree
        else { throw StackParentError.checkoutUnavailable }
        let common = try path("--git-common-dir", at: repository)
        guard try path("--git-common-dir", at: worktree) == common else {
            throw StackParentError.checkoutUnavailable
        }
        let gitDirectory = try path("--git-dir", at: worktree)
        let branchResult = try run(["symbolic-ref", "--quiet", "HEAD"], at: worktree)
        guard branchResult.terminationStatus == 0,
            let branchOutput = String(data: branchResult.stdout, encoding: .utf8),
            branchOutput.hasPrefix("refs/heads/"), branchOutput.hasSuffix("\n")
        else { throw StackParentError.detachedHead }
        let branch = String(branchOutput.dropFirst("refs/heads/".count).dropLast())
        try validateBranch(branch, at: worktree)
        guard let head = try commit("HEAD^{commit}", at: worktree),
            try commit("refs/heads/\(branch)^{commit}", at: worktree) == head
        else { throw StackParentError.detachedHead }
        return StackCheckoutIdentity(
            repositoryPath: repository, worktreePath: worktree,
            gitCommonDirectory: common, gitDirectory: gitDirectory,
            branchName: branch, headCommitID: head,
            repositoryIdentity: try StackFileIdentity.directory(at: repository),
            worktreeIdentity: try StackFileIdentity.directory(at: worktree),
            commonDirectoryIdentity: try StackFileIdentity.directory(at: common),
            gitDirectoryIdentity: try StackFileIdentity.directory(at: gitDirectory))
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
