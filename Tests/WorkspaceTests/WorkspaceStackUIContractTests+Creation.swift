import Foundation
import Testing

@testable import Argus

extension WorkspaceStackUIContractTests {
    // MARK: - New Workspace in Stack… source contracts

    @Test
    func stackHeaderContextMenuProvidesNewWorkspaceInStackAction() throws {
        let stacks = try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift")
        stacks.containsAll(
            [
                "Button(\"New Workspace in Stack…\")",
                "group.newWorkspaceParentBranch",
                "\"parentBranch\": parentBranch",
                "name: .showNewWorkspaceSheet"
            ],
            "Stack Group header context menu offers New Workspace in Stack\u{2026} with last real row branch as parent")
        // The action must appear before move actions in the context menu
        let contextMenu = try stacks.section(
            after: ".contextMenu {", before: "workspaceMoveActions(for: workspaceId, isStack: true)")
        #expect(contextMenu.contains("New Workspace in Stack"))
        #expect(contextMenu.contains("parentBranch"))
        #expect(!contextMenu.contains("selectWorkspace("))
    }

    @Test
    func newWorkspaceInStackUsesLastOpenBranchInDisplayedForkOrder() {
        let parent = WorkspaceStackRow(
            branch: "parent", parentBranch: "main", dependentBranches: ["first", "last"], workspaceId: UUID())
        let first = WorkspaceStackRow(
            branch: "first", parentBranch: "parent", dependentBranches: [], workspaceId: UUID())
        let last = WorkspaceStackRow(
            branch: "last", parentBranch: "parent", dependentBranches: [], workspaceId: UUID())
        let reference = WorkspaceStackRow(
            branch: "reference", parentBranch: "last", dependentBranches: [], workspaceId: nil)
        let group = WorkspaceStackGroup(id: "stack", baseBranch: "main", rows: [parent, first, last, reference])
        #expect(group.newWorkspaceParentBranch == "last")
        let reordered = WorkspaceStackGroup(id: "stack", baseBranch: "main", rows: [parent, last, first])
        #expect(reordered.newWorkspaceParentBranch == "first")
    }

    @Test
    func mainWindowForwardsParentBranchFromNotificationToSheet() throws {
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        window.containsAll(
            [
                "let stackParentBranch: String?",
                "let parentBranch = notification.userInfo?[\"parentBranch\"] as? String",
                "stackParentBranch: parentBranch",
                "NewWorkspaceSheet(projectId: request.projectId, stackParentBranch: request.stackParentBranch)"
            ], "MainWindowView threads parentBranch from notification through request to sheet")
    }

    @Test
    func newWorkspaceSheetLocksSourceToNewBranchWhenStackParentIsSet() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/NewWorkspaceSheet.swift")
        sheet.containsAll(
            [
                "var stackParentBranch: String?",
                "@State private var branchMode: BranchMode = .new",
                "if stackParentBranch == nil {",
                "Picker(\"Source\"",
                "stackParentBranch.map {",
                "Based on",
                "parentBranch: stackParentBranch"
            ], "sheet locks source picker to new-branch-only and shows parent context when stackParentBranch is set")
        // The picker must only appear when stackParentBranch == nil
        let sourcePicker = try sheet.section(
            after: "if stackParentBranch == nil {",
            before: "switch branchMode {")
        #expect(sourcePicker.contains("Picker(\"Source\""))
    }

    @Test
    func managerAndServiceExposeParentBranchParameter() throws {
        let manager = try SourceContract("Argus/Services/WorkspaceManager+Projects.swift")
        manager.containsAll(
            [
                "parentBranch: String? = nil",
                "parentBranch: parentBranch"
            ], "addWorkspaceToProject accepts and threads parentBranch to createWorktree")
        let service = try SourceContract("Argus/Services/WorktreeService+Operations.swift")
        service.containsAll(
            [
                "parentBranch: String? = nil",
                "Stack creation requires a new branch",
                "--no-track",
                "refs/heads/",
                "\"config\", \"--local\"",
                "branch.",
                "Could not record stack parent"
            ], "createWorktree implements stack branch creation with start-point, no-track, and config recording")
        service.contains(
            "if parentBranch != nil, !createNewBranch {",
            "service boundary rejects existing-branch mode when parentBranch is supplied")
    }
}
