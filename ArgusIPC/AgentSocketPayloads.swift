import Foundation

// MARK: - Agent methods

/// Agent Status states as they appear on the wire.
public enum AgentSocketStatusState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case needsInput
    case error
}

/// `agent.statusChanged` parameters.
public struct AgentStatusChangedParameters: Codable, Sendable, Equatable {
    public let agentKey: String
    public let workspaceId: String
    public let surfaceId: String?
    public let state: AgentSocketStatusState
    public let sessionId: String
    public let sequence: UInt64

    public init(
        agentKey: String,
        workspaceId: String,
        surfaceId: String?,
        state: AgentSocketStatusState,
        sessionId: String,
        sequence: UInt64
    ) {
        self.agentKey = agentKey
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.state = state
        self.sessionId = sessionId
        self.sequence = sequence
    }
}

/// `agent.statusCleared` parameters.
public struct AgentStatusClearedParameters: Codable, Sendable, Equatable {
    public let agentKey: String
    public let workspaceId: String
    public let surfaceId: String?
    public let sessionId: String
    public let sequence: UInt64

    public init(agentKey: String, workspaceId: String, surfaceId: String?, sessionId: String, sequence: UInt64) {
        self.agentKey = agentKey
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.sessionId = sessionId
        self.sequence = sequence
    }
}

/// `agent.turnCompleted` parameters.
public struct AgentTurnCompletedParameters: Codable, Sendable, Equatable {
    public let agentKey: String
    public let workspaceId: String
    public let surfaceId: String
    public let eventId: String

    public init(agentKey: String, workspaceId: String, surfaceId: String, eventId: String) {
        self.agentKey = agentKey
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.eventId = eventId
    }
}

/// Result of any agent method. Agent Integrations treat delivery as
/// best-effort, so the result is acknowledged but not inspected.
public struct AgentSocketAcknowledgement: Codable, Sendable {
    public let accepted: Bool?

    public init(accepted: Bool?) {
        self.accepted = accepted
    }
}
