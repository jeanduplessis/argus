import AppKit
import SwiftUI

struct StackParentSheet: View {
    let request: StackMaintenanceSheetRequest
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var pullRequestStatusModel: WorkspacePullRequestStatusModel
    @EnvironmentObject private var gitStatusViewModel: GitStatusViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var context: StackParentContext?
    @State private var parentName = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var showsSyncSteps = false

    private var pullRequestTarget: String? {
        guard let context else { return nil }
        return workspaceManager.stackPullRequestEvidence(
            for: request.workspaceID, context: context, statusModel: pullRequestStatusModel, at: .now
        )?.status.baseBranchName
    }

    private var instructions: StackSyncInstructions? {
        guard let context else { return nil }
        let project = workspaceManager.project(for: request.workspaceID)
        let parents = project.flatMap { workspaceManager.workspaceStackSnapshots[$0.id]?.parents } ?? [:]
        return StackSyncInstructions(
            branch: context.branchName, recordedParent: context.recordedParent,
            pullRequestTarget: pullRequestTarget,
            dependents: parents.filter { $0.value == context.branchName }.map(\.key).sorted()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.showsSyncSteps ? "Review Stack sync steps" : "Stack parent")
                .font(.headline)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .leading, spacing: 14) {
                        if let context {
                            parentDetails(context)
                            parentEditor(context)
                            DisclosureGroup("Sync after a parent merges", isExpanded: $showsSyncSteps) {
                                if let instructions {
                                    Text(instructions.text)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .padding(.top, 8)
                                }
                            }
                        } else if isLoading {
                            ProgressView("Reading local Stack context…")
                                .controlSize(.small)
                        }
                        if let resultMessage {
                            Text(resultMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 500)
            Divider()
            HStack {
                Button("Refresh") {
                    pullRequestStatusModel.refresh(workspaceID: request.workspaceID)
                    Task { await load() }
                }
                .disabled(isLoading || isSaving)
                Button("Open New Terminal Tab") { openTerminal() }
                    .disabled(context == nil || isSaving)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled(isSaving)
        .task {
            showsSyncSteps = request.showsSyncSteps
            await load()
        }
    }

    private func parentDetails(_ context: StackParentContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(context.branchName)
                .font(.system(.body, design: .monospaced).weight(.semibold))
            Text("Recorded parent: \(context.recordedParent ?? "None")")
            if let description = comparisonDescription(context) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(context.sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let issue = context.editingIssue ?? context.parentIssue {
                Text(issue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let pullRequestTarget {
                Text("Pull Request target: \(pullRequestTarget)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    private func comparisonDescription(_ context: StackParentContext) -> String? {
        guard let comparison = request.comparison else { return nil }
        guard comparison.rootPath == context.worktreePath, comparison.branchName == context.branchName,
            comparison.headCommitID == context.headCommitID, comparison.recordedParentBranch == context.recordedParent
        else {
            return "The captured comparison no longer matches this checkout. Refresh Changes to review the new diff."
        }
        guard let reference = comparison.resolvedRef, let commit = comparison.baseCommitID else {
            return "The recorded parent comparison is unavailable. No replacement base was selected."
        }
        return "Displayed comparison snapshot: \(reference) at \(commit.prefix(12))."
    }

    private func parentEditor(_ context: StackParentContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Recorded parent branch", text: $parentName)
                .textFieldStyle(.roundedBorder)
                .disabled(isSaving || isLoading)
            Text(
                "Changes local Stack grouping and Against Base only. "
                    + "Does not rebase commits or change a Pull Request. "
                    + "Local overrides take priority over Graphite and gh-stack metadata; "
                    + "remove the override to follow those tools."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Save Local Parent") {
                    Task { await save(parentName.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
                .disabled(isSaving || isLoading || parentName.isEmpty || context.editingIssue != nil)
                Button("Remove Local Override") {
                    Task { await save(nil) }
                }
                .disabled(isSaving || isLoading || !context.hasLocalOverride || context.editingIssue != nil)
                if isSaving { ProgressView().controlSize(.small) }
            }
            Text(
                "Removing the local override uses any remaining tool or Git configuration metadata; "
                    + "it does not detach the branch."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Copy Sync Instructions") {
                guard let text = instructions?.text else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        resultMessage = nil
        defer { isLoading = false }
        do {
            let updated = try await workspaceManager.inspectStackParent(for: request.workspaceID)
            guard !Task.isCancelled else { return }
            context = updated
            parentName = updated.recordedParent ?? ""
        } catch {
            guard !Task.isCancelled else { return }
            context = nil
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ parent: String?) async {
        guard !isSaving, let context else { return }
        isSaving = true
        errorMessage = nil
        resultMessage = nil
        defer { isSaving = false }
        do {
            let updated = try await workspaceManager.setStackParent(parent, for: request.workspaceID, expected: context)
            self.context = updated
            parentName = updated.recordedParent ?? ""
            resultMessage = "Local parent metadata updated. Commit history and Pull Request targets were not changed."
            if workspaceManager.selectedWorkspaceId == request.workspaceID {
                await gitStatusViewModel.refreshAfterLocalMetadataChange(
                    workspaceId: request.workspaceID, rootPath: updated.worktreePath)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openTerminal() {
        guard let context,
            let workspace = workspaceManager.workspaces.first(where: { $0.id == request.workspaceID }),
            let project = workspaceManager.project(for: workspace.id),
            WorkspacePullRequestTarget.normalizedPath(project.repositoryPath) == context.repositoryPath
        else {
            errorMessage = "The Workspace changed. Refresh before opening a Terminal Tab."
            return
        }
        let path = workspace.workspaceType == .mainCheckout ? project.repositoryPath : workspace.worktreePath
        guard let path, WorkspacePullRequestTarget.normalizedPath(path) == context.worktreePath,
            workspace.addTerminalPanel(workingDirectory: context.worktreePath) != nil
        else {
            errorMessage = "Could not open a Terminal Tab in the initiating Workspace."
            return
        }
        dismiss()
        workspaceManager.selectWorkspace(workspace.id)
    }
}
