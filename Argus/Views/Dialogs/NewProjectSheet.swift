// NewProjectSheet.swift
// Argus
//
// Sheet dialog for creating a new project from a git repository directory.
// Validates the selected path is a git repo, detects the main branch,
// and creates the project via WorkspaceManager.

import SwiftUI

struct NewProjectSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPath: String = ""
    @State private var displayName: String = ""
    @State private var detectedBranch: String?
    @State private var mainBranch: String = ""
    @State private var isRepositoryValid: Bool = false
    @State private var isValidating: Bool = false
    @State private var validationError: String?
    @State private var branchDetectionWarning: String?
    @State private var isCreating: Bool = false

    private var canCreate: Bool {
        !selectedPath.isEmpty
            && isRepositoryValid
            && validationError == nil
            && !mainBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("New Project")
                .font(.headline)

            // Repository section
            VStack(alignment: .leading, spacing: 4) {
                Text("Repository")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)

                HStack {
                    if selectedPath.isEmpty {
                        Text("No directory selected")
                            .foregroundColor(.secondary)
                    } else {
                        Text(selectedPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    Button("Browse\u{2026}") { browseForDirectory() }
                }
            }

            // Display Name section (visible once a directory is selected)
            if !selectedPath.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display Name")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    TextField("Project name", text: $displayName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Main Branch section (visible once a directory is selected)
            if !selectedPath.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Main Branch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    if isValidating {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Detecting\u{2026}")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        if let error = validationError {
                            Text(error)
                                .foregroundColor(.red)
                        } else {
                            TextField("Main branch", text: $mainBranch)
                                .textFieldStyle(.roundedBorder)

                            if let warning = branchDetectionWarning {
                                Text(warning)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .frame(width: 400, height: 300)
    }

    // MARK: - Actions

    private func browseForDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a git repository"

        if panel.runModal() == .OK, let url = panel.url {
            selectedPath = url.path
            displayName = url.lastPathComponent
            validateRepository()
        }
    }

    private func validateRepository() {
        isValidating = true
        validationError = nil
        branchDetectionWarning = nil
        detectedBranch = nil
        mainBranch = ""
        isRepositoryValid = false

        Task {
            guard let repositoryRoot = try? await workspaceManager.worktreeService
                .canonicalRepositoryRoot(for: selectedPath)
            else {
                validationError = "Not a git repository"
                isValidating = false
                return
            }

            if workspaceManager.hasDuplicateProject(repositoryRoot: repositoryRoot) {
                validationError = "Project already exists for this repository"
                isValidating = false
                return
            }

            isRepositoryValid = true

            do {
                let branch = try await workspaceManager.worktreeService
                    .detectMainBranch(repositoryPath: repositoryRoot)
                detectedBranch = branch
                mainBranch = branch
            } catch {
                branchDetectionWarning = "Could not detect main branch. Enter one manually."
            }

            isValidating = false
        }
    }

    private func createProject() {
        isCreating = true
        let path = selectedPath
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = mainBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let project = await workspaceManager.createProject(
                repositoryPath: path,
                displayName: name.isEmpty ? nil : name,
                mainBranchOverride: branch.isEmpty ? nil : branch
            )
            guard project != nil else {
                validationError = "Could not create project"
                isCreating = false
                return
            }
            dismiss()
        }
    }
}
