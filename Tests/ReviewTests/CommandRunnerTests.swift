import Darwin
import Foundation
import Testing

@testable import Argus

@Suite
struct CommandRunnerTests {
    @Test
    func capturesStandardOutputAndStandardError() async throws {
        let script = try temporaryScript("""
        printf 'standard output'
        printf 'standard error' >&2
        """)
        defer { removeTemporaryScript(script) }

        let result = try await CommandRunner().run(command(for: script))

        #expect(result.standardOutputString == "standard output")
        #expect(result.standardErrorString == "standard error")
        #expect(result.terminationStatus == 0)
    }

    @Test
    func reportsNonzeroExitWithCapturedOutput() async throws {
        let script = try temporaryScript("""
        printf 'partial output'
        printf 'failure detail' >&2
        exit 23
        """)
        defer { removeTemporaryScript(script) }

        do {
            _ = try await CommandRunner().run(command(for: script))
            Issue.record("Expected a nonzero exit error")
        } catch let CommandRunnerError.nonZeroExit(result) {
            #expect(result.standardOutputString == "partial output")
            #expect(result.standardErrorString == "failure detail")
            #expect(result.terminationStatus == 23)
        }
    }

    @Test
    func timeoutCompletesWithinDeadline() async throws {
        let script = try temporaryScript("""
        while :; do
            :
        done
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script, timeout: 0.1))
        }

        #expect(await completes(task, within: .seconds(2)))
        await expectTimeout(task)
    }

    @Test
    func cancellationCompletesWithinDeadline() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyFile = directory.appendingPathComponent("ready")
        let script = try temporaryScript("""
        : > "\(readyFile.path)"
        while :; do
            :
        done
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script))
        }
        #expect(await fileAppears(at: readyFile, within: .seconds(1)))
        task.cancel()

        #expect(await completes(task, within: .seconds(2)))
        await expectCancellation(task)
    }

    @Test
    func cancellationTerminatesDescendantsAndReleasesTheirPipes() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyFile = directory.appendingPathComponent("ready")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = try temporaryScript("""
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        child=$!
        printf '%s' "$child" > "\(childPIDFile.path)"
        : > "\(readyFile.path)"
        wait "$child"
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script))
        }
        #expect(await fileAppears(at: readyFile, within: .seconds(1)))
        let childPID = try #require(Int32(String(decoding: Data(contentsOf: childPIDFile), as: UTF8.self)))
        task.cancel()

        #expect(await completes(task, within: .seconds(2)))
        await expectCancellation(task)
        #expect(await processDisappears(childPID, within: .seconds(1)))
    }

    @Test
    func standardOutputLimitTerminatesCommandAndReportsStream() async throws {
        let script = try temporaryScript("""
        while :; do
            printf '0123456789'
        done
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script, standardOutputLimit: 32))
        }

        #expect(await completes(task, within: .seconds(2)))
        await expectOutputLimit(task, stream: .standardOutput, limit: 32)
    }

    @Test
    func standardErrorLimitTerminatesCommandAndReportsStream() async throws {
        let script = try temporaryScript("""
        while :; do
            printf '0123456789' >&2
        done
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script, standardErrorLimit: 32))
        }

        #expect(await completes(task, within: .seconds(2)))
        await expectOutputLimit(task, stream: .standardError, limit: 32)
    }

    @Test
    func outputLimitTerminatesDescendantsAndCompletesWithinDeadline() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readyFile = directory.appendingPathComponent("ready")
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let script = try temporaryScript("""
        /bin/sh -c 'trap "" TERM; while :; do :; done' &
        child=$!
        printf '%s' "$child" > "\(childPIDFile.path)"
        : > "\(readyFile.path)"
        while :; do
            printf '0123456789'
        done
        """)
        defer { removeTemporaryScript(script) }

        let task = Task {
            try await CommandRunner().run(command(for: script, standardOutputLimit: 32))
        }
        #expect(await fileAppears(at: readyFile, within: .seconds(1)))
        let childPID = try #require(Int32(String(decoding: Data(contentsOf: childPIDFile), as: UTF8.self)))

        #expect(await completes(task, within: .seconds(2)))
        await expectOutputLimit(task, stream: .standardOutput, limit: 32)
        #expect(await processDisappears(childPID, within: .seconds(2)))
    }

    private func command(
        for script: URL,
        timeout: TimeInterval? = nil,
        standardOutputLimit: Int = CommandRequest.defaultOutputLimit,
        standardErrorLimit: Int = CommandRequest.defaultOutputLimit
    ) -> CommandRequest {
        CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit
        )
    }

    private func temporaryScript(_ contents: String) throws -> URL {
        let directory = makeTemporaryDirectory()
        let script = directory.appendingPathComponent("command.sh")
        try contents.write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArgusCommandRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func removeTemporaryScript(_ script: URL) {
        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
    }

    private func completes(
        _ task: Task<CommandResult, Error>,
        within duration: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await task.value
                } catch {
                    // Completion with an expected command error still meets the deadline.
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
    }

    private func fileAppears(at url: URL, within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while clock.now < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func processDisappears(_ pid: Int32, within duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while clock.now < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    private func expectTimeout(_ task: Task<CommandResult, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected a timeout error")
        } catch let error as CommandRunnerError {
            guard case .timedOut = error else {
                Issue.record("Expected a timeout error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected a timeout error, got \(error)")
        }
    }

    private func expectCancellation(_ task: Task<CommandResult, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected a cancellation error")
        } catch let error as CommandRunnerError {
            guard case .cancelled = error else {
                Issue.record("Expected a cancellation error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected a cancellation error, got \(error)")
        }
    }

    private func expectOutputLimit(
        _ task: Task<CommandResult, Error>,
        stream: CommandOutputStream,
        limit: Int
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected an output limit error")
        } catch let error as CommandOutputLimitError {
            #expect(error.stream == stream)
            #expect(error.limit == limit)
        } catch {
            Issue.record("Expected an output limit error, got \(error)")
        }
    }
}
