import SwiftUI

struct StackComparisonNotice: View {
    let owner: GitStatusSnapshotOwner
    let summary: GitStatusSummary
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var pullRequestStatusModel: WorkspacePullRequestStatusModel
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            if let section = summary.sections.first(where: { $0.kind == .againstBase }),
                let advisory = workspaceManager.stackComparisonAdvisory(
                    owner: owner, comparison: section.comparisonContext,
                    statusModel: pullRequestStatusModel, at: clock.date
                )
            {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title(for: advisory))
                        .font(
                            .system(size: appSettings.presentationMetrics.textSize(forBaseSize: 11), weight: .semibold)
                        )
                        .foregroundStyle(.orange)
                    Text(
                        "Recorded parent: \(advisory.recordedParentBranch). "
                            + "PR target: \(advisory.pullRequestBaseBranch)."
                    )
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                    .foregroundStyle(.secondary)
                    Text(
                        section.state.isAvailable
                            ? "Comparison: \(section.title)" : "Comparison unavailable: \(section.title)"
                    )
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                    .foregroundStyle(.secondary)
                    .help(comparisonHelp(section.comparisonContext))
                    Button("Review Sync Steps…") {
                        NotificationCenter.default.post(
                            name: .showStackMaintenanceSheet,
                            object: StackMaintenanceSheetRequest(
                                workspaceID: owner.workspaceId, showsSyncSteps: true,
                                comparison: section.comparisonContext
                            )
                        )
                    }
                    .controlSize(.small)
                    .help("Review history and parent metadata without running Git commands")
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func title(for advisory: StackComparisonAdvisory) -> String {
        switch advisory.kind {
        case .parentMergedNeedsSync: "Parent merged · Stack needs sync"
        case .pullRequestTargetMismatch: "PR target differs from recorded parent"
        }
    }

    private func comparisonHelp(_ comparison: GitBaseComparisonContext?) -> String {
        guard let comparison, let reference = comparison.resolvedRef, let commit = comparison.baseCommitID else {
            return "The recorded parent is not available for comparison. No replacement base was selected."
        }
        return "Comparison snapshot: \(reference) at \(commit). HEAD: \(comparison.headCommitID ?? "unavailable")."
    }
}
