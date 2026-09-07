import Darwin
import Foundation

struct DependentCheckoutSafety: Sendable {
    let git: StackGitCommand

    func filterBlockingArguments(at path: String, sourceCommit: String? = nil) throws -> [String] {
        let drivers = try configuredDrivers(at: path)
        let listing = try git.output(
            sourceCommit.map { ["ls-tree", "-r", "-z", "--name-only", "--full-tree", $0] }
                ?? ["ls-files", "--cached", "-z"], at: path)
        let paths = try nulFields(listing)
        var batch: [String] = []
        var byteCount = 0
        for file in paths {
            guard file.utf8.count < 16_384 else { throw StackParentError.outputTooLarge }
            if byteCount + file.utf8.count + 1 > 16_384 {
                try requireUnfiltered(batch, at: path, sourceCommit: sourceCommit, drivers: drivers)
                batch.removeAll(keepingCapacity: true)
                byteCount = 0
            }
            batch.append(file)
            byteCount += file.utf8.count + 1
        }
        try requireUnfiltered(batch, at: path, sourceCommit: sourceCommit, drivers: drivers)
        let arguments = drivers.sorted().flatMap { driver in
            [
                "-c", "filter.\(driver).clean=", "-c", "filter.\(driver).smudge=",
                "-c", "filter.\(driver).process=", "-c", "filter.\(driver).required=true"
            ]
        }
        guard arguments.reduce(0, { $0 + $1.utf8.count + 1 }) <= 32_768 else {
            throw StackParentError.outputTooLarge
        }
        return arguments
    }

    func requireUnchangedIndex(at path: String, headCommitID: String) throws {
        let result = try git.run(
            [
                "diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none",
                headCommitID, "--"
            ],
            at: path)
        guard result.terminationStatus == 0 else { throw DependentWorkspaceError.resourcesChanged }
    }

    func gitlinkPaths(at path: String, sourceCommit: String? = nil) throws -> [String] {
        let output = try git.output(
            sourceCommit.map { ["ls-tree", "-r", "-z", "--full-tree", $0] } ?? ["ls-files", "--stage", "-z"],
            at: path)
        return try nulFields(output).compactMap { record in
            guard record.hasPrefix("160000 ") else { return nil }
            guard let separator = record.firstIndex(of: "\t") else { throw StackParentError.commandFailed }
            return String(record[record.index(after: separator)...])
        }
    }

    func requireUnpopulatedSubmodules(at path: String, headCommitID: String) throws {
        for relativePath in try gitlinkPaths(at: path, sourceCommit: headCommitID) {
            let directory = URL(fileURLWithPath: path).appendingPathComponent(relativePath).standardizedFileURL.path
            guard directory.hasPrefix(path + "/"), StackGitCommand.canonicalPath(directory) == directory else {
                throw DependentWorkspaceError.resourcesChanged
            }
            var information = stat()
            if lstat(directory, &information) != 0 {
                guard errno == ENOENT else { throw DependentWorkspaceError.resourcesChanged }
                continue
            }
            guard information.st_mode & S_IFMT == S_IFDIR,
                try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty
            else { throw DependentWorkspaceError.resourcesChanged }
        }
    }

    private func configuredDrivers(at path: String) throws -> Set<String> {
        let result = try git.run(
            [
                "config", "--null", "--includes", "--name-only", "--get-regexp",
                "^filter\\..*\\.(clean|smudge|process|required)$"
            ],
            at: path)
        let keys = try StackParentConfiguration.fields(result)
        var drivers = Set<String>()
        for key in keys {
            guard key.hasPrefix("filter."), let separator = key.lastIndex(of: ".") else {
                throw StackParentError.configurationUnavailable
            }
            let driver = String(key[key.index(key.startIndex, offsetBy: "filter.".count)..<separator])
            guard !driver.isEmpty, !driver.contains("="),
                !driver.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw DependentWorkspaceError.checkoutFiltersUnsupported(recovery: nil) }
            drivers.insert(driver)
        }
        return drivers
    }

    private func requireUnfiltered(
        _ files: [String], at path: String, sourceCommit: String?, drivers: Set<String>
    ) throws {
        guard !files.isEmpty else { return }
        let arguments =
            ["check-attr", "-z"] + (sourceCommit.map { ["--source=\($0)"] } ?? [])
            + ["filter", "--"] + files
        let fields = try nulFields(git.output(arguments, at: path))
        guard fields.count == files.count * 3 else { throw StackParentError.commandFailed }
        for index in files.indices {
            guard fields[index * 3] == files[index], fields[index * 3 + 1] == "filter" else {
                throw StackParentError.commandFailed
            }
            let value = fields[index * 3 + 2]
            guard value == "unspecified" || value == "unset", !drivers.contains(value) else {
                throw DependentWorkspaceError.checkoutFiltersUnsupported(recovery: nil)
            }
        }
    }

    private func nulFields(_ output: String) throws -> [String] {
        if output.isEmpty { return [] }
        guard output.hasSuffix("\0") else { throw StackParentError.commandFailed }
        return output.dropLast().components(separatedBy: "\0")
    }
}
