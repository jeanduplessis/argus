import SwiftUI

extension Notification.Name {
    static let showStackMaintenanceSheet = Notification.Name("ArgusShowStackMaintenanceSheet")
    static let showMergedWorkspaceCleanupSheet = Notification.Name("ArgusShowMergedWorkspaceCleanupSheet")
}

struct StackMaintenanceSheetRequest: Identifiable {
    let id = UUID()
    let workspaceID: UUID
    var showsSyncSteps = false
    var comparison: GitBaseComparisonContext?
}

struct MergedWorkspaceCleanupSheetRequest: Identifiable {
    let id = UUID()
    let projectID: UUID
    let workspaceIDs: [UUID]
}

struct StackMaintenanceSheets: ViewModifier {
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var parentRequest: StackMaintenanceSheetRequest?
    @State private var cleanupRequest: MergedWorkspaceCleanupSheetRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $parentRequest) { request in
                StackParentSheet(request: request)
            }
            .sheet(item: $cleanupRequest) { request in
                MergedWorkspaceCleanupSheet(request: request)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showStackMaintenanceSheet)) { notification in
                guard let request = notification.object as? StackMaintenanceSheetRequest,
                    workspaceManager.workspaces.contains(where: { $0.id == request.workspaceID })
                else { return }
                parentRequest = request
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMergedWorkspaceCleanupSheet)) { notification in
                guard let request = notification.object as? MergedWorkspaceCleanupSheetRequest,
                    workspaceManager.projects.contains(where: { $0.id == request.projectID })
                else { return }
                cleanupRequest = request
            }
    }
}

struct StackSyncInstructions {
    let branch: String
    let recordedParent: String?
    let pullRequestTarget: String?
    let dependents: [String]

    var text: String {
        let parent = recordedParent ?? "the recorded parent"
        var steps = [
            "Save Working Changes and stop agents in the affected Workspaces. "
                + "Preserve backup refs before rewriting history.",
            "Current Pull Request target for \(branch): \(pullRequestTarget ?? "unknown"). "
                + "Independently verify whether \(parent) merged and which branch received it. "
                + "The child's current Pull Request target does not establish the parent's merge destination. "
                + "Then update the verified destination locally using your normal Git workflow.",
            "Restack \(branch) and its dependents with the correct old parent commit boundary. "
                + "After a squash merge, changing the PR target or running a plain rebase onto main "
                + "can include already merged changes.",
            "Inspect the resulting diff. Only then update the local Recorded Base Branch "
                + "if it still names the old parent. A metadata edit does not rebase commits.",
            "Review pushing and PR target changes separately, then refresh Argus. "
                + "Third-party sync commands may fetch, rebase, force-push, and update PRs; Argus does not run them."
        ]
        if !dependents.isEmpty {
            steps.append(
                "Recorded direct dependents: \(dependents.joined(separator: ", ")). Review their descendants too.")
        }
        return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }
}
