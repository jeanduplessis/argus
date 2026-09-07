import Foundation
import Testing

@testable import Argus

@Suite(.serialized)
struct StackParentTransactionTests {
    @Test
    func failedReadbackRestoresExactPriorConfiguration() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let original = try Data(contentsOf: fixture.configurationURL)
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .before, arguments.contains("symbolic-ref"),
                (try? fixture.git(["config", "--local", "--get", "branch.\(fixture.parentBranch).base"])) == "main",
                once.take()
            else { return nil }
            return StackGitTestRunner.failure
        }
        do {
            _ = try await fixture.service(runner: runner).setParent("main", expected: expected)
            Issue.record("A failed readback must fail the edit")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-sensitive"))
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.configurationURL.path + ".lock"))
    }

    @Test
    func failedReadbackNeverRestoresOverAnExternalConfigWrite() async throws {
        let fixture = try StackMaintenanceFixture()
        try fixture.git(["branch", "external", "main"])
        let expected = try await fixture.context()
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .before, arguments.contains("symbolic-ref"),
                (try? fixture.git(["config", "--local", "--get", "branch.\(fixture.parentBranch).base"])) == "main",
                once.take()
            else { return nil }
            try fixture.git(["config", "branch.\(fixture.parentBranch).base", "external"])
            try fixture.git(["config", "unrelated.value", "fixture-sensitive"])
            return StackGitTestRunner.failure
        }
        await #expect(throws: StackParentError.retainedConfiguration(fixture.configurationURL.path)) {
            try await fixture.service(runner: runner).setParent("main", expected: expected)
        }
        #expect(try fixture.git(["config", "branch.\(fixture.parentBranch).base"]) == "external")
        #expect(try fixture.git(["config", "unrelated.value"]) == "fixture-sensitive")
    }

    @Test
    func concurrentConfigReplacementBeforeCommitIsNotOverwritten() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let replacement = try Data(contentsOf: fixture.configurationURL) + Data("\n[external]\nvalue = retained\n".utf8)
        let once = StackTestOneShot()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .after, arguments.contains("--replace-all"), once.take() else { return nil }
            try replacement.write(to: fixture.configurationURL, options: .atomic)
            return nil
        }
        await #expect(throws: StackParentError.self) {
            try await fixture.service(runner: runner).setParent("main", expected: expected)
        }
        #expect(try Data(contentsOf: fixture.configurationURL) == replacement)
        #expect((try? fixture.git(["config", "branch.\(fixture.parentBranch).base"])) == nil)
    }

    @Test
    func cancellationAfterTheWriteRollsBackOnlyTheOwnedConfiguration() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let original = try Data(contentsOf: fixture.configurationURL)
        let gate = StackCommandGate()
        let once = StackTestOneShot()
        defer { gate.release() }
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .before, arguments.contains("symbolic-ref"),
                (try? fixture.git(["config", "--local", "--get", "branch.\(fixture.parentBranch).base"])) == "main",
                once.take()
            else { return nil }
            try gate.stop()
            return nil
        }
        let task = Task { try await fixture.service(runner: runner).setParent("main", expected: expected) }
        try await gate.wait()
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: fixture.configurationURL) == original)
    }

    @Test
    func refusesAConfigSymlinkAndPreservesAnExistingLock() async throws {
        let fixture = try StackMaintenanceFixture()
        let expected = try await fixture.context()
        let lock = URL(fileURLWithPath: fixture.configurationURL.path + ".lock")
        let lockData = Data("another writer".utf8)
        try lockData.write(to: lock)
        await #expect(throws: StackParentError.self) {
            try await fixture.service().setParent("main", expected: expected)
        }
        #expect(try Data(contentsOf: lock) == lockData)
        try FileManager.default.removeItem(at: lock)
        let original = fixture.root.appendingPathComponent("original-config")
        try FileManager.default.moveItem(at: fixture.configurationURL, to: original)
        try FileManager.default.createSymbolicLink(at: fixture.configurationURL, withDestinationURL: original)
        await #expect(throws: StackParentError.self) { try await fixture.context() }
        #expect(try Data(contentsOf: original).count > 0)
    }

    @Test
    func boundsGitOutputWithoutExposingStderr() async throws {
        let fixture = try StackMaintenanceFixture()
        let runner = StackGitTestRunner { arguments, _, phase in
            guard phase == .before, arguments.contains("symbolic-ref") else { return nil }
            return ExternalProcessResult(
                stdout: Data(repeating: 65, count: 1_048_576),
                stderr: Data("fixture-sensitive".utf8), terminationStatus: 0)
        }
        await #expect(throws: StackParentError.outputTooLarge) {
            try await fixture.context(using: fixture.service(runner: runner))
        }
    }

    @Test(arguments: ["detached", "missing", "subdirectory", "other-repository"])
    func refusesAnUnverifiedWorkspaceCheckout(_ kind: String) async throws {
        let fixture = try StackMaintenanceFixture()
        var path = fixture.parent
        switch kind {
        case "detached": try fixture.git(["switch", "--detach"], at: fixture.parent)
        case "missing": path = fixture.root.appendingPathComponent("missing")
        case "subdirectory":
            path = fixture.parent.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        default:
            path = fixture.root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            try fixture.git(["init", "-b", "main", "."], at: path)
        }
        await #expect(throws: StackParentError.self) {
            try await fixture.service().inspect(repositoryPath: fixture.repository.path, worktreePath: path.path)
        }
    }
}
