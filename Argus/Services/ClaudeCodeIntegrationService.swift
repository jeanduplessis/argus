import Combine
import Darwin
import Foundation

enum ClaudeCodeIntegrationError: LocalizedError {
    case companionCLIUnavailable
    case invalidSettings(String)
    case lockFailed(String)

    var errorDescription: String? {
        switch self {
        case .companionCLIUnavailable:
            "This Argus build does not bundle the Companion CLI that the Claude Code hooks run."
        case .invalidSettings(let detail):
            "Claude Code settings validation failed: \(detail)"
        case .lockFailed(let detail):
            "Could not lock Claude Code settings: \(detail)"
        }
    }
}

@MainActor
final class ClaudeCodeIntegrationModel: ObservableObject {
    enum Status: Equatable {
        case unavailable
        case installed
        case busy
        case failed(String)
    }

    @Published private(set) var status: Status = .unavailable
    @Published private(set) var managedSettingsPath = ""

    private let service: ClaudeCodeIntegrationService

    init(service: ClaudeCodeIntegrationService = ClaudeCodeIntegrationService()) {
        self.service = service
        refresh()
    }

    func refresh() {
        let paths = service.resolvedPaths()
        managedSettingsPath = paths.settingsFile.path
        status = service.isInstalled(at: paths) ? .installed : .unavailable
    }

    func enable() { update(.enable) }
    func disable() { update(.disable) }

    private func update(_ operation: ClaudeCodeIntegrationOperation) {
        status = .busy
        Task {
            do {
                let paths = try await Task.detached(priority: .userInitiated) {
                    try operation == .enable ? self.service.enable() : self.service.disable()
                }.value
                managedSettingsPath = paths.settingsFile.path
                status = operation == .enable ? .installed : .unavailable
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

private enum ClaudeCodeIntegrationOperation: Sendable { case enable, disable }

/// Installs only Argus's Claude Code hook entries in the user's settings.
///
/// The hooks run the bundled Companion CLI, so there is no plugin file to own.
final class ClaudeCodeIntegrationService: @unchecked Sendable {
    let environment: [String: String]
    let homeDirectory: URL
    private let isCompanionCLIBundled: Bool
    private let fileManager: FileManager

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isCompanionCLIBundled: Bool = TerminalEnvironment.bundledToolsDirectory() != nil,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isCompanionCLIBundled = isCompanionCLIBundled
        self.fileManager = fileManager
    }

    struct Paths: Equatable {
        let configDirectory: URL
        let settingsFile: URL
        let lockFile: URL
    }

    func resolvedPaths() -> Paths {
        let directory: URL
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            directory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        return Paths(
            configDirectory: directory,
            settingsFile: directory.appendingPathComponent("settings.json"),
            lockFile: directory.appendingPathComponent(".argus-claude-code-integration.lock")
        )
    }

    func enable() throws -> Paths { try update(.enable) }
    func disable() throws -> Paths { try update(.disable) }

    func isInstalled(at paths: Paths) -> Bool {
        guard let text = try? String(contentsOf: paths.settingsFile, encoding: .utf8) else { return false }
        return ClaudeCodeSettingsEditor.isInstalled(in: text)
    }

    private func update(_ operation: ClaudeCodeSettingsEditor.Operation) throws -> Paths {
        let paths = resolvedPaths()
        if operation == .disable, !fileManager.fileExists(atPath: paths.settingsFile.path) {
            return paths
        }
        if operation == .enable, !isCompanionCLIBundled {
            throw ClaudeCodeIntegrationError.companionCLIUnavailable
        }

        try fileManager.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        let descriptor = open(paths.lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ClaudeCodeIntegrationError.lockFailed(String(cString: strerror(errno)))
        }
        defer { close(descriptor) }
        try acquireIntegrationLock(descriptor)
        defer { flock(descriptor, LOCK_UN) }

        // Write through a symlinked settings file so dotfile links survive.
        let target = paths.settingsFile.resolvingSymlinksInPath()
        let original: String
        if fileManager.fileExists(atPath: target.path) {
            guard let text = String(data: try Data(contentsOf: target), encoding: .utf8) else {
                throw ClaudeCodeIntegrationError.invalidSettings("not UTF-8")
            }
            original = text
        } else {
            original = ""
        }

        let edited: String
        do {
            edited = try ClaudeCodeSettingsEditor.edit(original, operation: operation)
        } catch {
            throw ClaudeCodeIntegrationError.invalidSettings(error.localizedDescription)
        }
        if edited != original {
            try atomicWrite(Data(edited.utf8), to: target)
        }
        return paths
    }

    private func acquireIntegrationLock(_ descriptor: Int32) throws {
        let deadline = Date().addingTimeInterval(2)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw ClaudeCodeIntegrationError.lockFailed(String(cString: strerror(errno)))
            }
            guard !Task.isCancelled, Date() < deadline else {
                throw ClaudeCodeIntegrationError.lockFailed("Timed out waiting for the integration lock")
            }
            usleep(50_000)
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? fileManager.removeItem(at: temporary) }
        if fileManager.fileExists(atPath: url.path) {
            // Keep the user's file mode; settings can hold credentials-adjacent values.
            if let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
