import SwiftUI

struct WorkspaceStackMenuItems: View {
    let workspaceID: UUID
    let projectID: UUID

    var body: some View {
        Button("Create Dependent Workspace…") {
            NotificationCenter.default.post(
                name: .showNewWorkspaceSheet, object: nil,
                userInfo: ["projectId": projectID, "parentWorkspaceId": workspaceID]
            )
        }
        Button("Stack Parent…") {
            NotificationCenter.default.post(
                name: .showStackMaintenanceSheet,
                object: StackMaintenanceSheetRequest(workspaceID: workspaceID)
            )
        }
        Button("Review Sync Steps…") {
            NotificationCenter.default.post(
                name: .showStackMaintenanceSheet,
                object: StackMaintenanceSheetRequest(workspaceID: workspaceID, showsSyncSteps: true)
            )
        }
    }
}

struct WorkspaceStackGroupMenuItems: View {
    let group: WorkspaceStackGroup
    let projectID: UUID

    var body: some View {
        Menu("Create Dependent Workspace From") {
            ForEach(group.rows) { row in
                if let workspaceID = row.workspaceId {
                    Button(row.branch) {
                        NotificationCenter.default.post(
                            name: .showNewWorkspaceSheet, object: nil,
                            userInfo: ["projectId": projectID, "parentWorkspaceId": workspaceID]
                        )
                    }
                }
            }
        }
        Button("Review Merged Workspaces…") {
            NotificationCenter.default.post(
                name: .showMergedWorkspaceCleanupSheet,
                object: MergedWorkspaceCleanupSheetRequest(projectID: projectID, workspaceIDs: group.workspaceIds)
            )
        }
    }
}
