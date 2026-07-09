import Foundation
import Testing

@testable import Argus

@Suite
@MainActor
struct AgentStatusStoreTests {
    @Test
    func perPanelStatusOverridesWorkspaceStatus() throws {
        let store = AgentStatusStore()
        let workspaceId = UUID()
        let surfaceId = UUID()

        let workspaceEntry = store.setStatus(
            .running,
            agentKey: "workspace-agent",
            workspaceId: workspaceId
        )
        let panelEntry = store.setStatus(
            .needsInput,
            agentKey: "panel-agent",
            workspaceId: workspaceId,
            surfaceId: surfaceId
        )

        #expect(store.effectiveStatus(workspaceId: workspaceId) == workspaceEntry)
        #expect(store.effectiveStatus(workspaceId: workspaceId, surfaceId: surfaceId) == panelEntry)
        #expect(store.effectiveStatus(workspaceId: workspaceId, surfaceId: UUID()) == workspaceEntry)
    }

    @Test
    func newestRevisionWinsWithinScopeAndWorkspaceSummary() throws {
        let store = AgentStatusStore()
        let workspaceId = UUID()
        let firstSurfaceId = UUID()
        let secondSurfaceId = UUID()

        store.setStatus(.idle, agentKey: "arbitrary/agent:key", workspaceId: workspaceId)
        let newerWorkspaceEntry = store.setStatus(
            .running,
            agentKey: "another unrestricted key",
            workspaceId: workspaceId
        )
        let newestPanelEntry = store.setStatus(
            .error,
            agentKey: "panel-agent",
            workspaceId: workspaceId,
            surfaceId: firstSurfaceId
        )

        #expect(store.effectiveStatus(workspaceId: workspaceId) == newerWorkspaceEntry)
        #expect(
            store.workspaceSummary(
                workspaceId: workspaceId,
                terminalSurfaceIds: [firstSurfaceId, secondSurfaceId],
                includesNonterminalPanels: false
            ) == newestPanelEntry)
    }

    @Test
    func clearOperationsRespectAgentScopeAndWorkspace() throws {
        let store = AgentStatusStore()
        let firstWorkspaceId = UUID()
        let secondWorkspaceId = UUID()
        let surfaceId = UUID()

        store.setStatus(.running, agentKey: "first", workspaceId: firstWorkspaceId)
        store.setStatus(.idle, agentKey: "second", workspaceId: firstWorkspaceId)
        store.setStatus(
            .error,
            agentKey: "first",
            workspaceId: firstWorkspaceId,
            surfaceId: surfaceId
        )
        let otherWorkspaceEntry = store.setStatus(
            .needsInput,
            agentKey: "first",
            workspaceId: secondWorkspaceId
        )

        store.clearStatus(agentKey: "first", workspaceId: firstWorkspaceId)
        #expect(
            store.entries.values.contains {
                $0.agentKey == "second" && $0.scope == .workspace(firstWorkspaceId)
            })

        store.clearStatuses(workspaceId: firstWorkspaceId, surfaceId: surfaceId)
        #expect(store.effectiveStatus(workspaceId: firstWorkspaceId, surfaceId: surfaceId)?.agentKey == "second")

        store.clearStatuses(forWorkspace: firstWorkspaceId)
        #expect(store.entries.values.allSatisfy { $0.scope.workspaceId != firstWorkspaceId })
        #expect(store.effectiveStatus(workspaceId: secondWorkspaceId) == otherWorkspaceEntry)

        store.clearAll()
        #expect(store.entries.isEmpty)
    }

    @Test
    func statesHaveDistinctSymbolsColorsAndLabels() {
        let states = AgentStatusState.allCases

        #expect(Set(states.map(\.symbolName)).count == states.count)
        #expect(Set(states.map(\.semanticColor)).count == states.count)
        #expect(Set(states.map(\.label)).count == states.count)
    }
}
