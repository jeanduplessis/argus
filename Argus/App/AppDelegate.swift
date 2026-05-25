import AppKit
import SwiftUI

/// NSApplicationDelegate handling window lifecycle and configuration.
///
/// The delegate is connected to the SwiftUI lifecycle via
/// `@NSApplicationDelegateAdaptor` in `ArgusApp`. It receives a reference
/// to `WorkspaceManager` on first window appear so it can update the
/// window title when the active workspace changes.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by ArgusApp.body's `.onAppear` once the view hierarchy is live.
    var workspaceManager: WorkspaceManager? {
        didSet { updateWindowTitle() }
    }

    // MARK: - NSApplicationDelegate

    /// Tracks windows we've already configured to avoid redundant work.
    private var configuredWindows: Set<ObjectIdentifier> = []
    private var windowTitleObserver: NSObjectProtocol?

    func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure any existing windows
        for window in NSApp.windows {
            configureWindow(window)
        }

        // Observe new windows becoming key — SwiftUI may create them after
        // applicationDidFinishLaunching, so we configure them on first focus.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow else { return }
            self.configureWindow(window)
        }

        windowTitleObserver = NotificationCenter.default.addObserver(
            forName: .workspaceContextDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateWindowTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceManager?.saveSession()
        if let windowTitleObserver {
            NotificationCenter.default.removeObserver(windowTitleObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    // MARK: - Window Configuration

    private func configureWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard !configuredWindows.contains(id) else { return }
        configuredWindows.insert(id)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = ChromeColors.contentBackgroundNSColor
        window.isRestorable = false

        // Window sizing
        window.minSize = NSSize(width: 600, height: 400)

        // Set initial title (visible in Mission Control / Exposé).
        window.title = "Argus"
    }

    /// Updates the window title to reflect the active workspace.
    ///
    /// Falls back to "Argus" when no workspace is selected.
    func updateWindowTitle(_ window: NSWindow? = nil) {
        let targetWindow = window ?? NSApp.mainWindow
        targetWindow?.title = workspaceManager?.activeWorkspaceTitle
            ?? WorkspaceTitleFormatter.fallbackTitle
    }
}
