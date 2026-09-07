import CryptoKit
import Darwin
import Foundation

struct StackFileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    init(_ information: stat) {
        device = information.st_dev
        inode = information.st_ino
    }

    static func directory(at path: String) throws -> StackFileIdentity {
        var information = stat()
        guard lstat(path, &information) == 0, information.st_mode & S_IFMT == S_IFDIR else {
            throw StackParentError.checkoutUnavailable
        }
        return StackFileIdentity(information)
    }
}

struct StackFileVersion: Equatable, Sendable {
    let identity: StackFileIdentity
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let permissions: UInt16
    let digest: Data

    static func read(at path: String) throws -> (version: StackFileVersion, data: Data) {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StackParentError.configurationUnavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            throw StackParentError.configurationUnavailable
        }
        let limit = RecordedBaseBranchReader.maximumMetadataBytes
        guard before.st_size <= limit else { throw StackParentError.configurationTooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw StackParentError.configurationTooLarge }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0, lstat(path, &current) == 0,
            StackFileIdentity(before) == StackFileIdentity(current),
            before.st_size == after.st_size, data.count == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw StackParentError.configurationChanged }
        return (
            StackFileVersion(
                identity: StackFileIdentity(after),
                modifiedSeconds: after.st_mtimespec.tv_sec,
                modifiedNanoseconds: after.st_mtimespec.tv_nsec,
                permissions: after.st_mode & 0o777,
                digest: Data(SHA256.hash(data: data))),
            data
        )
    }
}

struct StackParentConfiguration: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let scope: String
        let origin: String
        let value: String
    }

    let path: String
    let version: StackFileVersion
    let localValues: [String]
    let effectiveEntries: [Entry]

    var editingIssue: String? {
        if localValues.count > 1 {
            return "This branch has multiple repository-local parent values. Resolve them in \(path) before editing."
        }
        for entry in effectiveEntries {
            if entry.scope == "worktree" || entry.scope == "command" {
                return "A higher-precedence \(entry.scope) configuration supplies this parent. "
                    + "Argus only edits repository-local configuration."
            }
            if entry.scope == "local", !isDirectLocal(entry) {
                return "An included repository configuration supplies this parent. "
                    + "Argus will not edit included files or write a potentially ineffective override."
            }
            if !["system", "global", "local"].contains(entry.scope) {
                return "The parent configuration source cannot be edited safely from repository-local configuration."
            }
        }
        return nil
    }

    var sourceDescription: String {
        guard let entry = effectiveEntries.last else { return "No branch-base configuration" }
        switch entry.scope {
        case "local":
            return isDirectLocal(entry) ? "Repository-local configuration" : "Included repository-local configuration"
        case "global": return "Global configuration"
        case "system": return "System configuration"
        case "worktree": return "Worktree configuration"
        case "command": return "Command configuration"
        default: return "Unrecognized configuration source"
        }
    }

    private func isDirectLocal(_ entry: Entry) -> Bool {
        guard entry.origin.hasPrefix("file:") else { return false }
        let origin = String(entry.origin.dropFirst("file:".count))
        return origin.hasPrefix("/") && StackGitCommand.canonicalPath(origin) == path
    }

    static func read(checkout: StackCheckoutIdentity, git: StackGitCommand) throws -> StackParentConfiguration {
        let path = URL(fileURLWithPath: checkout.gitCommonDirectory).appendingPathComponent("config").path
        let before = try StackFileVersion.read(at: path).version
        let key = "branch.\(checkout.branchName).base"
        let local = try git.run(
            ["config", "--local", "--no-includes", "--null", "--get-all", key], at: checkout.worktreePath)
        let localValues = try fields(local)
        let effective = try git.run(
            ["config", "--null", "--includes", "--show-scope", "--show-origin", "--get-all", key],
            at: checkout.worktreePath)
        let values = try fields(effective)
        guard values.count.isMultiple(of: 3),
            localValues.allSatisfy({ $0.utf8.count <= RecordedBaseBranchReader.maximumBranchNameBytes })
        else { throw StackParentError.configurationUnavailable }
        var entries: [Entry] = []
        for index in stride(from: 0, to: values.count, by: 3) {
            guard values[index + 2].utf8.count <= RecordedBaseBranchReader.maximumBranchNameBytes else {
                throw StackParentError.configurationUnavailable
            }
            let rawOrigin = values[index + 1]
            let origin: String
            if rawOrigin.hasPrefix("file:") {
                let file = String(rawOrigin.dropFirst("file:".count))
                let absolute = file.hasPrefix("/") ? file : checkout.worktreePath + "/" + file
                origin = "file:" + StackGitCommand.canonicalPath(absolute)
            } else {
                origin = rawOrigin
            }
            entries.append(Entry(scope: values[index], origin: origin, value: values[index + 2]))
        }
        guard try StackFileVersion.read(at: path).version == before else {
            throw StackParentError.configurationChanged
        }
        return StackParentConfiguration(
            path: path, version: before, localValues: localValues, effectiveEntries: entries)
    }

    static func fields(_ result: ExternalProcessResult) throws -> [String] {
        if result.terminationStatus == 1, result.stdout.isEmpty { return [] }
        guard result.terminationStatus == 0, let output = String(data: result.stdout, encoding: .utf8),
            output.hasSuffix("\0")
        else { throw StackParentError.configurationUnavailable }
        return output.dropLast().components(separatedBy: "\0")
    }
}

struct StackLocalConfigurationWrite: Sendable {
    let path: String
    let before: Data
    let after: StackFileVersion
}

struct StackLocalConfiguration: Sendable {
    let git: StackGitCommand

    func replace(
        parent: String?, branch: String, expected: StackParentConfiguration,
        worktreePath: String, validate: () throws -> Void
    ) throws -> StackLocalConfigurationWrite {
        let original = try StackFileVersion.read(at: expected.path)
        guard original.version == expected.version else { throw StackParentError.configurationChanged }
        let lockPath = expected.path + ".lock"
        var owned = try reserve(lockPath, data: original.data, permissions: original.version.permissions)
        var committed = false
        defer {
            if !committed { removeUnchangedLock(lockPath, version: owned) }
        }
        do {
            try validate()
            let arguments =
                ["config", "--file", lockPath, "--no-includes"]
                + (parent.map { ["--replace-all", "branch.\(branch).base", $0] }
                    ?? ["--unset-all", "branch.\(branch).base"])
            let result = try git.run(arguments, at: worktreePath)
            let staged = try StackFileVersion.read(at: lockPath)
            owned = staged.version
            guard result.terminationStatus == 0 else { throw StackParentError.configurationWriteFailed(expected.path) }
            let values = try StackParentConfiguration.fields(
                git.run(
                    ["config", "--file", lockPath, "--no-includes", "--null", "--get-all", "branch.\(branch).base"],
                    at: worktreePath))
            guard values == (parent.map { [$0] } ?? []) else { throw StackParentError.readbackFailed }
            try validate()
            try Task.checkCancellation()
            guard try StackFileVersion.read(at: expected.path).version == original.version,
                try StackFileVersion.read(at: lockPath).version == owned
            else { throw StackParentError.configurationChanged }
            guard rename(lockPath, expected.path) == 0 else {
                throw StackParentError.configurationWriteFailed(expected.path)
            }
            committed = true
            return StackLocalConfigurationWrite(path: expected.path, before: original.data, after: owned)
        } catch {
            if (try? StackFileVersion.read(at: lockPath).version) != owned {
                throw StackParentError.configurationWriteFailed(expected.path)
            }
            throw error
        }
    }

    func restore(_ write: StackLocalConfigurationWrite) throws -> Bool {
        guard try StackFileVersion.read(at: write.path).version == write.after else { return false }
        let lockPath = write.path + ".lock"
        let owned = try reserve(lockPath, data: write.before, permissions: write.after.permissions)
        var committed = false
        defer {
            if !committed { removeUnchangedLock(lockPath, version: owned) }
        }
        guard try StackFileVersion.read(at: write.path).version == write.after,
            try StackFileVersion.read(at: lockPath).version == owned
        else { return false }
        guard rename(lockPath, write.path) == 0 else { return false }
        committed = true
        return true
    }

    private func reserve(_ path: String, data: Data, permissions: UInt16) throws -> StackFileVersion {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StackParentError.configurationWriteFailed(String(path.dropLast(5))) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            guard fchmod(descriptor, mode_t(permissions)) == 0 else {
                throw StackParentError.configurationUnavailable
            }
            try handle.synchronize()
            return try StackFileVersion.read(at: path).version
        } catch {
            var owned = stat()
            var current = stat()
            if fstat(descriptor, &owned) == 0, lstat(path, &current) == 0,
                StackFileIdentity(owned) == StackFileIdentity(current)
            {
                _ = unlink(path)
            }
            throw StackParentError.configurationWriteFailed(String(path.dropLast(5)))
        }
    }

    private func removeUnchangedLock(_ path: String, version: StackFileVersion) {
        if (try? StackFileVersion.read(at: path).version) == version { _ = unlink(path) }
    }
}
