// ContentAreaView.swift
// Argus

import AppKit
import SwiftUI

struct ContentAreaView: View {
    @EnvironmentObject var workspaceManager: WorkspaceManager

    var body: some View {
        if let workspace = workspaceManager.selectedWorkspace {
            WorkspaceContentView(workspace: workspace)
                .id(workspace.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No panels open")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Observes a single workspace and renders its tab bar + panel content.
/// This MUST be a separate view with `@ObservedObject` so that changes
/// to `workspace.activePanelId` trigger a re-render.
struct WorkspaceContentView: View {
    @ObservedObject var workspace: Workspace
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @State private var terminalResizeGeneration = 0
    @State private var terminalActivationGeneration = 0
    @State private var contentSize: CGSize = .zero

    var body: some View {
        let terminalRenderGeneration = terminalResizeGeneration &+ terminalActivationGeneration

        VStack(spacing: 0) {
            TitlebarView()
                .allowsHitTesting(false)

            TabBarView(workspace: workspace)

            if let layout = workspace.activeTabLayout {
                GeometryReader { proxy in
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: layout,
                        terminalResizeGeneration: terminalRenderGeneration
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        syncTerminalSurfaces(to: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        syncTerminalSurfaces(to: newSize)
                    }
                }
            }
        }
        .background(
            WindowResizeRemountObserver {
                terminalResizeGeneration &+= 1
            }
            .frame(width: 0, height: 0)
        )
        .onChange(of: workspace.activePanelId) { _, _ in
            syncTerminalSurfaces(to: contentSize)
            scheduleActiveTerminalRemount()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scheduleActiveTerminalRemount() {
        DispatchQueue.main.async {
            terminalActivationGeneration &+= 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            terminalActivationGeneration &+= 1
        }
    }

    private func syncTerminalSurfaces(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        contentSize = size

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = UInt32(size.width * scale)
        let pixelHeight = UInt32(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        for panel in workspace.panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            terminalPanel.surface.setContentScale(scale, scale)
            terminalPanel.surface.setSize(width: pixelWidth, height: pixelHeight)
        }
    }
}

/// Recursively renders the pane layout for the active tab.
struct PanelSplitLayoutView: View {
    @ObservedObject var workspace: Workspace
    let node: PanelLayoutNode
    let terminalResizeGeneration: Int

    var body: some View {
        switch node {
        case .leaf(let panelId):
            if let panel = workspace.panels[panelId] {
                let active = panelId == workspace.activePanelId
                PanelContentView(
                    panel: panel,
                    isActive: active,
                    terminalResizeGeneration: terminalResizeGeneration
                )
                .contentShape(Rectangle())
                .onTapGesture { workspace.selectPanel(panelId) }
            }
        case .split(let direction, let first, let second):
            switch direction {
            case .vertical:
                HStack(spacing: 0) {
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: first,
                        terminalResizeGeneration: terminalResizeGeneration
                    )
                    ChromeColors.separator.frame(width: 1)
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: second,
                        terminalResizeGeneration: terminalResizeGeneration
                    )
                }
            case .horizontal:
                VStack(spacing: 0) {
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: first,
                        terminalResizeGeneration: terminalResizeGeneration
                    )
                    ChromeColors.separator.frame(height: 1)
                    PanelSplitLayoutView(
                        workspace: workspace,
                        node: second,
                        terminalResizeGeneration: terminalResizeGeneration
                    )
                }
            }
        }
    }
}

// MARK: - Panel Content View

struct PanelContentView: View {
    let panel: any Panel
    var isActive: Bool = true
    let terminalResizeGeneration: Int

    var body: some View {
        switch panel.panelType {
        case .terminal:
            if let terminalPanel = panel as? TerminalPanel {
                TerminalView(
                    surface: terminalPanel.surface,
                    isActive: isActive,
                    reattachToken: terminalResizeGeneration
                )
                .id("\(terminalPanel.surface.id)-\(terminalResizeGeneration)")
            }
        case .browser:
            Text("Browser panel — coming in Phase 5")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Observes main-window resize events and forces SwiftUI to remount terminal
/// representables after resizing. This deliberately mirrors the user-visible
/// workaround of switching away from a tab and back: the same TerminalNSView is
/// detached and reattached, which causes Ghostty's embedded Metal surface to
/// become drawable and interactive again after AppKit live resize.
private struct WindowResizeRemountObserver: NSViewRepresentable {
    let onResizeFinished: () -> Void

    func makeNSView(context: Context) -> WindowResizeRemountNSView {
        let view = WindowResizeRemountNSView()
        view.onResizeFinished = onResizeFinished
        return view
    }

    func updateNSView(_ nsView: WindowResizeRemountNSView, context: Context) {
        nsView.onResizeFinished = onResizeFinished
    }
}

private final class WindowResizeRemountNSView: NSView {
    var onResizeFinished: (() -> Void)?

    private weak var observedWindow: NSWindow?
    private var isLiveResizing = false
    private var pendingResizeWorkItem: DispatchWorkItem?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observe(window)
    }

    private func observe(_ window: NSWindow?) {
        guard observedWindow !== window else { return }
        removeWindowObservers()
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(windowWillStartLiveResize(_:)),
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidEndLiveResize(_:)),
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    private func removeWindowObservers() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.willStartLiveResizeNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didEndLiveResizeNotification,
                object: observedWindow
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResizeNotification,
                object: observedWindow
            )
        }
        observedWindow = nil
    }

    @objc private func windowWillStartLiveResize(_ notification: Notification) {
        isLiveResizing = true
        pendingResizeWorkItem?.cancel()
    }

    @objc private func windowDidEndLiveResize(_ notification: Notification) {
        isLiveResizing = false
        scheduleRemount(after: 0)
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard !isLiveResizing else { return }
        scheduleRemount(after: 0.15)
    }

    private func scheduleRemount(after delay: TimeInterval) {
        pendingResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.observedWindow != nil else { return }
            self.onResizeFinished?()
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
