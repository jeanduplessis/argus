import Darwin
import Foundation

/// Only used off MainActor. All reads and reaping are nonblocking; cleanup has a deadline.
final class WorktreeSetupProcess: @unchecked Sendable {
    private let pid: pid_t
    private let readDescriptor: Int32
    private var leaderReaped = false

    init(executablePath: String, request: WorktreeSetupRequest, environment: [String: String]) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        var keepReader = false
        defer {
            close(descriptors[1])
            if !keepReader { close(descriptors[0]) }
        }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try Self.check(posix_spawn_file_actions_addchdir_np(&actions, request.rootPath))
        try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO))
        try Self.check(posix_spawn_file_actions_addclose(&actions, descriptors[0]))
        try Self.check(posix_spawn_file_actions_addclose(&actions, descriptors[1]))
        let arguments = [executablePath, "-c", request.command].map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }
        var child: pid_t = 0
        let error = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { envp in
                posix_spawn(&child, executablePath, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try Self.check(error)
        pid = child
        readDescriptor = descriptors[0]
        keepReader = true
    }

    deinit { close(readDescriptor) }

    func collect(
        request: WorktreeSetupRequest,
        cancellation: WorktreeSetupCancellation,
        output: @escaping @Sendable (WorktreeSetupOutput) async -> Void
    ) async -> WorktreeSetupResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, request.timeout)))
        var lastPublication = clock.now
        var tail = WorktreeSetupOutputTail()
        var pendingOutput = false
        var outcome: WorktreeSetupOutcome?
        var cleanupStart: ContinuousClock.Instant?
        var sentKill = false
        while true {
            pendingOutput = drain(into: &tail) || pendingOutput
            let exitCode = observedExitCode()
            let now = clock.now
            if outcome == nil {
                outcome = completionOutcome(
                    cancelled: cancellation.isCancelled, timedOut: now >= deadline, exitCode: exitCode)
            }
            if outcome != nil, cleanupStart == nil {
                cleanupStart = now
                // Also clean residual ordinary descendants after a successful shell exit.
                _ = kill(-pid, SIGTERM)
            }
            if let cleanupStart {
                if !sentKill, now - cleanupStart >= .milliseconds(300) {
                    _ = kill(-pid, SIGKILL)
                    sentKill = true
                }
                if reapTerminatedGroup() {
                    _ = drain(into: &tail)
                    await output(tail.snapshot(final: true))
                    return .init(outcome: outcome ?? .cancelled)
                }
                if now - cleanupStart >= .seconds(3) {
                    await output(tail.snapshot(final: true))
                    cancellation.retainCleanup { await self.retryCleanup() }
                    return .init(outcome: outcome ?? .cancelled, terminationConfirmed: false)
                }
            }
            if pendingOutput, now - lastPublication >= .milliseconds(100) {
                await output(tail.snapshot())
                lastPublication = now
                pendingOutput = false
            }
            // Cancellation uses the explicit flag; cancelling a caller cannot skip cleanup.
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func completionOutcome(cancelled: Bool, timedOut: Bool, exitCode: Int32?) -> WorktreeSetupOutcome? {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        guard let exitCode else { return nil }
        return exitCode == 0 ? .succeeded : .exited(exitCode)
    }

    /// WNOWAIT reserves the leader PID (and hence group ID) through cleanup, even
    /// when the shell exits first. A failed bounded stop retains this same owner.
    private func observedExitCode() -> Int32? {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid else {
            return nil
        }
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }

    private func reapTerminatedGroup() -> Bool {
        if leaderReaped { return true }
        guard observedExitCode() != nil, groupHasOnlyZombies() else { return false }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return false }
        leaderReaped = true
        return true
    }

    private func groupHasOnlyZombies() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
            size > 0, size <= 1024 * 1024
        else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = processes.count * stride
        let result = processes.withUnsafeMutableBytes {
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return false }
        return processes.prefix(size / stride).allSatisfy { $0.kp_proc.p_stat == SZOMB }
    }

    private func retryCleanup() async -> Bool {
        if leaderReaped { return true }
        // The unreaped leader still reserves this process group identity.
        _ = kill(-pid, SIGKILL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if reapTerminatedGroup() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func drain(into tail: inout WorktreeSetupOutputTail) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var changed = false
        for _ in 0..<16 {
            let count = read(readDescriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            tail.append(Data(buffer.prefix(count)))
            changed = true
        }
        return changed
    }

    private static func check(_ error: Int32) throws {
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }
}
