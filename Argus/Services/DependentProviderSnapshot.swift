import Darwin
import Foundation

struct DependentProviderSnapshot: Equatable, Sendable {
    let ghStackFiles: [String: StackFileVersion]
    let graphiteReferences: String

    static func read(commonDirectory: String, repositoryPath: String, git: StackGitCommand) throws -> Self {
        let arguments = [
            "for-each-ref", "--sort=refname", "--format=%(refname)%00%(objectname)%00%(symref)", "refs/branch-metadata/"
        ]
        let references = try git.output(arguments, at: repositoryPath)
        let root = URL(fileURLWithPath: commonDirectory)
        var paths = [root.appendingPathComponent("gh-stack").path]
        let administrativeRoot = root.appendingPathComponent("worktrees", isDirectory: true)
        if try exists(administrativeRoot.path) {
            _ = try StackFileIdentity.directory(at: administrativeRoot.path)
            let directories = try FileManager.default.contentsOfDirectory(
                at: administrativeRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for directory in directories {
                try Task.checkCancellation()
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    paths.append(directory.appendingPathComponent("gh-stack").path)
                }
            }
        }
        guard paths.reduce(0, { $0 + $1.utf8.count }) <= RecordedBaseBranchReader.maximumMetadataBytes else {
            throw StackParentError.outputTooLarge
        }
        var files: [String: StackFileVersion] = [:]
        for path in paths.sorted() {
            try Task.checkCancellation()
            if try exists(path) { files[path] = try StackFileVersion.read(at: path).version }
        }
        guard try git.output(arguments, at: repositoryPath) == references else {
            throw DependentWorkspaceError.resourcesChanged
        }
        return Self(ghStackFiles: files, graphiteReferences: references)
    }

    private static func exists(_ path: String) throws -> Bool {
        var information = stat()
        if lstat(path, &information) == 0 { return true }
        guard errno == ENOENT else { throw DependentWorkspaceError.resourcesChanged }
        return false
    }
}
