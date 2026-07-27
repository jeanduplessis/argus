@preconcurrency import Foundation
import Darwin

/// A command request whose executable and arguments are kept separate so callers
/// never need a shell to invoke an external tool.
struct CommandRequest: Sendable, Equatable {
    /// Large enough for normal `gh api` JSON responses while bounding a malformed
    /// or unexpectedly verbose command's memory use per stream.
    static let defaultOutputLimit = 8 * 1024 * 1024

    let executableURL: URL
    let arguments: [String]
    let standardInput: Data?
    let environment: [String: String]
    let currentDirectoryURL: URL?
    let timeout: TimeInterval?
    let standardOutputLimit: Int
    let standardErrorLimit: Int

    init(
        executableURL: URL,
        arguments: [String] = [],
        standardInput: Data? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = nil,
        standardOutputLimit: Int = Self.defaultOutputLimit,
        standardErrorLimit: Int = Self.defaultOutputLimit
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.standardOutputLimit = max(0, standardOutputLimit)
        self.standardErrorLimit = max(0, standardErrorLimit)
    }
}

struct CommandResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32

    var standardOutputString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum CommandRunnerError: Error, LocalizedError, Sendable, Equatable {
    case launchFailed(String)
    case timedOut
    case cancelled
    case nonZeroExit(CommandResult)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "Could not start command: \(detail)"
        case .timedOut:
            return "Command timed out"
        case .cancelled:
            return "Command was cancelled"
        case .nonZeroExit(let result):
            let detail = result.standardErrorString.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Command failed with exit status \(result.terminationStatus)" : detail
        }
    }
}

enum CommandOutputStream: String, Sendable, Equatable {
    case standardOutput = "standard output"
    case standardError = "standard error"
}

struct CommandOutputLimitError: Error, LocalizedError, Sendable, Equatable {
    let stream: CommandOutputStream
    let limit: Int

    var errorDescription: String? {
        "Command \(stream.rawValue) exceeded its \(limit)-byte output limit"
    }
}

protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult
}

/// Executes local commands without a shell, draining stdout and stderr while the
/// child runs so a verbose command cannot deadlock on a full pipe.
final class CommandRunner: CommandRunning, Sendable {
    func run(_ request: CommandRequest) async throws -> CommandResult {
        let execution = CommandExecution()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let stdout = Pipe()
                    let stderr = Pipe()
                    let stdin = request.standardInput.map { _ in Pipe() }
                    do {
                        let pid = try self.spawn(request, standardInput: stdin, standardOutput: stdout, standardError: stderr)
                        let reader = CommandOutputReader(
                            stdout: stdout,
                            stderr: stderr,
                            standardOutputLimit: request.standardOutputLimit,
                            standardErrorLimit: request.standardErrorLimit,
                            onLimitExceeded: { stream, limit in
                                execution.outputLimitExceeded(stream: stream, limit: limit)
                            }
                        )
                        execution.attach(pid: pid, reader: reader)
                        try? stdout.fileHandleForWriting.close()
                        try? stderr.fileHandleForWriting.close()
                        try? stdin?.fileHandleForReading.close()

                        if let standardInput = request.standardInput, let stdin {
                            DispatchQueue.global(qos: .utility).async {
                                try? stdin.fileHandleForWriting.write(contentsOf: standardInput)
                                try? stdin.fileHandleForWriting.close()
                            }
                        }

                        if let timeout = request.timeout {
                            execution.startTimeout(after: timeout)
                        }

                        DispatchQueue.global(qos: .utility).async {
                            var status: Int32 = 0
                            while Darwin.waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                            Task {
                                let output = await reader.readToEnd()
                                switch execution.complete() {
                                case .cancelled:
                                    continuation.resume(throwing: CommandRunnerError.cancelled)
                                case .timedOut:
                                    continuation.resume(throwing: CommandRunnerError.timedOut)
                                case .outputLimitExceeded(let stream, let limit):
                                    continuation.resume(throwing: CommandOutputLimitError(stream: stream, limit: limit))
                                case .running, .completed:
                                    let result = CommandResult(
                                        standardOutput: output.stdout,
                                        standardError: output.stderr,
                                        terminationStatus: self.terminationStatus(for: status)
                                    )
                                    if result.terminationStatus == 0 {
                                        continuation.resume(returning: result)
                                    } else {
                                        continuation.resume(throwing: CommandRunnerError.nonZeroExit(result))
                                    }
                                }
                            }
                        }
                    } catch {
                        continuation.resume(throwing: CommandRunnerError.launchFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// `POSIX_SPAWN_SETPGROUP` makes the child the leader of a new process group
    /// before it executes. This avoids the post-launch `setpgid` race in which a
    /// descendant can escape cancellation.
    private func spawn(_ request: CommandRequest, standardInput: Pipe?, standardOutput: Pipe, standardError: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw CommandRunnerError.launchFailed("Could not initialize command launch")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CommandRunnerError.launchFailed("Could not initialize command launch")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        let stdinFD = standardInput?.fileHandleForReading.fileDescriptor
        let stdoutFD = standardOutput.fileHandleForWriting.fileDescriptor
        let stderrFD = standardError.fileHandleForWriting.fileDescriptor
        guard posix_spawn_file_actions_adddup2(&actions, stdinFD ?? STDIN_FILENO, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw CommandRunnerError.launchFailed("Could not configure command launch")
        }
        if let directory = request.currentDirectoryURL?.path {
            guard posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else {
                throw CommandRunnerError.launchFailed("Could not set command directory")
            }
        }

        let argumentStorage = ([request.executableURL.path] + request.arguments).map { strdup($0) }
        let environmentStorage = request.environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argumentStorage.forEach { free($0) }
            environmentStorage.forEach { free($0) }
        }
        var argv = argumentStorage + [nil]
        var environment = environmentStorage + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, request.executableURL.path, &actions, &attributes, &argv, &environment)
        guard result == 0 else {
            throw CommandRunnerError.launchFailed(String(cString: strerror(result)))
        }
        return pid
    }

    private func terminationStatus(for waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : 128 + signal
    }
}

private final class CommandExecution: @unchecked Sendable {
    enum Outcome: Equatable {
        case running
        case timedOut
        case cancelled
        case outputLimitExceeded(CommandOutputStream, Int)
        case completed
    }

    private let lock = NSLock()
    private var pid: pid_t?
    private var reader: CommandOutputReader?
    private var storedOutcome = Outcome.running
    private var timeoutTask: Task<Void, Never>?

    var outcome: Outcome {
        lock.withLock { storedOutcome }
    }

    func attach(pid: pid_t, reader: CommandOutputReader) {
        let shouldTerminate = lock.withLock { () -> Bool in
            self.pid = pid
            self.reader = reader
            return storedOutcome != .running
        }
        if shouldTerminate {
            terminateProcessGroup(pid: pid, reader: reader)
        }
    }

    func timeout() {
        stop(with: .timedOut)
    }

    func cancel() {
        stop(with: .cancelled)
    }

    func outputLimitExceeded(stream: CommandOutputStream, limit: Int) {
        stop(with: .outputLimitExceeded(stream, limit))
    }

    func startTimeout(after timeout: TimeInterval) {
        guard timeout > 0 else {
            self.timeout()
            return
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(timeout))
                self?.timeout()
            } catch is CancellationError {
                // Process completion, cancellation, or an earlier timeout ended this request.
            } catch {
                self?.timeout()
            }
        }
        let shouldCancel = lock.withLock { () -> Bool in
            guard storedOutcome == .running else { return true }
            timeoutTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func complete() -> Outcome {
        lock.withLock {
            let outcome = storedOutcome
            if storedOutcome == .running { storedOutcome = .completed }
            pid = nil
            reader = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            return outcome
        }
    }

    private func stop(with outcome: Outcome) {
        let target = lock.withLock { () -> (pid_t, CommandOutputReader)? in
            guard storedOutcome == .running else { return nil }
            storedOutcome = outcome
            guard let pid, let reader else { return nil }
            return (pid, reader)
        }
        if let target {
            terminateProcessGroup(pid: target.0, reader: target.1)
        }
    }

    /// Commands run in their own process group so cancellation also closes
    /// descendants that inherited stdout/stderr and would otherwise keep pipe
    /// readers (and the awaiting task) alive after `gh` exits.
    private func terminateProcessGroup(pid: pid_t, reader: CommandOutputReader) {
        guard pid > 0 else { return }
        _ = Darwin.kill(-pid, SIGTERM)
        let escalation = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard self?.outcome != .completed else { return }
                _ = Darwin.kill(-pid, SIGKILL)
                // A process that deliberately escapes its group can retain a pipe.
                // Closing reader descriptors bounds completion after cancellation.
                reader.close()
            } catch is CancellationError {
                // The command completed before escalation was necessary.
            } catch {
                _ = Darwin.kill(-pid, SIGKILL)
                reader.close()
            }
        }
        lock.withLock {
            timeoutTask?.cancel()
            timeoutTask = escalation
        }
    }
}

private final class CommandOutputReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let stdoutBox = CommandDataBox()
    private let stderrBox = CommandDataBox()
    private let descriptors = CommandDescriptorBox()

    private let onLimitExceeded: @Sendable (CommandOutputStream, Int) -> Void

    init(
        stdout: Pipe,
        stderr: Pipe,
        standardOutputLimit: Int,
        standardErrorLimit: Int,
        onLimitExceeded: @escaping @Sendable (CommandOutputStream, Int) -> Void
    ) {
        self.onLimitExceeded = onLimitExceeded
        read(stdout.fileHandleForReading, into: stdoutBox, stream: .standardOutput, limit: standardOutputLimit)
        read(stderr.fileHandleForReading, into: stderrBox, stream: .standardError, limit: standardErrorLimit)
    }

    func readToEnd() async -> (stdout: Data, stderr: Data) {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .utility)) {
                continuation.resume()
            }
        }
        return (stdoutBox.data, stderrBox.data)
    }

    private func read(_ handle: FileHandle, into box: CommandDataBox, stream: CommandOutputStream, limit: Int) {
        let descriptor = Darwin.dup(handle.fileDescriptor)
        descriptors.add(descriptor)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.group.leave() }
            defer {
                if self.descriptors.remove(descriptor) {
                    Darwin.close(descriptor)
                }
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let remaining = limit - data.count
                    if count > remaining {
                        if remaining > 0 {
                            data.append(buffer, count: remaining)
                        }
                        box.data = data
                        self.onLimitExceeded(stream, limit)
                        return
                    }
                    data.append(buffer, count: count)
                } else if count == 0 || errno != EINTR {
                    box.data = data
                    return
                }
            }
        }
    }

    func close() {
        descriptors.closeAll()
    }
}

private final class CommandDataBox: @unchecked Sendable {
    var data = Data()
}

private final class CommandDescriptorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: Set<Int32> = []

    func add(_ descriptor: Int32) { _ = lock.withLock { descriptors.insert(descriptor) } }
    func remove(_ descriptor: Int32) -> Bool {
        lock.withLock { descriptors.remove(descriptor) != nil }
    }
    func closeAll() {
        let active = lock.withLock { () -> Set<Int32> in
            let active = descriptors
            descriptors.removeAll()
            return active
        }
        active.forEach { Darwin.close($0) }
    }
}
