import Testing

@testable import Argus

@Suite
struct AgentStatusUIContractTests {
    @Test
    func oneEphemeralStoreIsInjectedFromTheApp() throws {
        try SourceContract("Argus/App/ArgusApp.swift").containsAll(
            [
                "@StateObject private var agentStatusStore = AgentStatusStore()",
                ".environmentObject(agentStatusStore)",
            ], "process-wide Agent Status Store ownership"
        )

        try SourceContract("Argus/Models/SessionSnapshot.swift").excludes(
            "AgentStatus",
            "Session Snapshot must exclude Agent Status Entries"
        )
    }

    @Test
    func tabIconsPreserveLoadingThenStatusThenDefaultPrecedence() throws {
        let tabBar = try SourceContract("Argus/Views/Content/TabBarView.swift")
        let iconSelection = try tabBar.section(
            after: "if panel.isLoading",
            before: "Text(title)"
        )

        #expect(iconSelection.contains("ProgressView()"))
        #expect(iconSelection.contains("else if let agentStatus"))
        #expect(iconSelection.contains("agentStatus.state.symbolName"))
        #expect(iconSelection.contains("agentStatus.state.color"))
        #expect(iconSelection.contains("else if let icon = panel.displayIcon"))
        tabBar.containsAll(
            [
                "workspace.layout(for: tabId).leaves",
                "workspace.panels[$0]?.panelType == .terminal",
                "agentStatusStore.effectiveStatus(workspaceId: workspace.id)",
            ], "Terminal Surface and Workspace-level tab status resolution"
        )
    }

    @Test
    func sidebarStatusReplacesTypeIconAndNamesStateForAccessibility() throws {
        let sidebar = try SourceContract("Argus/Views/Sidebar/SidebarView.swift")
        let row = try sidebar.section(
            after: "private struct SidebarWorkspaceRow: View",
            before: "// MARK: - NSVisualEffectView Wrapper"
        )

        #expect(row.contains("if let agentStatus"))
        #expect(row.contains("agentStatus.state.symbolName"))
        #expect(row.contains("workspace.workspaceType.icon"))
        #expect(row.contains(".accessibilityValue(workspaceAccessibilityValue)"))
        #expect(row.contains(#"values.append("Agent status: \(agentStatus.state.label)")"#))
        #expect(row.contains("includesNonterminalPanels:"))
    }

    @Test
    func implementationDoesNotInventDeferredAgentSubsystems() throws {
        let store = try SourceContract("Argus/Services/AgentStatusStore.swift")
        for forbidden in [
            "Socket", "PID", "Process", "JSON", "Codable", "NotificationCenter", "TTS", "speech",
        ] {
            store.excludes(forbidden, "Agent Status Store must remain socket-independent and ephemeral")
        }
    }
}
