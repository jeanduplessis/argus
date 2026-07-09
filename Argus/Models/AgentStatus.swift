import SwiftUI

/// Semantic colors used to distinguish Agent Status states.
enum AgentStatusColor: String, CaseIterable, Sendable {
    case secondary
    case blue
    case orange
    case red

    var color: Color {
        switch self {
        case .secondary: .secondary
        case .blue: .blue
        case .orange: .orange
        case .red: .red
        }
    }
}

/// Display state reported by an Agent Integration.
enum AgentStatusState: String, CaseIterable, Sendable {
    case idle
    case running
    case needsInput
    case error

    var symbolName: String {
        switch self {
        case .idle: "pause.circle.fill"
        case .running: "bolt.circle.fill"
        case .needsInput: "questionmark.bubble.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var semanticColor: AgentStatusColor {
        switch self {
        case .idle: .secondary
        case .running: .blue
        case .needsInput: .orange
        case .error: .red
        }
    }

    var color: Color { semanticColor.color }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .needsInput: "Needs input"
        case .error: "Error"
        }
    }
}

/// Runtime scope for one Agent Status Entry.
enum AgentStatusScope: Hashable, Sendable {
    case workspace(UUID)
    case terminalSurface(workspaceId: UUID, surfaceId: UUID)

    var workspaceId: UUID {
        switch self {
        case .workspace(let workspaceId): workspaceId
        case .terminalSurface(let workspaceId, _): workspaceId
        }
    }
}

/// Stable identity for one agent within one Agent Status scope.
struct AgentStatusEntryID: Hashable, Sendable {
    let scope: AgentStatusScope
    let agentKey: String
}

/// Ephemeral Agent Status telemetry owned by the running Argus Application.
struct AgentStatusEntry: Identifiable, Equatable, Sendable {
    let agentKey: String
    let scope: AgentStatusScope
    let state: AgentStatusState
    let revision: UInt64

    var id: AgentStatusEntryID {
        AgentStatusEntryID(scope: scope, agentKey: agentKey)
    }
}
