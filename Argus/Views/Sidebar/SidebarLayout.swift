import CoreGraphics

/// Pure layout rules for the workspace sidebar.
enum SidebarLayout {
    static let leftMinWidth: CGFloat = 80
    static let leftDefaultWidth: CGFloat = 200
    static let leftMaxFraction: CGFloat = 0.33

    static func leftMaxWidth(forWindowWidth windowWidth: CGFloat) -> CGFloat {
        max(leftMinWidth, windowWidth * leftMaxFraction)
    }

    static func clampLeftWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(max(width, leftMinWidth), leftMaxWidth(forWindowWidth: windowWidth))
    }
}
