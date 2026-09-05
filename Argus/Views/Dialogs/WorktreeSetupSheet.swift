import SwiftUI

struct WorktreeSetupSheet: View {
    @ObservedObject var project: Project
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var errorMessage: String?

    init(project: Project) {
        self.project = project
        _command = State(initialValue: project.worktreeSetupCommand ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Worktree Setup — \(project.displayName)")
                .font(.headline)
            Text(
                "Run this command in every newly created worktree, including Pull Request worktrees. "
                    + "Leave blank to disable."
            )
            Text(
                "Enabling setup executes code with your user permissions, including code from fork Pull Requests. "
                    + "Only enable commands and repositories you trust."
            )
            .foregroundStyle(.secondary)
            Text("Command (/bin/sh -c)")
            TextEditor(text: $command)
                .font(.system(.body, design: .monospaced))
                .frame(height: 140)
                .border(ChromeColors.separator)
                .accessibilityLabel("Worktree setup command")
            Text(
                "Noninteractive, non-login shell in the new worktree directory. Input is EOF. "
                    + "Interactive prompts and detached background services are not supported. "
                    + "Runs stop after one hour. "
                    + "Logs are kept only in the runtime Worktree Setup tab."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try workspaceManager.setWorktreeSetupCommand(command, for: project.id)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}
