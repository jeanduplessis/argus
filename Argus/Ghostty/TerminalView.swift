import SwiftUI

struct TerminalView: NSViewRepresentable {

    let surface: TerminalSurface
    var isActive: Bool = true

    func makeNSView(context: Context) -> TerminalNSView {
        return surface.hostedView
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // Ensure the surface is created
        if surface.surface == nil {
            surface.createSurface()
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
}


