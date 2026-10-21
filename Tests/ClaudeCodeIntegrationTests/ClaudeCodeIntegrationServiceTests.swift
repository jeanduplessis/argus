import Foundation
import Testing

@testable import Argus

struct ClaudeCodeIntegrationServiceTests {
    @Test
    func resolvesTheConfiguredClaudeConfigDirectory() throws {
        try withFixture { fixture in
            let custom = fixture.root.appendingPathComponent("custom-claude")
            let configured = fixture.service(environment: ["CLAUDE_CONFIG_DIR": custom.path]).resolvedPaths()
            #expect(configured.settingsFile == custom.appendingPathComponent("settings.json"))

            let fallback = fixture.service(environment: [:]).resolvedPaths()
            #expect(fallback.settingsFile.path.hasSuffix(".claude/settings.json"))
            #expect(fallback.settingsFile.path.hasPrefix(fixture.root.path))
        }
    }

    @Test
    func enableCreatesSettingsAndDisableLeavesNoArgusHooks() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = try service.enable()

            #expect(service.isInstalled(at: paths))
            let installed = try String(contentsOf: paths.settingsFile, encoding: .utf8)
            for hook in ClaudeCodeSettingsEditor.managedHooks {
                #expect(installed.contains("\"\(hook.event)\""))
            }

            _ = try service.enable()
            #expect(try String(contentsOf: paths.settingsFile, encoding: .utf8) == installed)

            _ = try service.disable()
            #expect(!service.isInstalled(at: paths))
            #expect(try String(contentsOf: paths.settingsFile, encoding: .utf8) == "{}\n")
        }
    }

    @Test
    func unrelatedSettingsAndUserHooksSurviveARoundTrip() throws {
        try withFixture { fixture in
            let original = """
                {
                  "model": "opus",
                  "permissions": {
                    "allow": [
                      "Bash(git status)"
                    ]
                  },
                  "hooks": {
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "say \\"done\\""
                          }
                        ]
                      }
                    ]
                  },
                  "cleanupPeriodDays": 30.0,
                  "statusLine": {
                    "type": "command",
                    "command": "~/.claude/statusline.sh"
                  }
                }

                """
            let service = fixture.service()
            let paths = service.resolvedPaths()
            try fixture.write(original, to: paths.settingsFile)

            _ = try service.enable()
            let enabled = try String(contentsOf: paths.settingsFile, encoding: .utf8)
            #expect(service.isInstalled(at: paths))
            #expect(enabled.contains(#""command": "say \"done\"""#))
            #expect(enabled.contains(#""cleanupPeriodDays": 30.0"#))
            let order = ["\"model\"", "\"permissions\"", "\"hooks\"", "\"cleanupPeriodDays\"", "\"statusLine\""]
                .compactMap { enabled.range(of: $0)?.lowerBound }
            #expect(order == order.sorted() && order.count == 5)
            // The user's Stop hook keeps its place ahead of Argus's.
            let stop = try #require(enabled.range(of: "\"Stop\": ["))
            let userHook = try #require(enabled.range(of: "say \\\"done\\\""))
            let argusHook = try #require(
                enabled.range(of: "claude-code-hook", range: stop.upperBound..<enabled.endIndex))
            #expect(userHook.lowerBound < argusHook.lowerBound)

            _ = try service.disable()
            #expect(try String(contentsOf: paths.settingsFile, encoding: .utf8) == original)
        }
    }

    @Test
    func disableKeepsUserHandlersThatShareAnArgusGroup() throws {
        let command = ClaudeCodeSettingsEditor.hookCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let shared = """
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\(command)"},\
            {"type":"command","command":"afplay done.aiff"}]}]}}
            """
        let disabled = try ClaudeCodeSettingsEditor.edit(shared, operation: .disable)
        #expect(!disabled.contains("claude-code-hook"))
        #expect(disabled.contains("afplay done.aiff"))
    }

    @Test
    func aStaleArgusHookSetIsNotReportedAsInstalled() throws {
        let enabled = try ClaudeCodeSettingsEditor.edit("{}", operation: .enable)
        #expect(ClaudeCodeSettingsEditor.isInstalled(in: enabled))
        let withoutStop = try ClaudeCodeSettingsEditor.edit(
            enabled.replacingOccurrences(of: "\"Stop\"", with: "\"Unrelated\""), operation: .disable)
        #expect(!ClaudeCodeSettingsEditor.isInstalled(in: withoutStop))
        let reenabled = try ClaudeCodeSettingsEditor.edit(withoutStop, operation: .enable)
        #expect(ClaudeCodeSettingsEditor.isInstalled(in: reenabled))
    }

    @Test(arguments: [
        "{ \"model\": \"opus\", // comment\n}",
        "{\"model\": \"opus\",}",
        "[]",
        "{\"hooks\": []}",
        "{\"hooks\": {\"Stop\": {}}}"
    ])
    func invalidSettingsAreRefusedWithoutWriting(_ text: String) throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = service.resolvedPaths()
            try fixture.write(text, to: paths.settingsFile)

            #expect(throws: ClaudeCodeIntegrationError.self) { try service.enable() }
            #expect(try String(contentsOf: paths.settingsFile, encoding: .utf8) == text)
        }
    }

    @Test
    func enableRequiresTheBundledCompanionCLI() throws {
        try withFixture { fixture in
            let service = fixture.service(isCompanionCLIBundled: false)
            #expect(throws: ClaudeCodeIntegrationError.self) { try service.enable() }
            #expect(!FileManager.default.fileExists(atPath: service.resolvedPaths().settingsFile.path))
        }
    }

    @Test
    func disableWithoutSettingsCreatesNothing() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = try service.disable()
            #expect(!FileManager.default.fileExists(atPath: paths.configDirectory.path))
        }
    }

    @Test
    func aSymlinkedSettingsFileStaysALinkAndKeepsItsMode() throws {
        try withFixture { fixture in
            let service = fixture.service()
            let paths = service.resolvedPaths()
            let dotfile = fixture.root.appendingPathComponent("dotfiles/claude-settings.json")
            try fixture.write("{\"model\": \"opus\"}\n", to: dotfile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotfile.path)
            try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: paths.settingsFile, withDestinationURL: dotfile)

            _ = try service.enable()

            let attributes = try FileManager.default.attributesOfItem(atPath: paths.settingsFile.path)
            #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
            #expect(service.isInstalled(at: paths))
            let mode = try FileManager.default.attributesOfItem(atPath: dotfile.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test
    func hookCommandIsSilentAndExecsTheBundledCLI() {
        let command = ClaudeCodeSettingsEditor.hookCommand
        #expect(command.hasPrefix(#"[ -n "$ARGUS_SURFACE_ID" ]"#))
        #expect(command.contains("exec argus agent claude-code-hook >/dev/null 2>&1"))
        #expect(command.hasSuffix("; exit 0"))
    }

    @Test
    func claudeCodeIntegrationIsOwnedBySettings() throws {
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "@StateObject private var claudeCodeIntegration: ClaudeCodeIntegrationModel",
                "let claudeCodeIntegration = ClaudeCodeIntegrationModel()",
                "claudeCodeIntegration: claudeCodeIntegration"
            ], "Claude Code integration app and Settings wiring"
        )
        try SourceContract("Argus/Settings/SettingsView.swift").containsAll(
            [
                "Section(\"Claude Code Integration\")",
                "claudeCodeIntegration.enable()",
                "claudeCodeIntegration.disable()"
            ], "Claude Code integration Settings controls"
        )
    }

    // MARK: - Fixture

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-claude-code-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(Fixture(root: root))
    }

    private struct Fixture {
        let root: URL

        func service(
            environment: [String: String]? = nil,
            isCompanionCLIBundled: Bool = true
        ) -> ClaudeCodeIntegrationService {
            ClaudeCodeIntegrationService(
                environment: environment ?? ["CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path],
                homeDirectory: root,
                isCompanionCLIBundled: isCompanionCLIBundled
            )
        }

        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct ClaudeCodeSocketContractTests {
    @Test
    func theServerAcceptsTheHookRequestsTheCompanionCLIEncodes() async throws {
        let workspace = UUID()
        let surface = UUID()
        let recorder = AgentEventRecorder()
        let handlers = AgentSocketHandlers(
            deliver: { event in
                recorder.record(event.eventId)
                return .accepted(requiresAttention: true)
            },
            deliverStatus: { event in
                recorder.record("\(event.state.map(\.rawValue) ?? "cleared"):\(event.sequence)")
                return .accepted(applied: true)
            },
            deliverCommand: { _ in .rejected(code: .commandUnavailable, message: "unused") }
        )
        func frame<Parameters: Codable & Sendable>(_ method: ArgusSocketMethod, _ params: Parameters) throws -> Data {
            try JSONEncoder().encode(ArgusSocketRequest(id: "hook", method: method, params: params))
        }

        let frames = try [
            frame(
                .agentStatusChanged,
                AgentStatusChangedParameters(
                    agentKey: "claude-code", workspaceId: workspace.uuidString, surfaceId: surface.uuidString,
                    state: .needsInput, sessionId: "claude-code:1:2.3", sequence: 1_234_567_890_123)),
            frame(
                .agentTurnCompleted,
                AgentTurnCompletedParameters(
                    agentKey: "claude-code", workspaceId: workspace.uuidString, surfaceId: surface.uuidString,
                    eventId: "claude-code:turnCompleted:x:1")),
            frame(
                .agentStatusCleared,
                AgentStatusClearedParameters(
                    agentKey: "claude-code", workspaceId: workspace.uuidString, surfaceId: surface.uuidString,
                    sessionId: "claude-code:1:2.3", sequence: 1_234_567_890_124))
        ]
        for frame in frames {
            let response = await AgentSocketServer.handle(frame: frame, handlers: handlers)
            let decoded = try JSONDecoder().decode(
                ArgusSocketResponse<AgentSocketAcknowledgement>.self, from: response.data)
            #expect(decoded.isSuccessful)
        }
        #expect(
            recorder.events == [
                "needsInput:1234567890123", "claude-code:turnCompleted:x:1", "cleared:1234567890124"
            ])
    }

    @Test
    func wireStatesMatchAgentStatusStates() {
        #expect(AgentSocketStatusState.allCases.map(\.rawValue) == AgentStatusState.allCases.map(\.rawValue))
    }
}

private final class AgentEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ event: String) {
        lock.withLock { recorded.append(event) }
    }

    var events: [String] {
        lock.withLock { recorded }
    }
}
