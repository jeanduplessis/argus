// TerminalNSViewSupport.swift
// Argus
//
// Geometry, cursor, and text-input support for TerminalNSView.

import AppKit
import QuartzCore

extension TerminalNSView {
    /// Reconciles Ghostty and Metal with SwiftUI's resolved Pane size.
    /// SwiftUI can reattach a retained NSView without a final frame callback.
    func synchronizeSurfaceGeometry(to targetSize: CGSize? = nil) {
        // A detached retained view has no authoritative backing scale. Updating
        // it at 1x corrupts the drawable and Ghostty viewport on Retina windows.
        guard let window else { return }

        let pointSize = targetSize ?? bounds.size
        guard pointSize.width > 0, pointSize.height > 0 else { return }

        let scale = window.backingScaleFactor
        let width = UInt32(max((pointSize.width * scale).rounded(), 0))
        let height = UInt32(max((pointSize.height * scale).rounded(), 0))
        surface?.setSize(width: width, height: height)

        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.drawableSize = CGSize(width: Int(width), height: Int(height))
        }
    }

    func updateCursor(shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:
            currentCursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT:
            currentCursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            currentCursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
            currentCursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            currentCursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            currentCursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            currentCursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            currentCursor = .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            currentCursor = .operationNotAllowed
        default:
            currentCursor = .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }
}

extension TerminalNSView: @preconcurrency NSTextInputClient {
    func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let ghosttySurface = surface?.surface else { return }
        let string = terminalText(from: insertString)
        guard !string.isEmpty else { return }

        string.withCString { pointer in
            ghostty_surface_text(ghosttySurface, pointer, UInt(string.utf8.count))
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        guard let ghosttySurface = surface?.surface else { return }
        let text = terminalText(from: string)
        text.withCString { pointer in
            ghostty_surface_preedit(ghosttySurface, pointer, UInt(text.utf8.count))
        }
    }

    func unmarkText() {
        guard let ghosttySurface = surface?.surface else { return }
        ghostty_surface_preedit(ghosttySurface, nil, 0)
    }

    func hasMarkedText() -> Bool { false }

    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.font, .underlineStyle]
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let ghosttySurface = surface?.surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(ghosttySurface, &x, &y, &width, &height)

        let viewPoint = NSPoint(x: x, y: y)
        let windowPoint = convert(viewPoint, to: nil)
        guard let screenPoint = window?.convertPoint(toScreen: windowPoint) else {
            return NSRect(x: x, y: y, width: width, height: height)
        }
        return NSRect(
            x: screenPoint.x,
            y: screenPoint.y - height,
            width: width,
            height: height
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }
}

private func terminalText(from value: Any) -> String {
    if let string = value as? String {
        return string
    }
    if let attributedString = value as? NSAttributedString {
        return attributedString.string
    }
    return String(describing: value)
}
