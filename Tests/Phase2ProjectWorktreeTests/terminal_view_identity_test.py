from pathlib import Path

content_area = Path("Argus/Views/Content/ContentAreaView.swift").read_text()
terminal_view = Path("Argus/Ghostty/TerminalView.swift").read_text()
terminal_ns_view = Path("Argus/Ghostty/TerminalNSView.swift").read_text()

if "WorkspaceContentView(workspace: workspace)\n                .id(workspace.id)" not in content_area:
    raise SystemExit("FAIL: WorkspaceContentView must be keyed by workspace id so SwiftUI does not reuse terminal NSViews across workspaces")

if "reattachToken: terminalResizeGeneration" not in content_area or ".id(\"\\(terminalPanel.surface.id)-\\(terminalResizeGeneration)\")" not in content_area:
    raise SystemExit("FAIL: TerminalView must be keyed by surface id plus resize generation so SwiftUI remounts terminal NSViews after resize")

if "guard nsView.surface === surface else" not in terminal_view:
    raise SystemExit("FAIL: TerminalView must reject updates that pair an NSView with the wrong TerminalSurface")

if "func attachSurfaceToWindow(force: Bool = false)" not in terminal_ns_view or "surface?.refresh()" not in terminal_ns_view or "surface?.setOcclusion(false)" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must configure, refresh, and clear occlusion whenever attached to a window")

if "nsView.attachSurfaceToWindow(force: forceAttach)" not in terminal_view or "lastReattachToken" not in terminal_view:
    raise SystemExit("FAIL: TerminalView.updateNSView must run attach setup and force reattach when SwiftUI supplies a new resize remount token")

if "func requestDisplay()" not in terminal_ns_view or "ghostty_surface_draw(ghosttySurface)" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must draw immediately for render callbacks after SwiftUI tab/workspace churn")

if "func scheduleRenderRecovery()" not in terminal_ns_view or "GhosttyApp.shared.tick()" not in terminal_ns_view or "nsView.scheduleRenderRecovery()" not in terminal_view:
    raise SystemExit("FAIL: TerminalNSView must tick/refresh/draw after resize remount so content appears before the next keypress")

if "override func setFrameSize" not in terminal_ns_view or "scheduleRenderRecovery()" not in terminal_ns_view or "currentWindow.makeFirstResponder(self)" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must redraw and reclaim first responder after tab reattachment/layout size changes")

if "self?._hostedView?.requestDisplay()" not in Path("Argus/Ghostty/TerminalSurface.swift").read_text():
    raise SystemExit("FAIL: TerminalSurface render notifications must request an immediate hosted-view display")

if "private func startRedrawPump" not in terminal_ns_view or "startRedrawPump()" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must tick/refresh/draw after local input so pty echo is visible without tab reattachment")

if "guard force || !inLiveResize else { return }" not in terminal_ns_view or "viewDidEndLiveResize" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must defer Ghostty surface resizing until live window resize completes")

if "override func viewWillStartLiveResize()" not in terminal_ns_view or "guard !inLiveResize else { return }" not in terminal_ns_view:
    raise SystemExit("FAIL: TerminalNSView must suppress Ghostty drawing during live resize and resume after AppKit commits the resized Metal layer")

if "WindowResizeRemountObserver" not in content_area or "NSWindow.didEndLiveResizeNotification" not in content_area or "terminalResizeGeneration &+= 1" not in content_area:
    raise SystemExit("FAIL: ContentAreaView must remount terminal representables after window resize because tab reattachment is otherwise required")

if "syncTerminalSurfaces(to:" not in content_area or "workspace.panels.values" not in content_area or "terminalPanel.surface.setSize" not in content_area:
    raise SystemExit("FAIL: ContentAreaView must propagate content size changes to inactive terminal tabs before they are selected after resize")

if "scheduleActiveTerminalRemount()" not in content_area or "terminalActivationGeneration &+= 1" not in content_area:
    raise SystemExit("FAIL: ContentAreaView must remount the newly active terminal after tab selection because the first post-resize activation can draw too early")

print("PASS")
