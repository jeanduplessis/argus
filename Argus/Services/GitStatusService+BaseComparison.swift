import Foundation

private struct BaseBranchResolution {
    let name: String?
    let reference: BaseBranchReference?
}

private struct BaseBranchReference {
    let ref: String
    let commitID: String
}

func buildAgainstBase(
    rootPath: String,
    presentation: GitStatusPresentation,
    currentBranch: String?,
    headCommitID: String? = nil
) -> BaseComparisonResult {
    let parent = readRecordedParent(rootPath: rootPath, currentBranch: currentBranch)
    let resolution =
        parent.issue == nil
        ? resolveBaseBranch(
            rootPath: rootPath, presentation: presentation, currentBranch: currentBranch, recordedParent: parent.name)
        : BaseBranchResolution(name: nil, reference: nil)
    let head = headCommitID ?? resolveBaseCommit(rootPath: rootPath, ref: "HEAD")
    let mergeBase = resolution.reference.flatMap { reference in
        head.flatMap { baseGitOutput(rootPath: rootPath, args: ["merge-base", reference.commitID, $0]) }
    }
    let context = GitBaseComparisonContext(
        rootPath: rootPath, branchName: currentBranch, headCommitID: head,
        recordedParentBranch: parent.name, baseBranchName: resolution.name,
        resolvedRef: resolution.reference?.ref, baseCommitID: resolution.reference?.commitID,
        mergeBaseCommitID: mergeBase
    )
    if let issue = parent.issue { return unavailableBase(context: context, message: issue) }
    guard let baseName = resolution.name else {
        return unavailableBase(context: context, message: "No base branch was found for this workspace.")
    }
    guard resolution.reference != nil else {
        return unavailableBase(
            context: context, message: "The base branch \"\(baseName)\" is unavailable locally.")
    }
    guard head != nil else {
        return unavailableBase(
            context: context, message: "The base branch \"\(baseName)\" cannot be compared before the first commit.")
    }
    guard mergeBase != nil else {
        return unavailableBase(context: context, message: "Could not find a merge base with \"\(baseName)\".")
    }
    return loadAgainstBaseComparison(context: context)
}

private func readRecordedParent(rootPath: String, currentBranch: String?) -> (name: String?, issue: String?) {
    guard let currentBranch, !currentBranch.isEmpty, currentBranch != "(detached)" else { return (nil, nil) }
    do {
        let metadata = try RecordedBaseBranchReader().read(repositoryPath: rootPath)
        return (metadata.parents[currentBranch], metadata.conflicts[currentBranch])
    } catch {
        return (nil, "Could not read the recorded base branch: \(error.localizedDescription)")
    }
}

private func loadAgainstBaseComparison(context: GitBaseComparisonContext) -> BaseComparisonResult {
    guard let baseName = context.baseBranchName, let resolvedRef = context.resolvedRef,
        let mergeBase = context.mergeBaseCommitID, let head = context.headCommitID
    else { return unavailableBase(context: context, message: "The committed comparison is unavailable.") }
    do {
        let names = try runBaseGit(
            rootPath: context.rootPath,
            args: [
                "diff", mergeBase, head, "--name-status", "-z", "--find-renames", "--"
            ])
        let stats = try runBaseGit(
            rootPath: context.rootPath,
            args: [
                "diff", mergeBase, head, "--numstat", "-z", "--find-renames", "--"
            ])
        let parsedStats = GitDiffStatParser.parseNUL(stats.stdout)
        let files = GitDiffNameStatusParser.parse(names.stdout).map { record in
            let stat = parsedStats[record.path]
            return GitFileChange(
                path: record.path,
                originalPath: record.originalPath,
                status: record.status,
                additions: stat?.additions,
                deletions: stat?.deletions,
                sectionKind: .againstBase,
                hasStagedChanges: false,
                hasUnstagedChanges: false,
                isUntracked: false,
                diffSource: .againstBase(baseName: baseName, resolvedRef: resolvedRef)
            )
        }
        return BaseComparisonResult(context: context, files: files, state: .available)
    } catch let error as GitStatusServiceError {
        return unavailableBase(
            context: context, message: "Could not compare this branch with \"\(baseName)\": \(error.message)")
    } catch {
        return unavailableBase(
            context: context,
            message: "Could not compare this branch with \"\(baseName)\": \(error.localizedDescription)")
    }
}

private func resolveBaseBranch(
    rootPath: String,
    presentation: GitStatusPresentation,
    currentBranch: String?,
    recordedParent: String?
) -> BaseBranchResolution {
    if let recordedParent, recordedParent != currentBranch, GitReferenceValidation.isValidBranchName(recordedParent) {
        let reference = resolveBaseReference(
            rootPath: rootPath, candidates: ["refs/heads/\(recordedParent)", "refs/remotes/origin/\(recordedParent)"])
        return BaseBranchResolution(name: recordedParent, reference: reference)
    }
    let configuredName = presentation.configuredBaseBranch?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedConfiguredName = configuredName.flatMap { name in name.isEmpty ? nil : name }
    if let name = normalizedConfiguredName {
        return BaseBranchResolution(name: name, reference: resolveBaseRef(rootPath: rootPath, name: name))
    }
    guard let inferredName = inferBaseBranchName(rootPath: rootPath, currentBranch: currentBranch) else {
        return BaseBranchResolution(name: nil, reference: nil)
    }
    let reference = resolveBaseRef(
        rootPath: rootPath, name: inferredName.name, preferredRef: inferredName.preferredRef)
    return BaseBranchResolution(name: inferredName.name, reference: reference)
}

private func inferBaseBranchName(
    rootPath: String,
    currentBranch: String?
) -> (name: String, preferredRef: String?)? {
    if let remoteHead = baseGitOutput(
        rootPath: rootPath, args: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]
    ), remoteHead.hasPrefix("refs/remotes/origin/") {
        let candidate = String(remoteHead.dropFirst("refs/remotes/origin/".count))
        if !candidate.isEmpty, candidate != currentBranch {
            return (name: candidate, preferredRef: "refs/remotes/origin/HEAD")
        }
    }
    if currentBranch != "main", resolveBaseCommit(rootPath: rootPath, ref: "refs/heads/main") != nil {
        return (name: "main", preferredRef: nil)
    }
    if currentBranch != "master", resolveBaseCommit(rootPath: rootPath, ref: "refs/heads/master") != nil {
        return (name: "master", preferredRef: nil)
    }
    return nil
}

private func resolveBaseRef(rootPath: String, name: String, preferredRef: String? = nil) -> BaseBranchReference? {
    resolveBaseReference(
        rootPath: rootPath,
        candidates: [preferredRef, "refs/remotes/origin/\(name)", "refs/heads/\(name)"].compactMap { $0 })
}

private func resolveBaseReference(rootPath: String, candidates: [String]) -> BaseBranchReference? {
    for ref in candidates {
        if let commitID = resolveBaseCommit(rootPath: rootPath, ref: ref) {
            return BaseBranchReference(ref: ref, commitID: commitID)
        }
    }
    return nil
}

private func resolveBaseCommit(rootPath: String, ref: String) -> String? {
    baseGitOutput(rootPath: rootPath, args: ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
}

private func baseGitOutput(rootPath: String, args: [String]) -> String? {
    guard let result = try? runBaseGit(rootPath: rootPath, args: args) else { return nil }
    let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
}

private func runBaseGit(rootPath: String, args: [String]) throws -> GitCommandResult {
    try runGit(
        args: ["-C", rootPath] + args,
        environment: GitCommandEnvironment.standard.merging([
            "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1"
        ]) { _, new in new }
    )
}

private func unavailableBase(context: GitBaseComparisonContext, message: String) -> BaseComparisonResult {
    BaseComparisonResult(context: context, files: [], state: .unavailable(message: message))
}
