import AppKit
import SwiftUI

@main
struct ArgusApp: App {
    @StateObject private var workspaceManager: WorkspaceManager
    @StateObject private var agentStatusStore = AgentStatusStore()
    @StateObject private var appSettings: AppSettings
    @StateObject private var turnCompletionAttentionStore: TurnCompletionAttentionStore
    @StateObject private var kiloIntegration: KiloIntegrationModel
    @StateObject private var reviewWorkMode: ReviewWorkModeModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let settings = AppSettings()
        let attentionStore = TurnCompletionAttentionStore()
        let manager = WorkspaceManager(settings: settings)
        _appSettings = StateObject(wrappedValue: settings)
        _workspaceManager = StateObject(wrappedValue: manager)
        _turnCompletionAttentionStore = StateObject(wrappedValue: attentionStore)
        _kiloIntegration = StateObject(wrappedValue: KiloIntegrationModel())
        let review = ReviewWorkModeModel(workspaceManager: manager)
        _reviewWorkMode = StateObject(wrappedValue: review)
        let runtime = TurnCompletionRuntime(
            workspaceManager: manager,
            attentionStore: attentionStore,
            isMainWindowKey: {
                NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isKeyWindow }
            },
            onAcceptedUnviewed: {
                if settings.agentCompletionSound {
                    TurnCompletionSoundPlayer.play()
                }
            }
        )
        manager.setTurnCompletionRuntime(runtime)
        appDelegate.configureTurnCompletion(
            workspaceManager: manager,
            runtime: runtime
        )
        appDelegate.configureReviewWorkMode(review)

        // Initialize GhosttyApp singleton — this triggers ghostty_init and
        // configures the terminal environment (TERM, PATH, GHOSTTY_RESOURCES_DIR).
        _ = GhosttyApp.shared
    }

    var body: some Scene {
        Window("Argus", id: "main") {
            MainWindowView()
                .environmentObject(workspaceManager)
                .environmentObject(agentStatusStore)
                .environmentObject(appSettings)
                .environmentObject(turnCompletionAttentionStore)
                .environmentObject(reviewWorkMode)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        Settings {
            SettingsView()
                .environmentObject(appSettings)
                .environmentObject(kiloIntegration)
        }
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
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Tab") {
                    guard WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode) else { return }
                    workspaceManager.addTab()
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(!WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode))

                Button("New Browser Tab") {
                    guard WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode) else { return }
                    workspaceManager.addBrowserTab()
                }
                .disabled(!WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode))

                Button("Split Vertically") {
                    guard WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode) else { return }
                    workspaceManager.splitActiveTerminal(direction: .vertical)
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(!WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode))

                Button("Split Horizontally") {
                    guard WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode) else { return }
                    workspaceManager.splitActiveTerminal(direction: .horizontal)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode))
            }

            CommandGroup(after: .textEditing) {
                Divider()

                Button("Find\u{2026}") {
                    guard WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode) else { return }
                    workspaceManager.requestFindInActiveBrowser()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!WorkModeCodeCommandEligibility.isEnabled(in: activeWorkMode))
            }

            // Close commands — placed after new-item group
            CommandGroup(after: .newItem) {
                Button("Close Tab") {
                    closeActiveTab()
                }
                .keyboardShortcut("w", modifiers: [.command])
            }

            // View menu — sidebar toggles and workspace selection
            CommandGroup(after: .toolbar) {
                Button("Code Work Mode") {
                    NotificationCenter.default.post(
                        name: .selectCodeWorkMode,
                        object: nil
                    )
                }
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Review Work Mode") {
                    NotificationCenter.default.post(
                        name: .selectReviewWorkMode,
                        object: nil
                    )
                }
                .keyboardShortcut("2", modifiers: [.command, .option])

                Divider()
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleSidebar, object: nil
                    )
                }
                .keyboardShortcut("b", modifiers: [.command])

                Button("Toggle Right Sidebar") {
                    NotificationCenter.default.post(
                        name: .toggleGitSidebar, object: nil
                    )
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("Select Previous Tab") {
                    selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command])

                Button("Select Next Tab") {
                    selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command])

                Button("Next Changed File") {
                    NotificationCenter.default.post(
                        name: .reviewNextChangedFile,
                        object: nil
                    )
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Button("Next Unviewed File") {
                    NotificationCenter.default.post(
                        name: .reviewNextUnviewedFile,
                        object: nil
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .option])

                Button("Review Summary") {
                    NotificationCenter.default.post(
                        name: .reviewShowSummary,
                        object: nil
                    )
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

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

    private var isReviewWorkMode: Bool {
        WorkModeStorage.read() == .review
    }

    private func closeActiveTab() {
        switch WorkModeTabCommandRouter.route(.close, in: activeWorkMode) {
        case .closeReviewTab:
            guard let activeTabID = reviewWorkMode.store.session.activeTabID else { return }
            reviewWorkMode.closeTab(activeTabID)
        case .closeCodeTab:
            workspaceManager.closeCurrentTab()
        default:
            return
        }
    }

    private func selectPreviousTab() {
        switch WorkModeTabCommandRouter.route(.selectPrevious, in: activeWorkMode) {
        case .selectReviewTab(let offset):
            reviewWorkMode.selectRelativeTab(offset)
        case .selectCodeTab:
            workspaceManager.selectPreviousTab()
        default:
            return
        }
    }

    private func selectNextTab() {
        switch WorkModeTabCommandRouter.route(.selectNext, in: activeWorkMode) {
        case .selectReviewTab(let offset):
            reviewWorkMode.selectRelativeTab(offset)
        case .selectCodeTab:
            workspaceManager.selectNextTab()
        default:
            return
        }
    }

    private var activeWorkMode: WorkMode { isReviewWorkMode ? .review : .code }
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
    static let selectCodeWorkMode = Notification.Name("ArgusSelectCodeWorkMode")
    static let selectReviewWorkMode = Notification.Name("ArgusSelectReviewWorkMode")
    static let reviewNextChangedFile = Notification.Name("ArgusReviewNextChangedFile")
    static let reviewNextUnviewedFile = Notification.Name("ArgusReviewNextUnviewedFile")
    static let reviewShowSummary = Notification.Name("ArgusReviewShowSummary")
}
