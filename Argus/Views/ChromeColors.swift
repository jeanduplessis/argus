// ChromeColors.swift
// Argus
//
// Shared window-chrome colors derived from the active Ghostty theme so the
// titlebar and tab strip visually belong to the terminal/content column.

import AppKit
import SwiftUI

struct ChromePalette {
    let background: NSColor
    let foreground: NSColor
    let isDark: Bool
    let revision: UInt

    init(background: NSColor, foreground: NSColor, revision: UInt) {
        self.background = background.usingColorSpace(.sRGB) ?? background
        self.foreground = foreground.usingColorSpace(.sRGB) ?? foreground
        self.isDark = Self.relativeLuminance(of: self.background) < 0.5
        self.revision = revision
    }

    static let fallback = ChromePalette(
        background: .windowBackgroundColor,
        foreground: .textColor,
        revision: 0
    )

    private static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let color = color.usingColorSpace(.sRGB) else { return 0 }
        return (0.2126 * color.redComponent)
            + (0.7152 * color.greenComponent)
            + (0.0722 * color.blueComponent)
    }
}

enum ChromeColors {
    static var contentBackground: Color {
        Color(nsColor: contentBackgroundNSColor)
    }

    static var foreground: Color {
        Color(nsColor: foregroundNSColor)
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
        palette.background
    }

    static var foregroundNSColor: NSColor {
        palette.foreground
    }

    static var colorScheme: ColorScheme {
        palette.isDark ? .dark : .light
    }

    static var backgroundCSS: String {
        cssColor(contentBackgroundNSColor)
    }

    static var foregroundCSS: String {
        cssColor(foregroundNSColor)
    }

    private static func adaptiveOverlay(darkAlpha: CGFloat, lightAlpha: CGFloat) -> Color {
        let color = palette.isDark
            ? NSColor.white.withAlphaComponent(darkAlpha)
            : NSColor.black.withAlphaComponent(lightAlpha)
        return Color(nsColor: color)
    }

    private static var palette: ChromePalette {
        GhosttyApp.shared.chromePalette
    }

    private static func cssColor(_ color: NSColor) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return "rgb(0 0 0)" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        return "rgb(\(red) \(green) \(blue))"
    }
}
