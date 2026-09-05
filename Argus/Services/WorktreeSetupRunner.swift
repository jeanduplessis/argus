import Darwin
import Foundation

/// Local opt-in only. Preserve shell source exactly; do not interpolate checkout metadata.
enum WorktreeSetupCommand {
    static let maximumBytes = 16 * 1024

    static func validated(_ command: String) throws -> String? {
        guard !command.utf8.contains(0), command.utf8.count <= maximumBytes else {
            throw WorktreeSetupConfigurationError.invalidCommand
        }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
    }
}

enum WorktreeSetupConfigurationError: LocalizedError {
    case invalidCommand
    case projectUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCommand: "Use at most 16 KiB of command text, without NUL characters."
        case .projectUnavailable: "The Named Project is no longer available."
        }
    }
}

struct WorktreeSetupRequest: Sendable {
    let command: String
    let rootPath: String
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var timeout: TimeInterval = 3600
}

enum WorktreeSetupOutcome: Equatable, Sendable {
    case succeeded
    case exited(Int32)
    case failedLaunch(String)
    case timedOut
    case cancelled
    case ownershipChanged

    var label: String {
        switch self {
        case .succeeded: "Succeeded (exit 0)"
        case .exited(let code): "Failed (exit \(code))"
        case .failedLaunch(let detail): "Could not start: \(detail)"
        case .timedOut: "Timed out"
        case .cancelled: "Stopped"
        case .ownershipChanged: "Workspace ownership changed; result discarded"
        }
    }
}

struct WorktreeSetupResult: Sendable {
    let outcome: WorktreeSetupOutcome
    var terminationConfirmed = true
}

struct WorktreeSetupOutput: Sendable {
    let text: String
    let truncated: Bool
}

/// A cancellation flag is independent of view and Swift Task lifetimes.
final class WorktreeSetupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var cleanup: (@Sendable () async -> Bool)?

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }

    func retainCleanup(_ operation: @escaping @Sendable () async -> Bool) {
        lock.withLock { cleanup = operation }
    }

    func retryCleanup() async -> Bool {
        guard let operation = lock.withLock({ cleanup }) else { return false }
        let stopped = await operation()
        if stopped { lock.withLock { cleanup = nil } }
        return stopped
    }
}

protocol WorktreeSetupRunning: Sendable {
    func run(
        _ request: WorktreeSetupRequest,
        cancellation: WorktreeSetupCancellation,
        output: @escaping @Sendable (WorktreeSetupOutput) async -> Void
    ) async -> WorktreeSetupResult
}

/// Separate from Git/gh capture: output overflow truncates retention, never the process.
/// An owned process group covers ordinary descendants, not deliberate daemonization.
struct WorktreeSetupRunner: WorktreeSetupRunning {
    var executablePath = "/bin/sh"

    func run(
        _ request: WorktreeSetupRequest,
        cancellation: WorktreeSetupCancellation,
        output: @escaping @Sendable (WorktreeSetupOutput) async -> Void
    ) async -> WorktreeSetupResult {
        await Task.detached {
            await execute(request, cancellation: cancellation, output: output)
        }.value
    }

    static func environment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        for key in ["ARGUS_SOCKET_PATH", "ARGUS_WORKSPACE_ID", "ARGUS_SURFACE_ID"] {
            environment.removeValue(forKey: key)
        }
        let installed = ["/opt/homebrew/bin", "/usr/local/bin"].filter {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory) && directory.boolValue
        }
        environment["PATH"] = (installed + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
        return environment
    }

    private func execute(
        _ request: WorktreeSetupRequest,
        cancellation: WorktreeSetupCancellation,
        output: @escaping @Sendable (WorktreeSetupOutput) async -> Void
    ) async -> WorktreeSetupResult {
        guard !cancellation.isCancelled else { return .init(outcome: .cancelled) }
        do {
            guard try WorktreeSetupCommand.validated(request.command) != nil else {
                return .init(outcome: .failedLaunch("No command configured."))
            }
            let process = try WorktreeSetupProcess(
                executablePath: executablePath, request: request,
                environment: Self.environment(request.environment)
            )
            return await process.collect(request: request, cancellation: cancellation, output: output)
        } catch {
            // Errors must never include shell source, environment values, or captured output.
            return .init(outcome: .failedLaunch(error.localizedDescription))
        }
    }
}

/// Retain raw UTF-8 until complete, including sequences split across reads. A leading
/// continuation at the retention boundary is omitted rather than displayed as corruption.
struct WorktreeSetupOutputTail {
    static let maximumBytes = 1024 * 1024
    private(set) var bytes = Data()
    private(set) var truncated = false

    mutating func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > Self.maximumBytes {
            bytes.removeFirst(bytes.count - Self.maximumBytes)
            truncated = true
        }
    }

    func snapshot(final: Bool = false) -> WorktreeSetupOutput {
        var visible = bytes[...]
        if truncated {
            while let first = visible.first, first & 0xC0 == 0x80 { visible = visible.dropFirst() }
        }
        if !final, let lead = visible.lastIndex(where: { $0 & 0xC0 != 0x80 }) {
            let byte = visible[lead]
            let length = byte < 0x80 ? 1 : byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : 4
            if visible.distance(from: lead, to: visible.endIndex) < length {
                visible = visible[..<lead]
            }
        }
        // Invalid bytes are visibly replaced; valid sequences split across reads are retained above.
        // swiftlint:disable:next optional_data_string_conversion
        let decoded = String(decoding: visible, as: UTF8.self)
        // Replacement characters can expand invalid input. Bound the visible tail too.
        var displayBytes = decoded.utf8.suffix(Self.maximumBytes)
        while let first = displayBytes.first, first & 0xC0 == 0x80 { displayBytes = displayBytes.dropFirst() }
        return WorktreeSetupOutput(
            text: String(bytes: displayBytes, encoding: .utf8) ?? "",
            truncated: truncated || decoded.utf8.count > Self.maximumBytes
        )
    }
}
