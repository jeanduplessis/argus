import AppKit
import SwiftUI

/// Repository registry access remains available even when no navigation heading exists.
struct WorkspaceRepositoryPicker: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var showsSetupConfiguration = false

    var body: some View {
        VStack(spacing: 8) {
            Picker("Repository", selection: $selection) {
                Text("Standalone Workspace").tag(nil as UUID?)
                ForEach(workspaceManager.projects) { project in
                    Text(project.displayName).tag(Optional(project.id))
                }
            }
            if let project = workspaceManager.projects.first(where: { $0.id == selection }) {
                HStack {
                    Button("Worktree Setup…") { showsSetupConfiguration = true }
                    if workspaceManager.workspaceIds(for: project).isEmpty {
                        Button("Remove Empty Repository…") { confirmRemoval(project) }
                    }
                }
            }
        }
        .sheet(isPresented: $showsSetupConfiguration) {
            if let project = workspaceManager.projects.first(where: { $0.id == selection }) {
                WorktreeSetupSheet(project: project).environmentObject(workspaceManager)
            }
        }
    }

    private func confirmRemoval(_ project: Project) {
        guard
            confirmDestructiveAction(
                title: "Remove repository \"\(project.displayName)\"?",
                message: "This removes saved repository configuration, including Worktree Setup consent. "
                    + "No files or worktrees are deleted. Repositories with open Workspaces cannot be removed here.",
                confirmTitle: "Remove Repository")
        else { return }
        if workspaceManager.removeEmptyProject(project.id) { selection = nil }
    }
}

struct WorkspaceBranchPicker: View {
    let isLoading: Bool
    let branches: [String]
    @Binding var filter: String
    @Binding var selection: String?

    var body: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading branches...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else if branches.isEmpty {
            Text("No available branches")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else {
            TextField("Filter branches", text: $filter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredAvailableBranches, id: \.self) { branch in
                        Button(
                            action: {
                                selection = branch
                            },
                            label: {
                                HStack {
                                    Text(branch)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if selection == branch {
                                        Text("Selected")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        )
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == branch ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    private var filteredAvailableBranches: [String] {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilter.isEmpty else { return branches }
        return branches.filter { branch in
            branch.localizedCaseInsensitiveContains(trimmedFilter)
        }
    }

}
