import SwiftUI

struct TerminalView: NSViewRepresentable {

    let surface: TerminalSurface
    var isActive: Bool = true
    var isVisible: Bool = true
    let targetSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalNSView {
        return surface.hostedView
    }

    func updateNSView(_ nsView: TerminalNSView, context: Context) {
        // Ensure the surface is created
        if surface.surface == nil {
            surface.createSurface()
        }
        if context.coordinator.isVisible != isVisible, surface.surface != nil {
            surface.setOcclusion(!isVisible)
            context.coordinator.isVisible = isVisible
        }
        nsView.synchronizeSurfaceGeometry(to: targetSize)

        context.coordinator.activeSurfaceId = isActive ? surface.id : nil
        guard isActive else { return }

        // Reconcile once more after AppKit attaches and lays out the retained
        // view. Revalidate focus because tab selection may change meanwhile.
        let surfaceId = surface.id
        let targetSize = targetSize
        DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
            guard nsView?.surface?.id == surfaceId,
                let nsView,
                let window = nsView.window
            else { return }
            nsView.synchronizeSurfaceGeometry(to: targetSize)

            guard coordinator?.activeSurfaceId == surfaceId else { return }
            nsView.surface?.refresh()
            if window.firstResponder !== nsView {
                window.makeFirstResponder(nsView)
            }
        }
    }

    static func dismantleNSView(_ nsView: TerminalNSView, coordinator: Coordinator) {
        coordinator.activeSurfaceId = nil
        coordinator.isVisible = nil
        nsView.surface?.setOcclusion(true)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: TerminalNSView,
        context: Context
    ) -> CGSize? {
        nil
    }

    final class Coordinator {
        var activeSurfaceId: UUID?
        var isVisible: Bool?
    }
}
