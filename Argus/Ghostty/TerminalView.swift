import Foundation
import SwiftUI

struct TerminalView: NSViewRepresentable {

    let surface: TerminalSurface
    var isActive: Bool = true
    var reattachToken: Int = 0

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalNSView {
        return surface.hostedView
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // TerminalNSView is bound to exactly one TerminalSurface. If SwiftUI
        // ever tries to reuse a representable NSView for another panel, do not
        // create the new Ghostty surface against the old panel's view; that
        // leaves the new surface with no hosted view to redraw and can blank the
        // terminal after workspace/tab churn.
        guard nsView.surface === surface else {
            NSLog("TerminalView: refusing to reuse TerminalNSView for a different surface")
            return
        }

        // Ensure the surface is created only once the representable view is
        // attached. Creating a Ghostty embedded surface without an NSView
        // produces a non-functional Metal renderer.
        if nsView.window != nil {
            let forceAttach = context.coordinator.lastReattachToken != reattachToken
            nsView.attachSurfaceToWindow(force: forceAttach)
            if forceAttach {
                nsView.scheduleRenderRecovery()
            }
            context.coordinator.lastReattachToken = reattachToken
        }

        // Only request first responder for the active terminal.
        // In the ZStack approach, all terminals get updateNSView called,
        // but only the active one should claim focus.
        if isActive {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                if window.firstResponder !== nsView {
                    window.makeFirstResponder(nsView)
                }
                nsView.scheduleRenderRecovery()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TerminalNSView,
        context: Context
    ) -> CGSize? {
        nil
    }

    final class Coordinator {
        var lastReattachToken: Int?
    }
}


