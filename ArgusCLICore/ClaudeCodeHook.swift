import ArgusIPC
import Darwin
import Foundation

/// Translates one Claude Code hook invocation into Agent Status and Turn
/// Completion Socket Requests.
///
/// Claude Code runs every hook as a new process, so nothing survives between
/// events. The reporting session is the Claude Code process that ran the hook,
/// and each request is ordered by a monotonic clock reading, which keeps one
/// process's updates in order across `/clear` and `/resume` without any
/// on-disk state.
enum ClaudeCodeHook {
    static let agentKey = "claude-code"

    enum Action: Equatable {
        case status(AgentSocketStatusState)
        /// Idle followed by one Turn Completion Event.
        case completedTurn
        case clear
    }

    /// Lifecycle mapping. Events that do not change Agent Status return nil.
    static func action(for input: ClaudeCodeHookInput) -> Action? {
        switch input.hookEventName {
        case "SessionStart":
            // `compact` starts a new session mid-turn; the agent is still running.
            guard let source = input.source, ["startup", "resume", "clear", "fork"].contains(source) else {
                return nil
            }
            return .status(.idle)
        case "UserPromptSubmit", "PostToolUse", "PostToolUseFailure":
            // A finished tool also ends any permission prompt that preceded it.
            return .status(.running)
        case "PermissionRequest", "PreToolUse":
            // PreToolUse is installed only for tools that wait on the user.
            return .status(.needsInput)
        case "Notification":
            return notificationAction(for: input.notificationType)
        case "Stop":
            return .completedTurn
        case "StopFailure":
            return .status(.error)
        case "SessionEnd":
            // `/clear` and `/resume` end one session and start another in the
            // same process; the following SessionStart reports idle.
            return input.reason == "clear" || input.reason == "resume" ? nil : .clear
        default:
            return nil
        }
    }

    private static func notificationAction(for type: String?) -> Action? {
        switch type {
        case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
            return .status(.needsInput)
        case "idle_prompt":
            // Stop does not fire after a user interrupt; this recovers idle.
            return .status(.idle)
        default:
            return nil
        }
    }

    struct Context: Equatable {
        let socketPath: String
        let workspaceId: String
        let surfaceId: String
        let sessionId: String
        let sequence: UInt64

        /// Context for an Argus-spawned shell. Outside Argus the hook does nothing.
        init?(environment: [String: String], sessionId: String?, sequence: UInt64) {
            guard let socketPath = environment["ARGUS_SOCKET_PATH"], !socketPath.isEmpty,
                let workspaceId = environment["ARGUS_WORKSPACE_ID"], !workspaceId.isEmpty,
                let surfaceId = environment["ARGUS_SURFACE_ID"], !surfaceId.isEmpty,
                let sessionId, sequence > 0
            else { return nil }
            self.socketPath = socketPath
            self.workspaceId = workspaceId
            self.surfaceId = surfaceId
            self.sessionId = sessionId
            self.sequence = sequence
        }
    }

    /// One Socket Request ready to send.
    enum Request: Equatable {
        case statusChanged(AgentStatusChangedParameters)
        case statusCleared(AgentStatusClearedParameters)
        case turnCompleted(AgentTurnCompletedParameters)

        var id: String {
            switch self {
            case .statusChanged(let params): "claude-code:changed:\(params.sessionId):\(params.sequence)"
            case .statusCleared(let params): "claude-code:cleared:\(params.sessionId):\(params.sequence)"
            case .turnCompleted(let params): params.eventId
            }
        }
    }

    static func requests(for action: Action, context: Context) -> [Request] {
        func status(_ state: AgentSocketStatusState) -> Request {
            .statusChanged(
                AgentStatusChangedParameters(
                    agentKey: agentKey, workspaceId: context.workspaceId, surfaceId: context.surfaceId,
                    state: state, sessionId: context.sessionId, sequence: context.sequence))
        }
        switch action {
        case .status(let state):
            return [status(state)]
        case .completedTurn:
            let eventId = "claude-code:turnCompleted:\(context.sessionId):\(context.sequence)"
            return [
                status(.idle),
                .turnCompleted(
                    AgentTurnCompletedParameters(
                        agentKey: agentKey, workspaceId: context.workspaceId,
                        surfaceId: context.surfaceId, eventId: eventId))
            ]
        case .clear:
            return [
                .statusCleared(
                    AgentStatusClearedParameters(
                        agentKey: agentKey, workspaceId: context.workspaceId, surfaceId: context.surfaceId,
                        sessionId: context.sessionId, sequence: context.sequence))
            ]
        }
    }

    /// Requests for one hook invocation, or none when the input is unreadable,
    /// irrelevant, or outside an Argus Terminal Surface.
    static func requests(
        input: Data,
        environment: [String: String],
        sessionId: String?,
        sequence: UInt64
    ) -> [Request] {
        guard let context = Context(environment: environment, sessionId: sessionId, sequence: sequence),
            let decoded = try? JSONDecoder().decode(ClaudeCodeHookInput.self, from: input),
            let action = action(for: decoded)
        else { return [] }
        return requests(for: action, context: context)
    }

    /// Sends each request in order. Delivery failures are ignored: the hook
    /// must never change Claude Code's behavior.
    static func deliver(_ requests: [Request], socketPath: String, responseTimeout: TimeInterval = 1) {
        let client = ArgusSocketClient(path: socketPath, responseTimeout: responseTimeout)
        for request in requests {
            switch request {
            case .statusChanged(let params):
                _ = try? client.send(
                    ArgusSocketRequest(id: request.id, method: .agentStatusChanged, params: params),
                    expecting: AgentSocketAcknowledgement.self)
            case .statusCleared(let params):
                _ = try? client.send(
                    ArgusSocketRequest(id: request.id, method: .agentStatusCleared, params: params),
                    expecting: AgentSocketAcknowledgement.self)
            case .turnCompleted(let params):
                _ = try? client.send(
                    ArgusSocketRequest(id: request.id, method: .agentTurnCompleted, params: params),
                    expecting: AgentSocketAcknowledgement.self)
            }
        }
    }

    /// Reporting session for the Claude Code process that ran this hook.
    ///
    /// The installed hook command `exec`s the CLI, so the parent process is
    /// Claude Code itself. Its start time distinguishes a reused PID.
    static func parentProcessSessionID() -> String? {
        let parent = getppid()
        guard parent > 1 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, parent]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return "claude-code:\(parent)"
        }
        let start = info.kp_proc.p_un.__p_starttime
        return "claude-code:\(parent):\(start.tv_sec).\(start.tv_usec)"
    }

    /// Monotonic across processes on one boot, which outlives any reporting session.
    static func monotonicSequence() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }
}

/// Fields Argus reads from a Claude Code hook's stdin JSON. Everything else is ignored.
struct ClaudeCodeHookInput: Decodable, Equatable {
    let hookEventName: String
    let source: String?
    let reason: String?
    let notificationType: String?

    private enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case source
        case reason
        case notificationType = "notification_type"
    }
}
