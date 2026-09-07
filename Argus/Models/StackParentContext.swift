import Foundation

struct StackParentContext: Equatable, Sendable {
    let repositoryPath: String
    let worktreePath: String
    let branchName: String
    let headCommitID: String
    let recordedParent: String?
    let localOverride: String?
    let hasLocalOverride: Bool
    let sourceDescription: String
    let editingIssue: String?
    let parentIssue: String?
    let checkout: StackCheckoutIdentity
    let configuration: StackParentConfiguration
    let metadata: RecordedBaseBranchSnapshot

    func hasSameCheckout(as other: StackParentContext) -> Bool {
        repositoryPath == other.repositoryPath && checkout == other.checkout
    }

    func hasSameMetadata(as other: StackParentContext) -> Bool {
        metadata.gitCommonDirectory == other.metadata.gitCommonDirectory
            && metadata.parents == other.metadata.parents
            && metadata.conflicts == other.metadata.conflicts
            && metadata.diagnostics == other.metadata.diagnostics
            && metadata.trunkBranches == other.metadata.trunkBranches
    }
}

struct StackCheckoutIdentity: Equatable, Sendable {
    let repositoryPath: String
    let worktreePath: String
    let gitCommonDirectory: String
    let gitDirectory: String
    let branchName: String
    let headCommitID: String
    let repositoryIdentity: StackFileIdentity
    let worktreeIdentity: StackFileIdentity
    let commonDirectoryIdentity: StackFileIdentity
    let gitDirectoryIdentity: StackFileIdentity
}

enum StackParentError: LocalizedError, Equatable {
    case invalidBranchName
    case checkoutUnavailable
    case detachedHead
    case contextChanged
    case configurationChanged
    case configurationUnavailable
    case configurationTooLarge
    case configurationNotEditable(String)
    case configurationWriteFailed(String)
    case retainedConfiguration(String)
    case metadataUnavailable
    case selfParent
    case parentCycle
    case ambiguousParent
    case parentNotResolvable
    case readbackFailed
    case commandFailed
    case commandTimedOut
    case outputTooLarge
    case workspaceUnavailable
    case projectChanged
    case workspaceLimitReached

    var errorDescription: String? {
        switch self {
        case .invalidBranchName:
            "Enter a valid Git branch name of at most 4096 UTF-8 bytes."
        case .checkoutUnavailable:
            "The Workspace checkout is missing, unregistered, or belongs to another repository."
        case .detachedHead:
            "The Workspace has a detached or unborn HEAD. Check out a committed local branch first."
        case .contextChanged:
            "The Workspace checkout, branch, HEAD, or recorded parents changed. Inspect it again before retrying."
        case .configurationChanged:
            "Git configuration changed. Inspect the Stack parent again before retrying."
        case .configurationUnavailable:
            "Repository-local Git configuration could not be read safely."
        case .configurationTooLarge:
            "Repository-local Git configuration exceeds the 1 MiB limit."
        case .configurationNotEditable(let reason):
            reason
        case .configurationWriteFailed(let path):
            "Could not update repository-local configuration at \(path). Check permissions and \(path).lock."
        case .retainedConfiguration(let path):
            "The edit could not be verified, and configuration changed before rollback. "
                + "Inspect branch parent settings in \(path); concurrent changes were retained."
        case .metadataUnavailable:
            "Recorded parent metadata is incomplete or unreadable. Resolve its diagnostics before editing."
        case .selfParent:
            "A branch cannot be its own recorded parent."
        case .parentCycle:
            "This parent would create a recorded parent cycle."
        case .ambiguousParent:
            "The parent chain has conflicting declarations. Resolve them before editing."
        case .parentNotResolvable:
            "The parent must resolve to a local branch or an existing origin-tracking branch. No fetch was attempted."
        case .readbackFailed:
            "The local parent edit did not produce the expected recorded parent."
        case .commandFailed:
            "A local Git validation command failed. No remote operation was requested."
        case .commandTimedOut:
            "A local Git command timed out."
        case .outputTooLarge:
            "Local Git validation output exceeds the 1 MiB limit."
        case .workspaceUnavailable:
            "This operation requires a repository-backed Workspace in a Named Project."
        case .projectChanged:
            "The initiating Project or Workspace changed or was removed."
        case .workspaceLimitReached:
            "The Workspace limit has been reached."
        }
    }
}
