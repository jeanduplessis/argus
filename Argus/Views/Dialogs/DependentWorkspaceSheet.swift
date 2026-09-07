import SwiftUI

struct DependentWorkspaceSheet: View {
    let projectID: UUID
    let parentWorkspaceID: UUID
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var parent: StackParentContext?
    @State private var branchName = ""
    @State private var workspaceName = ""
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create dependent Workspace")
                .font(.headline)
            if let project = workspaceManager.projects.first(where: { $0.id == projectID }) {
                Text(project.displayName)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Parent branch")
                    .font(.subheadline.weight(.semibold))
                if let parent {
                    Text(parent.branchName)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(parent.branchName)
                        .textSelection(.enabled)
                    Text(
                        "Starts at commit \(parent.headCommitID.prefix(12)). "
                            + "Working Changes stay in the parent Workspace."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if isLoading {
                    ProgressView("Reading parent…")
                        .controlSize(.small)
                }
                Button("Reload Parent") {
                    Task { await loadParent() }
                }
                .disabled(isLoading || isCreating)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("New branch")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Branch name", text: $branchName)
                        .textFieldStyle(.roundedBorder)
                    Button("Regenerate") { suggestBranch() }
                }
                .disabled(isCreating)
            }
            TextField("Workspace name (optional)", text: $workspaceName)
                .textFieldStyle(.roundedBorder)
                .disabled(isCreating)
            Text(
                "Records a local Stack parent. "
                    + "Does not create a Pull Request or register the branch with Graphite or gh-stack."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Spacer()
                if isCreating { ProgressView().controlSize(.small) }
                Button("Create Workspace") {
                    Task { await create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isCreating || parent == nil || branchName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(isCreating)
        .task {
            suggestBranch()
            await loadParent()
        }
    }

    private func loadParent() async {
        isLoading = true
        errorMessage = nil
        parent = nil
        defer { isLoading = false }
        do {
            let context = try await workspaceManager.inspectStackParent(for: parentWorkspaceID)
            guard !Task.isCancelled else { return }
            parent = context
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func suggestBranch() {
        branchName = RandomBranchNameGenerator.generate(prefix: workspaceManager.settings.newBranchPrefix)
    }

    private func create() async {
        guard !isCreating, let parent else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let workspace = try await workspaceManager.addDependentWorkspace(
                to: projectID, parentWorkspaceID: parentWorkspaceID,
                newBranch: branchName.trimmingCharacters(in: .whitespacesAndNewlines), expectedParent: parent
            )
            let title = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { workspaceManager.renameWorkspace(workspace.id, title: title) }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
