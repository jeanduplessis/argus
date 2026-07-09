import Foundation

struct GitPreviewCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let successfulExitCodes: Set<Int32>
}

enum GitPreviewKind: Equatable, Sendable {
    case diff
    case blame
}

enum GitPreviewContent: Equatable, Sendable {
    case diff(GitDiffPreview)
    case ansiText(String)
}

struct GitDiffPreview: Equatable, Sendable {
    let fileName: String
    let oldContent: String
    let newContent: String
}

struct GitPreview: Equatable, Sendable {
    let kind: GitPreviewKind
    let path: String
    let content: GitPreviewContent
}

enum GitPreviewLoadState: Equatable, Sendable {
    case loaded(GitPreview)
    case failed(kind: GitPreviewKind, path: String, message: String)
}

protocol GitPreviewProviding: Sendable {
    func preview(kind: GitPreviewKind, rootPath: String, file: GitFileChange) async -> GitPreviewLoadState
}

final class GitPreviewService: GitPreviewProviding {
    private let commandBuilder: GitPreviewCommandBuilder
    private let commandRunner: GitPreviewCommandRunner
    private let diffContentLoader: GitDiffContentLoader

    init(
        commandBuilder: GitPreviewCommandBuilder = GitPreviewCommandBuilder(),
        commandRunner: GitPreviewCommandRunner = GitPreviewCommandRunner(),
        diffContentLoader: GitDiffContentLoader? = nil
    ) {
        self.commandBuilder = commandBuilder
        self.commandRunner = commandRunner
        self.diffContentLoader = diffContentLoader ?? GitDiffContentLoader(commandRunner: commandRunner)
    }

    func preview(kind: GitPreviewKind, rootPath: String, file: GitFileChange) async -> GitPreviewLoadState {
        await Task.detached(priority: .utility) {
            do {
                let content: GitPreviewContent
                switch kind {
                case .diff:
                    content = try self.diffContentLoader.load(rootPath: rootPath, file: file)
                case .blame:
                    guard
                        let command = self.commandBuilder.command(
                            kind: kind,
                            rootPath: rootPath,
                            file: file
                        )
                    else {
                        return .failed(
                            kind: kind,
                            path: file.path,
                            message: "Preview is unavailable for this file"
                        )
                    }
                    let result = try self.commandRunner.run(command)
                    let output = result.stdout.isEmpty ? result.stderr : result.stdout
                    content = .ansiText(String(bytes: output, encoding: .utf8) ?? "")
                }
                return .loaded(GitPreview(kind: kind, path: file.path, content: content))
            } catch {
                return .failed(kind: kind, path: file.path, message: error.localizedDescription)
            }
        }.value
    }
}

struct GitPreviewCommandBuilder: Sendable {
    func command(kind: GitPreviewKind, rootPath: String, file: GitFileChange) -> GitPreviewCommand? {
        switch kind {
        case .diff:
            return nil
        case .blame:
            return blameCommand(rootPath: rootPath, file: file)
        }
    }

    private func blameCommand(rootPath: String, file: GitFileChange) -> GitPreviewCommand? {
        guard file.sectionKey != "untracked", file.status != .untracked else { return nil }
        return GitPreviewCommand(
            executablePath: "/usr/bin/git",
            arguments: ["-C", rootPath, "blame", "--color-lines", "--color-by-age", "--", file.path],
            successfulExitCodes: [0]
        )
    }
}

struct GitPreviewCommandResult: Sendable {
    let stdout: Data
    let stderr: Data
}

struct GitPreviewCommandRunner: Sendable {
    private let operation: @Sendable (GitPreviewCommand) throws -> GitPreviewCommandResult

    init(operation: (@Sendable (GitPreviewCommand) throws -> GitPreviewCommandResult)? = nil) {
        self.operation = operation ?? runPreviewCommand
    }

    func run(_ command: GitPreviewCommand) throws -> GitPreviewCommandResult {
        try operation(command)
    }
}

struct GitDiffContentLoader: Sendable {
    static let maximumFileSize = 2 * 1_024 * 1_024
    static let maximumLineLength = 20_000

    private let commandRunner: GitPreviewCommandRunner

    init(commandRunner: GitPreviewCommandRunner = GitPreviewCommandRunner()) {
        self.commandRunner = commandRunner
    }

    func load(rootPath: String, file: GitFileChange) throws -> GitPreviewContent {
        do {
            let sides = try contentSides(rootPath: rootPath, file: file)
            return .diff(
                GitDiffPreview(
                    fileName: file.path,
                    oldContent: try text(from: sides.old),
                    newContent: try text(from: sides.new)
                ))
        } catch GitDiffContentError.binary {
            return .ansiText("Binary file differs")
        } catch GitDiffContentError.tooLarge {
            return .ansiText("File is too large to preview")
        }
    }

    private func contentSides(rootPath: String, file: GitFileChange) throws -> (old: Data, new: Data) {
        switch file.sectionKey {
        case "staged":
            return try stagedContentSides(rootPath: rootPath, file: file)
        case "unstaged":
            return try unstagedContentSides(rootPath: rootPath, file: file)
        case "untracked":
            return (Data(), try workingTreeFile(rootPath: rootPath, path: file.path))
        default:
            throw GitDiffContentError.unavailable("Diff preview is unavailable for this file")
        }
    }

    private func stagedContentSides(
        rootPath: String,
        file: GitFileChange
    ) throws -> (old: Data, new: Data) {
        switch file.status {
        case .added:
            return (Data(), try gitObject(rootPath: rootPath, specifier: ":\(file.path)"))
        case .deleted:
            return (try gitObject(rootPath: rootPath, specifier: "HEAD:\(file.path)"), Data())
        case .renamed, .copied:
            let originalPath = file.originalPath ?? file.path
            return (
                try gitObject(rootPath: rootPath, specifier: "HEAD:\(originalPath)"),
                try gitObject(rootPath: rootPath, specifier: ":\(file.path)")
            )
        case .unmerged:
            throw GitDiffContentError.unavailable("Diff preview is unavailable for unmerged files")
        default:
            return (
                try gitObject(rootPath: rootPath, specifier: "HEAD:\(file.path)"),
                try gitObject(rootPath: rootPath, specifier: ":\(file.path)")
            )
        }
    }

    private func unstagedContentSides(
        rootPath: String,
        file: GitFileChange
    ) throws -> (old: Data, new: Data) {
        switch file.status {
        case .deleted:
            return (try gitObject(rootPath: rootPath, specifier: ":\(file.path)"), Data())
        case .renamed:
            let originalPath = file.originalPath ?? file.path
            return (
                try gitObject(rootPath: rootPath, specifier: ":\(originalPath)"),
                try workingTreeFile(rootPath: rootPath, path: file.path)
            )
        case .unmerged:
            throw GitDiffContentError.unavailable("Diff preview is unavailable for unmerged files")
        default:
            return (
                try gitObject(rootPath: rootPath, specifier: ":\(file.path)"),
                try workingTreeFile(rootPath: rootPath, path: file.path)
            )
        }
    }

    private func gitObject(rootPath: String, specifier: String) throws -> Data {
        let sizeResult = try commandRunner.run(
            GitPreviewCommand(
                executablePath: "/usr/bin/git",
                arguments: ["-C", rootPath, "cat-file", "-s", specifier],
                successfulExitCodes: [0]
            ))
        let sizeText = (String(bytes: sizeResult.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let size = Int(sizeText), size > Self.maximumFileSize {
            throw GitDiffContentError.tooLarge
        }

        let result = try commandRunner.run(
            GitPreviewCommand(
                executablePath: "/usr/bin/git",
                arguments: ["-C", rootPath, "cat-file", "blob", specifier],
                successfulExitCodes: [0]
            ))
        return result.stdout
    }

    private func workingTreeFile(rootPath: String, path: String) throws -> Data {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileURL = rootURL.appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else {
            throw GitDiffContentError.unavailable("File path is outside the repository")
        }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw GitDiffContentError.unavailable("Diff preview is unavailable for this file")
        }
        if let fileSize = values.fileSize, fileSize > Self.maximumFileSize {
            throw GitDiffContentError.tooLarge
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    private func text(from data: Data) throws -> String {
        if data.count > Self.maximumFileSize {
            throw GitDiffContentError.tooLarge
        }
        guard !data.contains(0), let contents = String(data: data, encoding: .utf8) else {
            throw GitDiffContentError.binary
        }
        if contents.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.utf8.count > Self.maximumLineLength })
        {
            throw GitDiffContentError.tooLarge
        }
        return contents
    }
}

private enum GitDiffContentError: LocalizedError {
    case binary
    case tooLarge
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .binary:
            return "Binary file differs"
        case .tooLarge:
            return "File is too large to preview"
        case .unavailable(let message):
            return message
        }
    }
}

private struct GitPreviewCommandError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class GitPreviewDataBox: @unchecked Sendable {
    var data = Data()
}

private func runPreviewCommand(_ command: GitPreviewCommand) throws -> GitPreviewCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command.executablePath)
    process.arguments = command.arguments
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "echo"
    ]) { _, new in new }

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let group = DispatchGroup()
    let stdoutBox = GitPreviewDataBox()
    let stderrBox = GitPreviewDataBox()
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        stdoutBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        stderrBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    process.waitUntilExit()
    group.wait()

    guard command.successfulExitCodes.contains(process.terminationStatus) else {
        let message = (String(bytes: stderrBox.data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitPreviewCommandError(message: message.isEmpty ? "preview command failed" : message)
    }

    return GitPreviewCommandResult(stdout: stdoutBox.data, stderr: stderrBox.data)
}
