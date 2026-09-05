import SwiftUI

struct WorktreeSetupPanelView: View {
    @ObservedObject var panel: WorktreeSetupPanel
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(panel.status)
                    .textSelection(.enabled)
                    .accessibilityLabel("Worktree Setup: \(panel.status)")
                Spacer()
                Button("Stop") { Task { await panel.stop() } }
                    .disabled(!panel.isRunning || panel.isStopping)
                Button("Run Setup Again") {
                    if let workspace = workspaceManager.workspace(containingPanel: panel.id) {
                        workspaceManager.runWorktreeSetupAgain(in: workspace)
                    }
                }
                .disabled(panel.isRunning || !canRunAgain)
            }
            .padding(8)
            .background(ChromeColors.shellBackground)
            .windowFocusChrome()
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Directory: \(panel.rootPath)")
                    Text(
                        panel.command.isEmpty
                            ? "Use Run Setup Again to run the current Project command." : "$ \(panel.command)")
                    if let workspace = workspaceManager.workspace(containingPanel: panel.id),
                        let project = workspaceManager.project(for: workspace.id)
                    {
                        WorktreeSetupCommandPreview(project: project, capturedCommand: panel.command)
                    }
                    if panel.truncated {
                        Text("Earlier output omitted. Showing at most the last 1 MiB.")
                            .foregroundStyle(.secondary)
                    }
                    Text(panel.output)
                }
                .font(.system(size: appSettings.documentTextSize, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
        .background(ChromeColors.contentBackground)
    }

    private var canRunAgain: Bool {
        guard let workspace = workspaceManager.workspace(containingPanel: panel.id) else { return false }
        return workspaceManager.canRunWorktreeSetup(in: workspace)
    }
}

private struct WorktreeSetupCommandPreview: View {
    @ObservedObject var project: Project
    let capturedCommand: String

    var body: some View {
        if let command = project.worktreeSetupCommand {
            if command != capturedCommand { Text("Next run command: \(command)") }
        } else {
            Text("Setup is disabled for this Project.").foregroundStyle(.secondary)
        }
    }
}
