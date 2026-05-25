import SwiftUI
import AppKit

@main
struct ArgusApp: App {
    @StateObject private var workspaceManager = WorkspaceManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Initialize GhosttyApp singleton — this triggers ghostty_init and
        // configures the terminal environment (TERM, PATH, GHOSTTY_RESOURCES_DIR).
        _ = GhosttyApp.shared
    }

    var body: some Scene {
        Window("Argus", id: "main") {
            MainWindowView()
                .environmentObject(workspaceManager)
                .onAppear {
                    appDelegate.workspaceManager = workspaceManager
                    appDelegate.updateWindowTitle()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // File menu — replace default "New" with workspace/tab commands
            CommandGroup(replacing: .newItem) {
                Button("New Project\u{2026}") {
                    NotificationCenter.default.post(
                        name: .showNewProjectSheet, object: nil
                    )
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("New Workspace") {
                    workspaceManager.addWorkspace()
                }
                .keyboardShortcut("t", modifiers: [.command])

                Button("New Tab") {
                    workspaceManager.addTab()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Split Vertically") {
                    workspaceManager.splitActiveTerminal(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command])

                Button("Split Horizontally") {
                    workspaceManager.splitActiveTerminal(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            // Close commands — placed after new-item group
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    workspaceManager.closeCurrentTab()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // View menu — sidebar toggles and workspace selection
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleSidebar, object: nil
                    )
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Toggle Git Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleGitSidebar, object: nil
                    )
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                // Workspace selection: Cmd+1 through Cmd+9
                ForEach(1...9, id: \.self) { number in
                    Button("Workspace \(number)") {
                        workspaceManager.handleWorkspaceShortcut(number: number)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")),
                        modifiers: .command
                    )
                }
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Toggle the workspace sidebar visibility.
    static let toggleSidebar = Notification.Name("ArgusToggleSidebar")
    /// Toggle the git status sidebar visibility.
    static let toggleGitSidebar = Notification.Name("ArgusToggleGitSidebar")
    /// Active workspace context changed; synchronize titlebar/window metadata.
    static let workspaceContextDidChange = Notification.Name("ArgusWorkspaceContextDidChange")
    /// Terminal NSView focus changed; synchronize the active split pane.
    static let terminalSurfaceDidBecomeFirstResponder = Notification.Name("ArgusTerminalSurfaceDidBecomeFirstResponder")
}
