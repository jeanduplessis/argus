import Foundation
import Testing

@testable import Argus

@Suite
struct WorkspaceStackMaintenanceUIContractTests {
    @Test
    func dependentCreationCarriesTheInitiatingWorkspaceThroughTheSheet() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+StackActions.swift").containsAll(
            [
                "Create Dependent Workspace", "parentWorkspaceId", "workspaceID",
                "ForEach(group.rows)", "if let workspaceID = row.workspaceId"
            ], "Stack creation selects an explicit parent rather than guessing a fork tip")
        try SourceContract("Argus/Views/MainWindowView.swift").containsAll(
            [
                "request.parentWorkspaceId", "DependentWorkspaceSheet(projectID:",
                "projectId: request.projectId, collectionId: request.collectionId,"
            ], "the new source retains the existing creation workflow")
        try SourceContract("Argus/Views/Dialogs/DependentWorkspaceSheet.swift").containsAll(
            [
                "inspectStackParent(for: parentWorkspaceID)", "expectedParent: parent",
                "Working Changes stay in the parent Workspace", "Does not create a Pull Request",
                ".interactiveDismissDisabled(isCreating)", ".keyboardShortcut(.cancelAction)"
            ], "dependent creation previews and revalidates the chosen parent")
        try SourceContract("Argus/Views/Dialogs/DependentWorkspaceSheet.swift").excludes(
            "suggestAvailableBranchName", "the local-only source must not use remote-querying branch suggestions")
    }

    @Test
    func noticesAreOutsideTheCleanStateAndSectionDisclosure() throws {
        let content = try SourceContract("Argus/Views/GitSidebar/GitSidebarView+Content.swift")
        let owned = try content.section(
            after: "private func statusContent(", before: "private func cleanWorkingTreeContent")
        let notice = try #require(owned.range(of: "StackComparisonNotice(owner: owner, summary: summary)"))
        let clean = try #require(owned.range(of: "if summary.hasNoSectionContent"))
        #expect(notice.lowerBound < clean.lowerBound)
        #expect(owned.contains("owner.request.presentation.showBaseBranchChanges"))
    }

    @Test
    func mergedDisclosureKeepsRealRowsAndMeasuredConnections() throws {
        try SourceContract("Argus/Views/Sidebar/SidebarView+Stacks.swift").containsAll(
            [
                "TimelineView(.periodic", "WorkspaceStackMergedPresentation(", "protectedWorkspaceIDs: protectedIDs",
                "workspaceManager.selectedWorkspaceId", "runningProcessCount", "ForEach(group.rows)",
                "!merged.hiddenWorkspaceIDs.contains(workspaceId)", "SidebarStackReferenceRow(row: row)",
                "SidebarCollapsedWorkspaceSummary(workspaceIds: Array(merged.hiddenWorkspaceIDs))",
                "rows: group.rows", "anchors: anchors"
            ], "folding is timed presentation without replacing dependency edges or navigation")
        try SourceContract("Argus/Views/Sidebar/SidebarMergedStackDisclosure.swift").containsAll(
            [
                "Button(action: onToggle)", ".onHover", ".focused($isFocused)", ".cursor(.pointingHand)",
                ".contentShape(Rectangle())", ".accessibilityLabel", ".accessibilityValue",
                "Worktrees and branches are retained"
            ], "merged history has a reversible accessible disclosure")
    }

    @Test
    func syncGuideDoesNotExecuteCommandsAndUsesTheInitiatingWorkspace() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/StackParentSheet.swift")
        sheet.containsAll(
            [
                "private func openTerminal()", "$0.id == request.workspaceID", "context.worktreePath",
                "workspace.addTerminalPanel(workingDirectory:", "workspaceManager.selectWorkspace(workspace.id)",
                "Commit history and Pull Request targets were not changed."
            ], "only explicit terminal creation changes navigation")
        sheet.containsAll(
            [
                "stackPullRequestEvidence(", "TimelineView(.periodic", "refreshAfterLocalMetadataChange(",
                "workspaceManager.selectedWorkspaceId == request.workspaceID"
            ],
            "sync instructions require fresh ownership-bound evidence and expire while visible")
        sheet.excludes("pullRequestStatusModel.state(for:", "cached status must not supply a sync target")
        for path in [
            "Argus/Views/Dialogs/StackParentSheet.swift", "Argus/Views/Dialogs/StackMaintenanceSheets.swift"
        ] {
            let source = try SourceContract(path)
            for mutation in ["Process()", "runGit(", "sendText(", "insertText(", "deleteWorktree("] {
                source.excludes(mutation, "guidance must not execute Git or inject commands into a live terminal")
            }
        }
    }

    @Test(arguments: ["parent", "main", "release"])
    func syncGuideRequiresIndependentMergeVerification(pullRequestTarget: String) {
        let text = StackSyncInstructions(
            branch: "child", recordedParent: "parent", pullRequestTarget: pullRequestTarget,
            dependents: ["next-layer", "sibling-layer"]
        ).text

        #expect(text.contains("Current Pull Request target for child: \(pullRequestTarget)."))
        #expect(text.contains("Independently verify whether parent merged and which branch received it."))
        #expect(
            text.contains("The child's current Pull Request target does not establish the parent's merge destination."))
        #expect(!text.contains("parent merged into"))
        #expect(text.contains("Restack child and its dependents with the correct old parent commit boundary."))
        #expect(text.contains("Recorded direct dependents: next-layer, sibling-layer. Review their descendants too."))
        #expect(text.contains("Save Working Changes and stop agents in the affected Workspaces."))
        #expect(text.contains("Preserve backup refs before rewriting history."))
        #expect(
            text.contains(
                "After a squash merge, changing the PR target or running a plain rebase onto main "
                    + "can include already merged changes."))
        #expect(text.contains("A metadata edit does not rebase commits."))
        #expect(text.contains("Review pushing and PR target changes separately, then refresh Argus."))
        #expect(
            text.contains(
                "Third-party sync commands may fetch, rebase, force-push, and update PRs; Argus does not run them."))
    }

    @Test
    func syncGuideKeepsAnUnknownPullRequestTargetUnknown() {
        let text = StackSyncInstructions(
            branch: "child", recordedParent: "parent", pullRequestTarget: nil, dependents: []
        ).text

        #expect(text.contains("Current Pull Request target for child: unknown."))
        #expect(text.contains("Independently verify whether parent merged and which branch received it."))
        #expect(!text.contains("parent merged into"))
        #expect(!text.contains("Recorded direct dependents:"))
    }

    @Test
    func cleanupRequiresExplicitCloseOnlyConfirmation() throws {
        let sheet = try SourceContract("Argus/Views/Dialogs/MergedWorkspaceCleanupSheet.swift")
        sheet.containsAll(
            [
                "All Worktrees, Working Changes, and branches stay on disk.",
                "Button(\"Cancel\")", ".foregroundStyle(.red)", ".interactiveDismissDisabled(isClosing)",
                "selectedIDs.isSubset(of: eligibleIDs)", "workspaceManager.closeMergedWorkspaces(selected)",
                "candidate.matchesStackSnapshot", "request.workspaceIDs.contains(candidate.id)",
                "selectedIDs.formIntersection(eligibleIDs)", "selectedIDs.formIntersection(candidates.map(\\.id))",
                "refreshMergedStackCandidates(", "reloadCandidates(selectInitially: true)"
            ], "cleanup confirms exact captured resources, preserves deselection, and revalidates evidence")
        let close = try sheet.section(after: "private func close() async {", before: "dismiss()")
        #expect(!close.contains("currentCandidates("), "Closing must validate only the supplied candidate")
        sheet.excludes("deletingWorktree:", "cleanup never enters the worktree deletion workflow")
        sheet.excludes("role: .destructive", "native confirmation must avoid unsafe symbol rendering")
    }
}
