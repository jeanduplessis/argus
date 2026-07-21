import Testing

@testable import Argus

@Suite
struct WorkspaceTabNavigationTests {
    @Test
    func commandBracketsStayWiredToTabCycling() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        app.containsAll(
            [
                "Button(\"Select Previous Tab\")",
                "workspaceManager.selectPreviousTab()",
                ".keyboardShortcut(\"[\", modifiers: [.command])",
                "Button(\"Select Next Tab\")",
                "workspaceManager.selectNextTab()",
                ".keyboardShortcut(\"]\", modifiers: [.command])"
            ], "tab cycling commands")
    }

    @Test
    @MainActor
    func cyclingSelectsAdjacentTabsWithWraparound() throws {
        let workspace = Workspace(workingDirectory: "/tmp")
        let firstTab = try #require(workspace.panelOrder.first)
        let secondTab = workspace.addTerminalPanel(workingDirectory: "/tmp/second").id
        let lastTab = workspace.addTerminalPanel(workingDirectory: "/tmp/last").id

        workspace.selectNextTab()
        #expect(workspace.activeTabId == firstTab)

        workspace.selectPreviousTab()
        #expect(workspace.activeTabId == lastTab)

        workspace.selectPanel(secondTab)
        workspace.selectPreviousTab()
        #expect(workspace.activeTabId == firstTab)

        workspace.selectNextTab()
        #expect(workspace.activeTabId == secondTab)
    }
}
