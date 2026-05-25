// NewWorkspaceSheet.swift
// Argus
//
// Sheet dialog for creating a new workspace within a project.
// Supports creating new branches or checking out existing branches
// as git worktrees.

import SwiftUI

struct NewWorkspaceSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// The project to add the workspace to (set by the caller).
    let projectId: UUID

    @State private var branchMode: BranchMode = .new
    @State private var newBranchName: String = ""
    @State private var selectedExistingBranch: String?
    @State private var branchFilter: String = ""
    @State private var availableBranches: [String] = []
    @State private var isLoadingBranches: Bool = false
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    enum BranchMode: String, CaseIterable {
        case new = "New Branch"
        case existing = "Existing Branch"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Text("New Workspace")
                    .font(.system(size: 15, weight: .semibold))
                if let project = workspaceManager.projects.first(where: { $0.id == projectId }) {
                    Text(project.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Branch mode picker
            Picker("", selection: $branchMode) {
                ForEach(BranchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .onChange(of: branchMode) { mode in
                if mode == .existing && availableBranches.isEmpty && !isLoadingBranches {
                    loadBranches()
                }
            }

            // Branch input
            VStack(alignment: .leading, spacing: 8) {
                switch branchMode {
                case .new:
                    newBranchInput
                case .existing:
                    existingBranchPicker
                }
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 80, alignment: .top)

            // Error message
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }

            Spacer()

            Divider()

            // Action buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    createWorkspace()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 400, height: 280)
        .onAppear {
            if branchMode == .existing {
                loadBranches()
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var newBranchInput: some View {
        TextField("Branch name", text: $newBranchName)
            .textFieldStyle(.roundedBorder)

        if !newBranchName.isEmpty && newBranchName.contains(" ") {
            Text("Branch names cannot contain spaces")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    @ViewBuilder
    private var existingBranchPicker: some View {
        if isLoadingBranches {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading branches...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else if availableBranches.isEmpty {
            Text("No available branches")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        } else {
            TextField("Filter branches", text: $branchFilter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredAvailableBranches, id: \.self) { branch in
                        Button(action: {
                            selectedExistingBranch = branch
                        }) {
                            HStack {
                                Text(branch)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if selectedExistingBranch == branch {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selectedExistingBranch == branch ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                    }
                }
            }
            .frame(maxHeight: 96)
        }
    }

    // MARK: - Computed

    private var canCreate: Bool {
        if isCreating { return false }
        switch branchMode {
        case .new:
            let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.contains(" ")
        case .existing:
            return selectedExistingBranch != nil
        }
    }

    private var filteredAvailableBranches: [String] {
        let filter = branchFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty else { return availableBranches }
        return availableBranches.filter { branch in
            branch.localizedCaseInsensitiveContains(filter)
        }
    }

    // MARK: - Actions

    private func loadBranches() {
        guard let project = workspaceManager.projects.first(where: { $0.id == projectId }) else { return }
        isLoadingBranches = true
        Task {
            defer { isLoadingBranches = false }
            do {
                let branches = try await workspaceManager.worktreeService.listWorkspaceBranchChoices(
                    repositoryPath: project.repositoryPath
                )
                availableBranches = branches
                if let selectedExistingBranch,
                   !branches.contains(selectedExistingBranch) {
                    self.selectedExistingBranch = nil
                }
            } catch {
                availableBranches = []
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createWorkspace() {
        isCreating = true
        errorMessage = nil

        Task {
            let branchName: String
            let createNew: Bool

            switch branchMode {
            case .new:
                branchName = newBranchName.trimmingCharacters(in: .whitespaces)
                createNew = true
            case .existing:
                guard let selected = selectedExistingBranch else { return }
                branchName = selected
                createNew = false
            }

            let result = await workspaceManager.addWorkspaceToProject(
                projectId,
                branchName: branchName,
                createNewBranch: createNew
            )

            if result != nil {
                dismiss()
            } else {
                switch workspaceManager.lastWorkspaceCreationError {
                case .branchAlreadyExists(let branchName):
                    errorMessage = "Branch '\(branchName)' already exists"
                default:
                    errorMessage = "Failed to create workspace"
                }
                isCreating = false
            }
        }
    }
}
