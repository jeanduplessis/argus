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

struct GitPreview: Equatable, Sendable {
    let kind: GitPreviewKind
    let path: String
    let output: String
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

    init(commandBuilder: GitPreviewCommandBuilder = GitPreviewCommandBuilder()) {
        self.commandBuilder = commandBuilder
    }

    func preview(kind: GitPreviewKind, rootPath: String, file: GitFileChange) async -> GitPreviewLoadState {
        await Task.detached(priority: .utility) {
            guard let command = self.commandBuilder.command(kind: kind, rootPath: rootPath, file: file) else {
                return .failed(kind: kind, path: file.path, message: "Preview is unavailable for this file")
            }
            do {
                let output = try runPreviewCommand(command)
                return .loaded(GitPreview(kind: kind, path: file.path, output: output))
            } catch {
                return .failed(kind: kind, path: file.path, message: error.localizedDescription)
            }
        }.value
    }
}

struct GitPreviewCommandBuilder: Sendable {
    private let difftasticPathProvider: @Sendable () -> String?

    init(difftasticPathProvider: @escaping @Sendable () -> String? = { Self.defaultDifftasticPath() }) {
        self.difftasticPathProvider = difftasticPathProvider
    }

    func command(kind: GitPreviewKind, rootPath: String, file: GitFileChange) -> GitPreviewCommand? {
        switch kind {
        case .diff:
            return diffCommand(rootPath: rootPath, file: file)
        case .blame:
            return blameCommand(rootPath: rootPath, file: file)
        }
    }

    private func diffCommand(rootPath: String, file: GitFileChange) -> GitPreviewCommand {
        var arguments = ["-C", rootPath, "diff", "--color=always"]
        if let difftasticPath = difftasticPathProvider() {
            arguments.insert(contentsOf: ["-c", "diff.external=\(difftasticPath)"], at: 2)
        } else {
            arguments.insert("--no-ext-diff", at: arguments.firstIndex(of: "--color=always") ?? arguments.endIndex)
        }
        switch file.sectionKey {
        case "staged":
            arguments.append("--cached")
            arguments.append(contentsOf: ["--", file.path])
            return GitPreviewCommand(executablePath: "/usr/bin/git", arguments: arguments, successfulExitCodes: [0])
        case "untracked":
            arguments.insert("--no-index", at: arguments.firstIndex(of: "--color=always") ?? arguments.endIndex)
            arguments.append(contentsOf: ["--", "/dev/null", file.path])
            return GitPreviewCommand(executablePath: "/usr/bin/git", arguments: arguments, successfulExitCodes: [0, 1])
        default:
            arguments.append(contentsOf: ["--", file.path])
            return GitPreviewCommand(executablePath: "/usr/bin/git", arguments: arguments, successfulExitCodes: [0])
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

    private static func defaultDifftasticPath() -> String? {
        let candidates = ["/opt/homebrew/bin/difft", "/usr/local/bin/difft", "/usr/bin/difft"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct GitPreviewCommandError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private func runPreviewCommand(_ command: GitPreviewCommand) throws -> String {
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
    process.waitUntilExit()

    let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    guard command.successfulExitCodes.contains(process.terminationStatus) else {
        let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        throw GitPreviewCommandError(message: message.isEmpty ? "preview command failed" : message)
    }

    return stdoutText.isEmpty ? stderrText : stdoutText
}
