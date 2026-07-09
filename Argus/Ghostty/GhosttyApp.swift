// GhosttyApp.swift
// Argus
//
// Singleton managing the ghostty_app_t lifecycle. Provides the bridge between
// Ghostty's C runtime and Argus's Swift layer. All terminal surfaces share
// this single app instance.

import AppKit
import Combine
import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a surface should be closed. Object is the surface UUID.
    static let argusCloseSurface = Notification.Name("argusCloseSurface")
    /// Posted when Ghostty requests a title change. userInfo: ["surfaceId": UUID, "title": String]
    static let argusSetSurfaceTitle = Notification.Name("argusSetSurfaceTitle")
    /// Posted when Ghostty reports a working directory change. userInfo: ["surfaceId": UUID, "pwd": String]
    static let argusSetSurfacePwd = Notification.Name("argusSetSurfacePwd")
    /// Posted when a surface needs redisplay. Object is the surface UUID.
    static let argusSurfaceNeedsDisplay = Notification.Name("argusSurfaceNeedsDisplay")
    /// Posted when the mouse shape should change. userInfo: ["surfaceId": UUID, "shape": Int]
    static let argusMouseShapeChanged = Notification.Name("argusMouseShapeChanged")
    /// Posted when a color change occurs. userInfo: ["surfaceId": UUID, "color": ghostty_action_color_change_s]
    static let argusColorChanged = Notification.Name("argusColorChanged")
    /// Posted when cell size changes. userInfo: ["surfaceId": UUID, "width": UInt32, "height": UInt32]
    static let argusCellSizeChanged = Notification.Name("argusCellSizeChanged")
}

// MARK: - GhosttyApp

final class GhosttyApp: ObservableObject {

    nonisolated(unsafe) static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultForegroundColor: NSColor = .textColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    @Published private(set) var chromePalette = ChromePalette.fallback
    private var appObservers: [NSObjectProtocol] = []

    private init() {
        configureGhosttyEnvironment()
        initializeGhostty()
    }

    deinit {
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    // MARK: - Environment Setup

    /// Configure environment variables Ghostty expects before initialization.
    private func configureGhosttyEnvironment() {
        // GHOSTTY_RESOURCES_DIR: Point to the framework's resources if needed.
        // Ghostty looks for this to find themes and shaders.
        if let resourcesPath = Bundle.main.resourcePath {
            setenv("GHOSTTY_RESOURCES_DIR", resourcesPath, 0)
        }

        // Terminal identification
        setenv("TERM", "xterm-256color", 0)
        setenv("TERM_PROGRAM", "Argus", 1)
        setenv("COLORTERM", "truecolor", 0)

        // Ensure common tool directories are in PATH
        ensurePathContains([
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ])
    }

    /// Adds directories to PATH if not already present.
    private func ensurePathContains(_ directories: [String]) {
        let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let pathComponents = Set(currentPath.split(separator: ":").map(String.init))

        var newComponents: [String] = []
        for dir in directories where !pathComponents.contains(dir) {
            if FileManager.default.fileExists(atPath: dir) {
                newComponents.append(dir)
            }
        }

        if !newComponents.isEmpty {
            let updatedPath = (newComponents + [currentPath]).joined(separator: ":")
            setenv("PATH", updatedPath, 1)
        }
    }

    // MARK: - Initialization

    private func initializeGhostty() {
        // 1. Initialize the Ghostty library
        let argc = CommandLine.argc
        let argv = CommandLine.unsafeArgv
        let result = ghostty_init(UInt(argc), argv)
        guard result == GHOSTTY_SUCCESS else {
            NSLog("GhosttyApp: ghostty_init failed with code \(result)")
            return
        }

        // 2. Create and load config
        guard let cfg = ghostty_config_new() else {
            NSLog("GhosttyApp: ghostty_config_new returned nil")
            return
        }
        self.config = cfg

        // Load config files from standard paths
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        // Log any config diagnostics
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0..<diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                NSLog("GhosttyConfig diagnostic: %@", String(cString: msg))
            }
        }

        // 3. Extract terminal colors for window and content chrome.
        extractChromePalette(from: cfg)

        // 4. Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = ghosttyWakeupCallback
        runtimeConfig.action_cb = ghosttyActionCallback
        runtimeConfig.read_clipboard_cb = ghosttyReadClipboardCallback
        runtimeConfig.confirm_read_clipboard_cb = ghosttyConfirmReadClipboardCallback
        runtimeConfig.write_clipboard_cb = ghosttyWriteClipboardCallback
        runtimeConfig.close_surface_cb = ghosttyCloseSurfaceCallback

        // 5. Create the app
        guard let ghosttyApp = ghostty_app_new(&runtimeConfig, cfg) else {
            NSLog("GhosttyApp: ghostty_app_new returned nil")
            return
        }
        self.app = ghosttyApp

        // 6. Track app activation/deactivation for focus state
        let activateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }

        let deactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }

        appObservers.append(contentsOf: [activateObserver, deactivateObserver])
    }

    /// Extract terminal colors from the finalized Ghostty config for shared chrome.
    private func extractChromePalette(from config: ghostty_config_t) {
        let background = configColor(named: "background", from: config)
            ?? NSColor.windowBackgroundColor
        let foreground = configColor(named: "foreground", from: config)
            ?? (background.isDark ? NSColor.white : NSColor.black)

        defaultBackgroundColor = background
        defaultForegroundColor = foreground

        var opacity: Double = 1.0
        if ghostty_config_get(config, &opacity, "background-opacity", 18) {
            defaultBackgroundOpacity = opacity
        } else {
            defaultBackgroundOpacity = 1.0
        }

        chromePalette = ChromePalette(
            background: background,
            foreground: foreground,
            revision: chromePalette.revision &+ 1
        )
    }

    private func configColor(named name: String, from config: ghostty_config_t) -> NSColor? {
        var color = ghostty_config_color_s(r: 0, g: 0, b: 0)
        guard ghostty_config_get(config, &color, name, UInt(name.utf8.count)) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: 1.0
        )
    }

    // MARK: - Public API

    /// Called by the wakeup callback to process pending Ghostty events.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Reload configuration from disk and apply it.
    @MainActor
    func reloadConfiguration(source: String = "user") {
        guard let app else { return }

        NSLog("GhosttyApp: Reloading configuration (source: %@)", source)

        guard let newConfig = ghostty_config_new() else { return }
        ghostty_config_load_default_files(newConfig)
        ghostty_config_load_recursive_files(newConfig)
        ghostty_config_finalize(newConfig)

        GhosttyConfig.invalidateCache()
        extractChromePalette(from: newConfig)
        ghostty_app_update_config(app, newConfig)

        // Replace our stored config
        if let oldConfig = self.config {
            ghostty_config_free(oldConfig)
        }
        self.config = newConfig

        for window in NSApp.windows {
            window.backgroundColor = defaultBackgroundColor
            window.contentView?.needsDisplay = true
        }
    }

    /// Create a new surface config with defaults.
    func newSurfaceConfig() -> ghostty_surface_config_s {
        ghostty_surface_config_new()
    }

    /// Update the color scheme on the app level (e.g., when system appearance changes).
    func setColorScheme(_ scheme: ghostty_color_scheme_e) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, scheme)
    }

    /// Whether any surface needs quit confirmation.
    var needsConfirmQuit: Bool {
        guard let app else { return false }
        return ghostty_app_needs_confirm_quit(app)
    }
}

// MARK: - Callback Context Helper

/// Extract a surface UUID from the userdata pointer.
/// Surfaces set their UUID bytes as a stable pointer via userdata.
func callbackSurfaceId(from userdata: UnsafeMutableRawPointer?) -> UUID? {
    guard let userdata else { return nil }
    let surfaceRef = Unmanaged<AnyObject>.fromOpaque(userdata).takeUnretainedValue()
    if let surface = surfaceRef as? TerminalSurface {
        return surface.id
    }
    return nil
}

// MARK: - C Callbacks (free functions required for C function pointers)

/// Wakeup callback — dispatches tick() to the main queue.
private func ghosttyWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async {
        GhosttyApp.shared.tick()
    }
}

/// Action callback — handles Ghostty actions (title changes, renders, etc.).
private func ghosttyActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    // Get the surface from the target if it's a surface-scoped action
    var surfaceId: UUID?
    if target.tag == GHOSTTY_TARGET_SURFACE {
        let surface = target.target.surface
        if let surface {
            let ud = ghostty_surface_userdata(surface)
            surfaceId = callbackSurfaceId(from: ud)
        }
    }

    switch action.tag {
    case GHOSTTY_ACTION_SET_TITLE:
        guard let surfaceId else { return false }
        let titleStruct = action.action.set_title
        let title: String
        if let ptr = titleStruct.title {
            title = String(cString: ptr)
        } else {
            title = ""
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusSetSurfaceTitle,
                object: nil,
                userInfo: ["surfaceId": surfaceId, "title": title]
            )
        }
        return true

    case GHOSTTY_ACTION_PWD:
        guard let surfaceId else { return false }
        let pwdStruct = action.action.pwd
        let pwd: String
        if let ptr = pwdStruct.pwd {
            pwd = String(cString: ptr)
        } else {
            pwd = ""
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusSetSurfacePwd,
                object: nil,
                userInfo: ["surfaceId": surfaceId, "pwd": pwd]
            )
        }
        return true

    case GHOSTTY_ACTION_RENDER:
        guard let surfaceId else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusSurfaceNeedsDisplay,
                object: surfaceId
            )
        }
        return true

    case GHOSTTY_ACTION_CELL_SIZE:
        guard let surfaceId else { return false }
        let cellSize = action.action.cell_size
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusCellSizeChanged,
                object: nil,
                userInfo: [
                    "surfaceId": surfaceId,
                    "width": cellSize.width,
                    "height": cellSize.height,
                ]
            )
        }
        return true

    case GHOSTTY_ACTION_MOUSE_SHAPE:
        guard let surfaceId else { return false }
        let shape = action.action.mouse_shape
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusMouseShapeChanged,
                object: nil,
                userInfo: ["surfaceId": surfaceId, "shape": shape.rawValue]
            )
        }
        return true

    case GHOSTTY_ACTION_COLOR_CHANGE:
        guard let surfaceId else { return false }
        let colorChange = action.action.color_change
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusColorChanged,
                object: nil,
                userInfo: [
                    "surfaceId": surfaceId,
                    "kind": colorChange.kind.rawValue,
                    "r": colorChange.r,
                    "g": colorChange.g,
                    "b": colorChange.b,
                ]
            )
        }
        return true

    case GHOSTTY_ACTION_RING_BELL:
        NSSound.beep()
        return true

    case GHOSTTY_ACTION_RELOAD_CONFIG:
        DispatchQueue.main.async {
            GhosttyApp.shared.reloadConfiguration(source: "ghostty")
        }
        return true

    case GHOSTTY_ACTION_CLOSE_TAB:
        guard let surfaceId else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .argusCloseSurface,
                object: surfaceId
            )
        }
        return true

    // Actions we don't handle in Argus — return false so Ghostty
    // knows the apprt didn't consume them.
    case GHOSTTY_ACTION_NEW_WINDOW,
         GHOSTTY_ACTION_NEW_TAB,
         GHOSTTY_ACTION_NEW_SPLIT,
         GHOSTTY_ACTION_GOTO_SPLIT,
         GHOSTTY_ACTION_RESIZE_SPLIT,
         GHOSTTY_ACTION_TOGGLE_FULLSCREEN,
         GHOSTTY_ACTION_INSPECTOR,
         GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
         GHOSTTY_ACTION_OPEN_CONFIG,
         GHOSTTY_ACTION_CONFIG_CHANGE,
         GHOSTTY_ACTION_CLOSE_ALL_WINDOWS,
         GHOSTTY_ACTION_CLOSE_WINDOW,
         GHOSTTY_ACTION_TOGGLE_MAXIMIZE,
         GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW,
         GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS,
         GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL,
         GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE,
         GHOSTTY_ACTION_TOGGLE_VISIBILITY,
         GHOSTTY_ACTION_MOVE_TAB,
         GHOSTTY_ACTION_GOTO_TAB,
         GHOSTTY_ACTION_GOTO_WINDOW,
         GHOSTTY_ACTION_EQUALIZE_SPLITS,
         GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM,
         GHOSTTY_ACTION_PRESENT_TERMINAL,
         GHOSTTY_ACTION_SIZE_LIMIT,
         GHOSTTY_ACTION_RESET_WINDOW_SIZE,
         GHOSTTY_ACTION_INITIAL_SIZE,
         GHOSTTY_ACTION_SCROLLBAR,
         GHOSTTY_ACTION_RENDER_INSPECTOR,
         GHOSTTY_ACTION_SHOW_GTK_INSPECTOR,
         GHOSTTY_ACTION_PROMPT_TITLE,
         GHOSTTY_ACTION_MOUSE_VISIBILITY,
         GHOSTTY_ACTION_MOUSE_OVER_LINK,
         GHOSTTY_ACTION_RENDERER_HEALTH,
         GHOSTTY_ACTION_QUIT_TIMER,
         GHOSTTY_ACTION_FLOAT_WINDOW,
         GHOSTTY_ACTION_SECURE_INPUT,
         GHOSTTY_ACTION_KEY_SEQUENCE,
         GHOSTTY_ACTION_KEY_TABLE,
         GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY,
         GHOSTTY_ACTION_QUIT,
         GHOSTTY_ACTION_UNDO,
         GHOSTTY_ACTION_REDO,
         GHOSTTY_ACTION_CHECK_FOR_UPDATES,
         GHOSTTY_ACTION_OPEN_URL,
         GHOSTTY_ACTION_SHOW_CHILD_EXITED,
         GHOSTTY_ACTION_PROGRESS_REPORT,
         GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD,
         GHOSTTY_ACTION_COMMAND_FINISHED,
         GHOSTTY_ACTION_START_SEARCH,
         GHOSTTY_ACTION_END_SEARCH,
         GHOSTTY_ACTION_SEARCH_TOTAL,
         GHOSTTY_ACTION_SEARCH_SELECTED,
         GHOSTTY_ACTION_READONLY,
         GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
        return false

    default:
        return false
    }
}

/// Read clipboard callback — reads from NSPasteboard.
private func ghosttyReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) {
    guard let userdata, let state else { return }
    // userdata is the TerminalSurface (set via config.userdata in createSurface)
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let ghosttySurface = terminalSurface.surface else { return }

    let pasteboard = NSPasteboard.general
    let contents = pasteboard.string(forType: .string) ?? ""

    contents.withCString { ptr in
        ghostty_surface_complete_clipboard_request(ghosttySurface, ptr, state, false)
    }
}

/// Confirm clipboard read callback — auto-confirms (no modal in Argus).
private func ghosttyConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ content: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    let terminalSurface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
    guard let ghosttySurface = terminalSurface.surface else { return }
    // Auto-confirm — personal tool, no need for a modal
    ghostty_surface_complete_clipboard_request(ghosttySurface, content, state, true)
}

/// Write clipboard callback — writes to NSPasteboard.
func writeTerminalClipboard(
    _ contents: [(mimeType: String, text: String)],
    to pasteboard: NSPasteboard
) {
    pasteboard.clearContents()

    for content in contents {
        let mimeType = content.mimeType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let pasteboardType: NSPasteboard.PasteboardType
        switch mimeType {
        case "text/plain":
            pasteboardType = .string
        case "text/html":
            pasteboardType = .html
        default:
            continue
        }

        pasteboard.setString(content.text, forType: pasteboardType)
    }
}

private func ghosttyWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    guard count > 0, let contents else { return }

    var clipboardContents: [(mimeType: String, text: String)] = []
    clipboardContents.reserveCapacity(count)
    for i in 0..<count {
        let item = contents[i]
        guard let mime = item.mime, let data = item.data else { continue }
        clipboardContents.append((String(cString: mime), String(cString: data)))
    }

    writeTerminalClipboard(clipboardContents, to: .general)
}

/// Close surface callback — posts notification for WorkspaceManager.
private func ghosttyCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    guard let surfaceId = callbackSurfaceId(from: userdata) else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .argusCloseSurface,
            object: surfaceId
        )
    }
}
