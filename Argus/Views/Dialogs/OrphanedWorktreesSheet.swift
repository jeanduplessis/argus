// OrphanedWorktreesSheet.swift
// Argus
//
// Non-blocking sheet shown on app launch when orphaned worktrees are detected.
// Lists orphaned worktrees and lets the user adopt, delete, or dismiss each one.

import SwiftUI

struct OrphanedWorktreesSheet: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss

    /// The list of orphaned worktrees to display.
    @State var orphans: [OrphanedWorktreeInfo]

    /// Tracks which orphans are currently being processed.
    @State private var processingIds: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("Orphaned Worktrees Detected")
                .font(.headline)

            // Description
            Text("The following worktrees on disk have no corresponding workspace. You can adopt them back into their project, delete them, or dismiss this dialog.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Orphan list
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(orphans) { orphan in
                        OrphanRow(
                            orphan: orphan,
                            isProcessing: processingIds.contains(orphan.id),
                            onAdopt: { adoptOrphan(orphan) },
                            onDelete: { deleteOrphan(orphan) }
                        )
                    }
                }
            }
            .frame(maxHeight: 300)

            // Dismiss button
            HStack {
                Spacer()
                Button("Dismiss") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // MARK: - Actions

    private func adoptOrphan(_ orphan: OrphanedWorktreeInfo) {
        processingIds.insert(orphan.id)
        Task {
            guard workspaceManager.projects.first(where: { $0.id == orphan.projectId }) != nil else {
                processingIds.remove(orphan.id)
                return
            }

            _ = workspaceManager.adoptOrphanedWorktree(orphan)

            orphans.removeAll { $0.id == orphan.id }
            processingIds.remove(orphan.id)

            if orphans.isEmpty { dismiss() }
        }
    }

    private func deleteOrphan(_ orphan: OrphanedWorktreeInfo) {
        processingIds.insert(orphan.id)
        Task {
            guard let project = workspaceManager.projects.first(where: { $0.id == orphan.projectId }) else {
                processingIds.remove(orphan.id)
                return
            }

            try? await workspaceManager.worktreeService.cleanupOrphanedWorktree(
                repositoryPath: project.repositoryPath,
                worktreePath: orphan.path
            )

            orphans.removeAll { $0.id == orphan.id }
            processingIds.remove(orphan.id)

            if orphans.isEmpty { dismiss() }
        }
    }
}

// MARK: - OrphanRow

/// A single row displaying an orphaned worktree with adopt/delete actions.
private struct OrphanRow: View {
    let orphan: OrphanedWorktreeInfo
    let isProcessing: Bool
    let onAdopt: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Path and branch info
            VStack(alignment: .leading, spacing: 2) {
                Text(truncatedPath(orphan.path))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.head)

                if let branch = orphan.branchName {
                    Text(branch)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button("Adopt") {
                        onAdopt()
                    }

                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    /// Returns the last 2–3 path components for a compact display.
    private func truncatedPath(_ path: String) -> String {
        let components = (path as NSString).pathComponents
            .filter { $0 != "/" }
        let suffix = components.suffix(3)
        return suffix.joined(separator: "/")
    }
}
