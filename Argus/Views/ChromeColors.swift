// ChromeColors.swift
// Argus
//
// Shared window-chrome colors derived from the active Ghostty theme so the
// titlebar and tab strip visually belong to the terminal/content column.

import AppKit
import SwiftUI

enum ChromeColors {
    static var contentBackground: Color {
        Color(nsColor: contentBackgroundNSColor)
    }

    static var activeTabFill: Color {
        adaptiveOverlay(darkAlpha: 0.10, lightAlpha: 0.07)
    }

    static var hoveredTabFill: Color {
        adaptiveOverlay(darkAlpha: 0.06, lightAlpha: 0.04)
    }

    static var separator: Color {
        adaptiveOverlay(darkAlpha: 0.12, lightAlpha: 0.10)
    }

    static var contentBackgroundNSColor: NSColor {
        GhosttyApp.shared.defaultBackgroundColor.usingColorSpace(.sRGB)
            ?? GhosttyApp.shared.defaultBackgroundColor
    }

    private static func adaptiveOverlay(darkAlpha: CGFloat, lightAlpha: CGFloat) -> Color {
        let color = isContentBackgroundDark
            ? NSColor.white.withAlphaComponent(darkAlpha)
            : NSColor.black.withAlphaComponent(lightAlpha)
        return Color(nsColor: color)
    }

    private static var isContentBackgroundDark: Bool {
        guard let color = contentBackgroundNSColor.usingColorSpace(.sRGB) else {
            return true
        }

        let luminance = (0.2126 * color.redComponent)
            + (0.7152 * color.greenComponent)
            + (0.0722 * color.blueComponent)
        return luminance < 0.5
    }
}
