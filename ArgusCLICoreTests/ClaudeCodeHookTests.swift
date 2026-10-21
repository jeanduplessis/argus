import ArgusIPC
import Darwin
import Foundation
import Testing

@testable import ArgusCLICore

@Suite
struct ClaudeCodeHookTests {
    private let environment = [
        "ARGUS_SOCKET_PATH": "/tmp/argus-test.sock",
        "ARGUS_WORKSPACE_ID": "workspace",
        "ARGUS_SURFACE_ID": "surface"
    ]

    private func action(_ json: String) -> ClaudeCodeHook.Action? {
        guard let input = try? JSONDecoder().decode(ClaudeCodeHookInput.self, from: Data(json.utf8)) else {
            return nil
        }
        return ClaudeCodeHook.action(for: input)
    }

    @Test
    func lifecycleEventsMapToAgentStatus() {
        #expect(action(#"{"hook_event_name":"SessionStart","source":"startup"}"#) == .status(.idle))
        #expect(action(#"{"hook_event_name":"SessionStart","source":"clear"}"#) == .status(.idle))
        #expect(action(#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#) == .status(.running))
        #expect(action(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#) == .status(.running))
        #expect(action(#"{"hook_event_name":"PostToolUseFailure","tool_name":"Bash"}"#) == .status(.running))
        #expect(action(#"{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}"#) == .status(.needsInput))
        #expect(action(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#) == .status(.needsInput))
        #expect(
            action(#"{"hook_event_name":"Notification","notification_type":"permission_prompt"}"#)
                == .status(.needsInput))
        #expect(
            action(#"{"hook_event_name":"Notification","notification_type":"elicitation_dialog"}"#)
                == .status(.needsInput))
        #expect(action(#"{"hook_event_name":"Notification","notification_type":"idle_prompt"}"#) == .status(.idle))
        #expect(action(#"{"hook_event_name":"Stop","stop_hook_active":false}"#) == .completedTurn)
        #expect(action(#"{"hook_event_name":"StopFailure","error":"rate_limit"}"#) == .status(.error))
        #expect(action(#"{"hook_event_name":"SessionEnd","reason":"prompt_input_exit"}"#) == .clear)
        #expect(action(#"{"hook_event_name":"SessionEnd","reason":"other"}"#) == .clear)
    }

    @Test
    func eventsThatDoNotChangeStatusAreIgnored() {
        // Auto-compaction starts a new session while the turn is still running.
        #expect(action(#"{"hook_event_name":"SessionStart","source":"compact"}"#) == nil)
        // A session swap inside one process is followed by SessionStart.
        #expect(action(#"{"hook_event_name":"SessionEnd","reason":"clear"}"#) == nil)
        #expect(action(#"{"hook_event_name":"SessionEnd","reason":"resume"}"#) == nil)
        #expect(action(#"{"hook_event_name":"Notification","notification_type":"auth_success"}"#) == nil)
        #expect(action(#"{"hook_event_name":"SubagentStop","agent_id":"a"}"#) == nil)
        #expect(action(#"{"hook_event_name":"PreCompact","trigger":"auto"}"#) == nil)
    }

    @Test
    func aStopReportsIdleBeforeOneTurnCompletion() throws {
        let requests = ClaudeCodeHook.requests(
            input: Data(#"{"hook_event_name":"Stop","session_id":"claude-session"}"#.utf8),
            environment: environment, sessionId: "claude-code:42:1.2", sequence: 7)

        #expect(requests.count == 2)
        guard case .statusChanged(let status) = requests.first,
            case .turnCompleted(let completion) = requests.last
        else {
            Issue.record("Unexpected requests: \(requests)")
            return
        }
        #expect(
            status
                == AgentStatusChangedParameters(
                    agentKey: "claude-code", workspaceId: "workspace", surfaceId: "surface",
                    state: .idle, sessionId: "claude-code:42:1.2", sequence: 7))
        #expect(completion.eventId == "claude-code:turnCompleted:claude-code:42:1.2:7")
        #expect(completion.surfaceId == "surface")
    }

    @Test
    func nothingIsSentOutsideAnArgusTerminalOrWithoutIdentity() {
        let stop = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        #expect(ClaudeCodeHook.requests(input: stop, environment: [:], sessionId: "s", sequence: 1).isEmpty)
        var missingSurface = environment
        missingSurface["ARGUS_SURFACE_ID"] = ""
        #expect(ClaudeCodeHook.requests(input: stop, environment: missingSurface, sessionId: "s", sequence: 1).isEmpty)
        #expect(ClaudeCodeHook.requests(input: stop, environment: environment, sessionId: nil, sequence: 1).isEmpty)
        #expect(ClaudeCodeHook.requests(input: stop, environment: environment, sessionId: "s", sequence: 0).isEmpty)
        #expect(
            ClaudeCodeHook.requests(input: Data("not json".utf8), environment: environment, sessionId: "s", sequence: 1)
                .isEmpty)
    }

    @Test
    func theReportingSessionIsStableWithinOneProcessAndSequencesIncrease() {
        let first = ClaudeCodeHook.parentProcessSessionID()
        #expect(first != nil)
        #expect(first == ClaudeCodeHook.parentProcessSessionID())
        // Consecutive reads can share one clock tick; separate hook processes cannot.
        let earlier = ClaudeCodeHook.monotonicSequence()
        usleep(1_000)
        #expect(ClaudeCodeHook.monotonicSequence() > earlier)
    }

    @Test
    func deliveryWritesOneFramePerRequestInOrder() throws {
        let server = try LineRecordingSocketServer()
        defer { server.stop() }
        let requests = ClaudeCodeHook.requests(
            input: Data(#"{"hook_event_name":"Stop"}"#.utf8),
            environment: environment, sessionId: "s", sequence: 3)

        ClaudeCodeHook.deliver(requests, socketPath: server.path)

        struct Header: Decodable { let method: String }
        let methods = try server.receivedLines().map {
            try JSONDecoder().decode(Header.self, from: $0).method
        }
        #expect(methods == ["agent.statusChanged", "agent.turnCompleted"])
    }

    @Test
    func deliveryFailureIsSilent() {
        ClaudeCodeHook.deliver(
            [
                .statusCleared(
                    .init(agentKey: "claude-code", workspaceId: "w", surfaceId: "s", sessionId: "s", sequence: 1))
            ],
            socketPath: "/tmp/argus-missing-\(UUID().uuidString).sock")
    }
}

/// Accepts connections on a temporary Unix socket, records one line from each,
/// and acknowledges it as the Socket Server would.
private final class LineRecordingSocketServer: @unchecked Sendable {
    let path = "/tmp/argus-hook-\(UUID().uuidString.prefix(8)).sock"
    private let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    private let lock = NSLock()
    private var lines: [Data] = []

    init() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let listener = descriptor
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread { [self] in acceptLoop() }.start()
    }

    private func acceptLoop() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var line = Data()
            while !line.contains(0x0A) {
                let count = recv(client, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                line.append(contentsOf: buffer.prefix(count))
            }
            lock.withLock { lines.append(Data(line.prefix { $0 != 0x0A })) }
            let reply = Array(#"{"ok":true,"result":{"accepted":true}}"#.utf8) + [0x0A]
            _ = send(client, reply, reply.count, 0)
            close(client)
        }
    }

    func receivedLines() throws -> [Data] {
        lock.withLock { lines }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
