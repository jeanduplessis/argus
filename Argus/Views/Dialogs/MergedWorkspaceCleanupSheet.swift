import SwiftUI

struct MergedWorkspaceCleanupSheet: View {
    let request: MergedWorkspaceCleanupSheetRequest
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var pullRequestStatusModel: WorkspacePullRequestStatusModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [MergedWorkspaceCloseCandidate] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var isClosing = false
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            let eligibleIDs = Set(currentCandidates(at: clock.date).map(\.id))
            VStack(alignment: .leading, spacing: 14) {
                Text("Close merged Workspaces")
                    .font(.headline)
                Text(
                    "Closes the selected Workspaces and their tabs. "
                        + "All Worktrees, Working Changes, and branches stay on disk."
                )
                .font(.callout)
                Text("Workspaces with running processes or unverifiable merged Pull Requests are excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if candidates.isEmpty {
                    Text("No eligible Workspaces. Refresh to check again.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(candidates) { candidate in
                                Toggle(isOn: selection(for: candidate.id)) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.title)
                                        Text(candidate.branchName)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        if !eligibleIDs.contains(candidate.id) {
                                            Text("Context or merge evidence changed. Refresh before closing.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(isClosing || isRefreshing || !eligibleIDs.contains(candidate.id))
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Divider()
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isClosing)
                    Button("Refresh") {
                        Task { await refresh() }
                    }
                    .disabled(isClosing || isRefreshing)
                    Spacer()
                    if isClosing || isRefreshing { ProgressView().controlSize(.small) }
                    Button(
                        "Close \(selectedIDs.count) \(selectedIDs.count == 1 ? "Workspace" : "Workspaces")"
                    ) {
                        Task { await close() }
                    }
                    .foregroundStyle(.red)
                    .disabled(
                        isClosing || isRefreshing || selectedIDs.isEmpty || !selectedIDs.isSubset(of: eligibleIDs))
                }
            }
            .padding(24)
            .frame(width: 520)
        }
        .interactiveDismissDisabled(isClosing)
        .task { reloadCandidates(selectInitially: true) }
    }

    private func selection(for workspaceID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(workspaceID) },
            set: { selected in
                if selected { selectedIDs.insert(workspaceID) } else { selectedIDs.remove(workspaceID) }
            }
        )
    }

    private func currentCandidates(at date: Date) -> [MergedWorkspaceCloseCandidate] {
        workspaceManager.mergedStackCandidates(
            in: request.workspaceIDs, statusModel: pullRequestStatusModel, at: date
        ).filter { $0.project.id == request.projectID && $0.matchesCurrentWorkspace(in: workspaceManager) }
    }

    private func reloadCandidates(selectInitially: Bool = false) {
        candidates = currentCandidates(at: .now)
        let eligibleIDs = Set(candidates.map(\.id))
        if selectInitially {
            selectedIDs = eligibleIDs
        } else {
            selectedIDs.formIntersection(eligibleIDs)
        }
        errorMessage = nil
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let refreshed = try await workspaceManager.refreshMergedStackCandidates(
                in: request.workspaceIDs, projectID: request.projectID, statusModel: pullRequestStatusModel)
            guard !Task.isCancelled else { return }
            candidates = refreshed
            selectedIDs.formIntersection(candidates.map(\.id))
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func close() async {
        guard !isClosing, !selectedIDs.isEmpty else { return }
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        guard selected.count == selectedIDs.count else { return }
        isClosing = true
        errorMessage = nil
        defer { isClosing = false }
        do {
            try await workspaceManager.closeMergedWorkspaces(selected) { candidate in
                guard candidate.project.id == request.projectID, request.workspaceIDs.contains(candidate.id),
                    candidate.matchesStackSnapshot(workspaceManager.workspaceStackSnapshots[candidate.project.id])
                else { return nil }
                return pullRequestStatusModel.evidence(for: candidate.target, at: .now)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
