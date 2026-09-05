import Darwin
import Foundation
import Testing

@testable import Argus

@Suite
struct WorktreeSetupRunnerTests {
    @Test
    func commandValidationPreservesBytesAndRejectsInvalidInput() throws {
        let command = "  printf '%s\\n' 'a; b'\n"
        #expect(try WorktreeSetupCommand.validated(command) == command)
        #expect(try WorktreeSetupCommand.validated(" \n\t") == nil)
        #expect(throws: WorktreeSetupConfigurationError.self) { try WorktreeSetupCommand.validated("a\0b") }
        #expect(throws: WorktreeSetupConfigurationError.self) {
            try WorktreeSetupCommand.validated(String(repeating: "a", count: 16 * 1024 + 1))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func runsLiteralShellSourceInCWDWithEOFAndSanitizedInheritedEnvironment() async throws {
        let directory = try TestTemporaryDirectory(prefix: "argus-setup")
        defer { directory.remove() }
        let root = directory.url.appendingPathComponent("quoted ' $(not-a-command)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = SetupOutputRecorder()
        let command = """
            pwd -P
            printf '%s\\n' 'literal "quotes"; $notExpanded'
            printf '%s|%s|%s|%s\\n' "$SETUP_FIXTURE" "$ARGUS_SOCKET_PATH" "$ARGUS_WORKSPACE_ID" "$ARGUS_SURFACE_ID"
            if read value; then exit 23; fi
            if (: </dev/tty) 2>/dev/null; then exit 24; fi
            printf 'stderr-marker' >&2
            """
        let request = WorktreeSetupRequest(
            command: command, rootPath: root.path,
            environment: [
                "SETUP_FIXTURE": "inherited", "PATH": "/usr/bin:/bin",
                "ARGUS_SOCKET_PATH": "bad", "ARGUS_WORKSPACE_ID": "bad", "ARGUS_SURFACE_ID": "bad"
            ])
        let result = await WorktreeSetupRunner().run(request, cancellation: .init()) { await recorder.record($0) }
        #expect(result.outcome == .succeeded)
        #expect(result.terminationConfirmed)
        let output = await recorder.latest.text
        #expect(output.contains(root.resolvingSymlinksInPath().path))
        #expect(output.contains("literal \"quotes\"; $notExpanded"))
        #expect(output.contains("inherited|||"))
        #expect(output.contains("stderr-marker"))
    }

    @Test(.timeLimit(.minutes(1)))
    func publishesQuietOutputBeforeCompletion() async throws {
        let directory = try TestTemporaryDirectory(prefix: "argus-setup-stream")
        defer { directory.remove() }
        let recorder = SetupOutputRecorder()
        let task = Task {
            await WorktreeSetupRunner().run(
                .init(
                    command: "printf ready; while [ ! -e release ]; do sleep 0.02; done",
                    rootPath: directory.url.path, timeout: 10
                ), cancellation: .init()
            ) { await recorder.record($0) }
        }
        for _ in 0..<500 where await recorder.latest.text.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        // The shell cannot complete until this test releases it; no fixed launch-time assumption.
        #expect(await recorder.latest.text == "ready")
        try Data().write(to: directory.url.appendingPathComponent("release"))
        #expect(await task.value.outcome == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func retainsBoundedOutputWithoutFailingCommand() async throws {
        let recorder = SetupOutputRecorder()
        let command = "/usr/bin/head -c 1200000 /dev/zero | /usr/bin/tr '\\000' x; printf end"
        let result = await WorktreeSetupRunner().run(
            .init(command: command, rootPath: "/tmp"), cancellation: .init()
        ) { await recorder.record($0) }
        #expect(result.outcome == .succeeded)
        let latest = await recorder.latest
        #expect(latest.truncated)
        #expect(latest.text.utf8.count <= 1024 * 1024)
        #expect(latest.text.hasSuffix("end"))
    }

    @Test(.timeLimit(.minutes(1)))
    func splitUTF8IsNotCorrupted() async {
        let recorder = SetupOutputRecorder()
        let result = await WorktreeSetupRunner().run(
            .init(
                command: "printf '\\360'; sleep 0.15; printf '\\237\\231'; sleep 0.15; printf '\\202'", rootPath: "/tmp"
            ),
            cancellation: .init()
        ) { await recorder.record($0) }
        #expect(result.outcome == .succeeded)
        #expect(await recorder.latest.text == "🙂")
        #expect(await !recorder.sawReplacement)
        var tail = WorktreeSetupOutputTail()
        tail.append(Data((String(repeating: "a", count: 1024 * 1024) + "🙂").utf8))
        tail.append(Data(repeating: 98, count: 1024 * 1024 - 2))
        #expect(!tail.snapshot(final: true).text.contains("�"))
    }

    @Test
    func invalidUTF8ReplacementAlsoRespectsDisplayBound() {
        var tail = WorktreeSetupOutputTail()
        tail.append(Data(repeating: 255, count: WorktreeSetupOutputTail.maximumBytes))
        let output = tail.snapshot(final: true)
        #expect(output.text.utf8.count <= WorktreeSetupOutputTail.maximumBytes)
        #expect(output.truncated)
    }

    @Test(.timeLimit(.minutes(1)))
    func nonzeroExitAndSpawnFailureRemainDistinct() async {
        let failed = await WorktreeSetupRunner().run(
            .init(command: "exit 17", rootPath: "/tmp"), cancellation: .init(), output: { _ in }
        )
        #expect(failed.outcome == .exited(17))
        let spawn = await WorktreeSetupRunner(executablePath: "/nonexistent/argus-setup-fixture").run(
            .init(command: "secret-marker", rootPath: "/tmp"), cancellation: .init(), output: { _ in }
        )
        guard case .failedLaunch(let message) = spawn.outcome else {
            Issue.record("Expected spawn failure")
            return
        }
        #expect(!message.contains("secret-marker"))
        #expect(spawn.terminationConfirmed)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func cancellationAndTimeoutCleanOrdinaryChildProcesses(_ timeout: Bool) async throws {
        let recorder = SetupOutputRecorder()
        let cancellation = WorktreeSetupCancellation()
        let request = WorktreeSetupRequest(
            command: "trap '' TERM; /bin/sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait",
            rootPath: "/tmp", timeout: timeout ? 0.4 : 10
        )
        let start = ContinuousClock.now
        let task = Task {
            await WorktreeSetupRunner().run(request, cancellation: cancellation) { await recorder.record($0) }
        }
        for _ in 0..<100 where await recorder.latest.text.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let child = try #require(pid_t(await recorder.latest.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        if !timeout { cancellation.cancel() }
        let result = await task.value
        #expect(result.outcome == (timeout ? .timedOut : .cancelled))
        #expect(result.terminationConfirmed)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test(.timeLimit(.minutes(1)))
    func shellExitAlsoCleansResidualDescendants() async throws {
        let recorder = SetupOutputRecorder()
        let result = await WorktreeSetupRunner().run(
            .init(command: "/bin/sleep 30 & printf '%s\\n' \"$!\"; exit 0", rootPath: "/tmp"),
            cancellation: .init()
        ) { await recorder.record($0) }
        let child = try #require(pid_t(await recorder.latest.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(result.outcome == .succeeded)
        #expect(result.terminationConfirmed)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }
}

private actor SetupOutputRecorder {
    var latest = WorktreeSetupOutput(text: "", truncated: false)
    var sawReplacement = false

    func record(_ output: WorktreeSetupOutput) {
        latest = output
        sawReplacement = sawReplacement || output.text.contains("�")
    }
}
