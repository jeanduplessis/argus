import Foundation

struct GitBaseComparisonContext: Equatable, Sendable {
    let rootPath: String
    let branchName: String?
    let headCommitID: String?
    let recordedParentBranch: String?
    let baseBranchName: String?
    let resolvedRef: String?
    let baseCommitID: String?
    let mergeBaseCommitID: String?

    init(
        rootPath: String,
        branchName: String?,
        headCommitID: String?,
        recordedParentBranch: String? = nil,
        baseBranchName: String? = nil,
        resolvedRef: String? = nil,
        baseCommitID: String? = nil,
        mergeBaseCommitID: String? = nil
    ) {
        self.rootPath = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL.path
        self.branchName = branchName
        self.headCommitID = headCommitID
        self.recordedParentBranch = recordedParentBranch
        self.baseBranchName = baseBranchName
        self.resolvedRef = resolvedRef
        self.baseCommitID = baseCommitID
        self.mergeBaseCommitID = mergeBaseCommitID
    }
}
