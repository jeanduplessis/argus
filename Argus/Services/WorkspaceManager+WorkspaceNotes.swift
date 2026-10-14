import Foundation

extension WorkspaceManager {
    /// Stores user-authored Workspace Notes on their Workspace and schedules a
    /// debounced Session Snapshot checkpoint. The text is applied immediately,
    /// so a later checkpoint always writes it for the Workspace that produced it.
    @discardableResult
    func setWorkspaceNotes(_ notes: String, for workspaceId: UUID) -> Bool {
        guard WorkspaceNotes.isWithinLimit(notes),
            let workspace = workspaces.first(where: { $0.id == workspaceId })
        else { return false }
        workspace.notes = notes
        scheduleWorkspaceNotesCheckpoint()
        return true
    }

    var hasPendingWorkspaceNotesCheckpoint: Bool {
        workspaceNotesCheckpointTask != nil
    }

    /// Writes a pending Workspace Notes checkpoint now. Does nothing when no
    /// notes edit is waiting for its debounced checkpoint.
    func flushWorkspaceNotesCheckpoint() {
        guard hasPendingWorkspaceNotesCheckpoint else { return }
        completeWorkspaceNotesCheckpoint()
    }

    private func scheduleWorkspaceNotesCheckpoint() {
        workspaceNotesCheckpointTask?.cancel()
        let delay = workspaceNotesCheckpointDelay
        workspaceNotesCheckpointTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.completeWorkspaceNotesCheckpoint()
        }
    }

    private func completeWorkspaceNotesCheckpoint() {
        workspaceNotesCheckpointTask?.cancel()
        workspaceNotesCheckpointTask = nil
        saveSession()
    }
}
