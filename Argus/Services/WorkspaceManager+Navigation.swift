import Foundation

extension WorkspaceManager {
    func selectWorkspace(_ workspaceId: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return }
        selectedWorkspace?.activePanel?.unfocus()
        selectedWorkspaceId = workspaceId
        selectedWorkspace?.activePanel?.focus()
    }

    func selectWorkspaceByIndex(_ index: Int) {
        let ordered = sidebarOrderedWorkspaces
        guard index >= 0, index < ordered.count else { return }
        selectWorkspace(ordered[index].workspace.id)
    }

    func selectLastWorkspace() {
        guard let last = sidebarOrderedWorkspaces.last else { return }
        selectWorkspace(last.workspace.id)
    }

    func selectNextWorkspace() {
        guard let currentId = selectedWorkspaceId,
            let currentIndex = workspaces.firstIndex(where: { $0.id == currentId })
        else { return }
        selectWorkspace(workspaces[(currentIndex + 1) % workspaces.count].id)
    }

    func selectPreviousWorkspace() {
        guard let currentId = selectedWorkspaceId,
            let currentIndex = workspaces.firstIndex(where: { $0.id == currentId })
        else { return }
        let previousIndex = (currentIndex - 1 + workspaces.count) % workspaces.count
        selectWorkspace(workspaces[previousIndex].id)
    }

    func renameWorkspace(_ workspaceId: UUID, title: String) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.setCustomTitle(title)
        if selectedWorkspaceId == workspaceId {
            notifyWorkspaceContextChanged()
        }
    }

    func reorderWorkspace(from source: Int, to destination: Int) {
        guard source >= 0, source < workspaces.count,
            destination >= 0, destination < workspaces.count,
            source != destination
        else { return }
        workspaces.insert(workspaces.remove(at: source), at: destination)
    }

    func reorderWorkspace(
        in projectId: UUID,
        moving workspaceId: UUID,
        before targetWorkspaceId: UUID
    ) {
        guard let project = projects.first(where: { $0.id == projectId }),
            let source = project.workspaceIds.firstIndex(of: workspaceId),
            let target = project.workspaceIds.firstIndex(of: targetWorkspaceId),
            source != target
        else { return }
        project.moveWorkspace(from: source, to: source < target ? max(target - 1, 0) : target)
        syncFlatWorkspaceOrderToSidebarOrder()
    }

    @discardableResult
    func addTab(workingDirectory: String? = nil) -> TerminalPanel? {
        selectedWorkspace?.addTerminalPanel(workingDirectory: workingDirectory)
    }

    @discardableResult
    func addBrowserTab(url: URL? = nil) -> BrowserPanel? {
        selectedWorkspace?.addBrowserPanel(url: url, configuration: browserPanelConfiguration)
    }

    func requestFindInActiveBrowser() {
        (selectedWorkspace?.activePanel as? BrowserPanel)?.requestFind()
    }

    @discardableResult
    func splitActiveTerminal(direction: PanelSplitDirection) -> TerminalPanel? {
        selectedWorkspace?.splitActiveTerminal(direction: direction)
    }

    func closeCurrentTab() {
        guard let workspace = selectedWorkspace else { return }
        let closesLastWorkspaceTab =
            workspace.panelOrder.count == 1
            && (workspace.activeTabLayout?.leaves.count ?? 1) == 1
        if closesLastWorkspaceTab,
            shouldConfirmWorktreeDeletionBeforeClosing(workspace.id)
        {
            NotificationCenter.default.post(
                name: .showCloseWorkspaceConfirmation,
                object: nil,
                userInfo: ["workspaceId": workspace.id]
            )
            return
        }
        workspace.closeActivePaneOrTab()
        if workspace.panelOrder.isEmpty {
            removeWorkspace(workspace.id)
        }
    }

    func handleWorkspaceShortcut(number: Int) {
        if number == 9 {
            selectLastWorkspace()
        } else {
            selectWorkspaceByIndex(number - 1)
        }
    }

    func workspace(containingPanel panelId: UUID) -> Workspace? {
        workspaces.first { $0.panels[panelId] != nil }
    }

    func focusPanel(_ panelId: UUID) {
        guard let workspace = workspace(containingPanel: panelId) else { return }
        if selectedWorkspaceId != workspace.id {
            selectedWorkspaceId = workspace.id
        }
        workspace.selectPanel(panelId)
    }

    func sidebarNumber(for workspaceId: UUID) -> Int? {
        globalSidebarIndex(for: workspaceId)
    }

    var sidebarOrderedWorkspaces: [(project: Project, workspace: Workspace)] {
        projects.flatMap { project in
            project.workspaceIds.compactMap { workspaceId in
                workspaces.first(where: { $0.id == workspaceId }).map { (project, $0) }
            }
        }
    }

    func globalSidebarIndex(for workspaceId: UUID) -> Int? {
        sidebarOrderedWorkspaces.firstIndex { $0.workspace.id == workspaceId }.map { $0 + 1 }
    }

    private func syncFlatWorkspaceOrderToSidebarOrder() {
        let orderedIds = sidebarOrderedWorkspaces.map(\.workspace.id)
        let indexById = Dictionary(
            uniqueKeysWithValues: orderedIds.enumerated().map { ($0.element, $0.offset) }
        )
        workspaces.sort { lhs, rhs in
            (indexById[lhs.id] ?? Int.max) < (indexById[rhs.id] ?? Int.max)
        }
    }

    private var browserPanelConfiguration: BrowserPanelConfiguration {
        BrowserPanelConfiguration(
            homepage: settings.homepage,
            searchProvider: settings.searchProvider,
            pageZoom: settings.defaultZoom,
            developerToolsEnabled: settings.webInspectorEnabled,
            dataStore: settings.browserDataStore
        )
    }
}
