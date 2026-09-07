import Foundation

struct DependentWorktreeCreation: Sendable {
    let branchName: String
    let worktreePath: String
    let headCommitID: String
    let parentContext: StackParentContext
    let childContext: StackParentContext
    let attempt: DependentWorktreeAttempt
}

struct DependentWorktreeAttempt: Sendable {
    let identifier: UUID
    let branchName: String
    let repositoryPath: String
    let expectedParent: StackParentContext
    var worktreePath: String?
    var directoryIdentity: StackFileIdentity?
    var childContext: StackParentContext?
    var configurationWrite: StackLocalConfigurationWrite?
    var providerSnapshot: DependentProviderSnapshot?
    var branchCreationAttempted = false
    var branchLogVersion: StackFileVersion?
    var worktreeHeadVersion: StackFileVersion?

    var branchReference: String { "refs/heads/\(branchName)" }
    var headCommitID: String { expectedParent.headCommitID }
    var reflogMessage: String { "Argus dependent Workspace \(identifier.uuidString)" }
    var branchLogPath: String {
        URL(fileURLWithPath: expectedParent.checkout.gitCommonDirectory)
            .appendingPathComponent("logs/refs/heads/\(branchName)").path
    }
}

enum DependentWorkspaceError: LocalizedError, Equatable {
    case branchAlreadyExists
    case preexistingMetadata
    case worktreeCreationFailed
    case checkoutFiltersUnsupported(recovery: String?)
    case resourcesChanged
    case retainedResources(repositoryPath: String, branchName: String, worktreePath: String?, configurationPath: String)

    var errorDescription: String? {
        switch self {
        case .branchAlreadyExists:
            "This local or remote-tracking branch already exists. Choose a new branch name."
        case .preexistingMetadata:
            "This branch name already has local configuration or recorded Stack metadata. Choose a new name."
        case .worktreeCreationFailed:
            "The dependent Worktree could not be created. No existing branch was reset."
        case .checkoutFiltersUnsupported(let recovery):
            "The checkout uses Git filters. Argus will not run external filters or attach unfiltered pointer contents. "
                + "Prepare this checkout outside Argus before adopting it."
                + (recovery.map { " " + $0 } ?? "")
        case .resourcesChanged:
            "The new branch, Worktree, or parent metadata changed before the Workspace could be attached."
        case .retainedResources(let repositoryPath, let branchName, let worktreePath, let configurationPath):
            "Creation was not completed. Resources could not be safely removed and were retained. "
                + "Inspect branch '\(branchName)' in \(repositoryPath), "
                + (worktreePath.map { "Worktree \($0), " } ?? "")
                + "and parent configuration in \(configurationPath). "
                + "Adopt or remove the Worktree after checking local files."
        }
    }
}
