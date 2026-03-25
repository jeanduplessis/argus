import Foundation
import AppKit

/// Type of panel content.
public enum PanelType: String, Codable, Sendable {
    case terminal
    case browser
}

/// Protocol for all panel types (terminal, browser).
///
/// Each panel owns an independent content surface (terminal or browser) and
/// appears as a tab within a workspace. The protocol is `@MainActor` because
/// panel state drives SwiftUI views. Conformers must be classes
/// (`AnyObject`) so workspaces can hold them by reference.
@MainActor
public protocol Panel: AnyObject, Identifiable, ObservableObject where ID == UUID {
    var id: UUID { get }
    var panelType: PanelType { get }
    var displayTitle: String { get }
    var displayIcon: String? { get }
    var isDirty: Bool { get }

    /// Tear down the panel's resources and release its surface.
    func close()
    /// Mark this panel as the focused (active) panel.
    func focus()
    /// Remove focus from this panel.
    func unfocus()
}

extension Panel {
    public var displayIcon: String? { nil }
    public var isDirty: Bool { false }
}
