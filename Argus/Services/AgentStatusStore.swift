import Combine
import Foundation

/// In-memory owner of Agent Status Entries for the current app process.
@MainActor
final class AgentStatusStore: ObservableObject {
    @Published private(set) var entries: [AgentStatusEntryID: AgentStatusEntry] = [:]

    private var latestRevision: UInt64 = 0

    /// Sets an Agent Status Entry. Agent Keys are accepted without validation.
    @discardableResult
    func setStatus(
        _ state: AgentStatusState,
        agentKey: String,
        workspaceId: UUID,
        surfaceId: UUID? = nil
    ) -> AgentStatusEntry {
        latestRevision &+= 1
        let scope = surfaceId.map {
            AgentStatusScope.terminalSurface(workspaceId: workspaceId, surfaceId: $0)
        } ?? .workspace(workspaceId)
        let entry = AgentStatusEntry(
            agentKey: agentKey,
            scope: scope,
            state: state,
            revision: latestRevision
        )
        entries[entry.id] = entry
        return entry
    }

    /// Resolves a Terminal Surface override before its Workspace-level fallback.
    func effectiveStatus(workspaceId: UUID, surfaceId: UUID? = nil) -> AgentStatusEntry? {
        if let surfaceId,
           let panelEntry = newestStatus(
               in: .terminalSurface(workspaceId: workspaceId, surfaceId: surfaceId)
           ) {
            return panelEntry
        }
        return newestStatus(in: .workspace(workspaceId))
    }

    /// Returns the newest status that is effective for any Panel in a Workspace.
    func workspaceSummary(
        workspaceId: UUID,
        terminalSurfaceIds: [UUID],
        includesNonterminalPanels: Bool
    ) -> AgentStatusEntry? {
        var effectiveEntries = terminalSurfaceIds.compactMap {
            effectiveStatus(workspaceId: workspaceId, surfaceId: $0)
        }

        if includesNonterminalPanels || terminalSurfaceIds.isEmpty,
           let workspaceEntry = effectiveStatus(workspaceId: workspaceId) {
            effectiveEntries.append(workspaceEntry)
        }

        return newest(in: effectiveEntries)
    }

    /// Clears one agent from one exact scope.
    func clearStatus(
        agentKey: String,
        workspaceId: UUID,
        surfaceId: UUID? = nil
    ) {
        let scope = surfaceId.map {
            AgentStatusScope.terminalSurface(workspaceId: workspaceId, surfaceId: $0)
        } ?? .workspace(workspaceId)
        entries.removeValue(forKey: AgentStatusEntryID(scope: scope, agentKey: agentKey))
    }

    /// Clears every agent from one exact Workspace or Terminal Surface scope.
    func clearStatuses(workspaceId: UUID, surfaceId: UUID? = nil) {
        let scope = surfaceId.map {
            AgentStatusScope.terminalSurface(workspaceId: workspaceId, surfaceId: $0)
        } ?? .workspace(workspaceId)
        entries = entries.filter { $0.key.scope != scope }
    }

    /// Clears Workspace-level and Per-panel Agent Status for one Workspace.
    func clearStatuses(forWorkspace workspaceId: UUID) {
        entries = entries.filter { $0.key.scope.workspaceId != workspaceId }
    }

    func clearAll() {
        entries.removeAll()
    }

    private func newestStatus(in scope: AgentStatusScope) -> AgentStatusEntry? {
        newest(in: entries.values.filter { $0.scope == scope })
    }

    private func newest<S: Sequence>(in candidates: S) -> AgentStatusEntry?
    where S.Element == AgentStatusEntry {
        candidates.max { left, right in
            if left.revision != right.revision {
                return left.revision < right.revision
            }
            return left.agentKey > right.agentKey
        }
    }
}
