import CoreGraphics
import Foundation

@main
struct SidebarLayoutTests {
    static func main() {
        assertEqual(SidebarLayout.leftMaxWidth(forWindowWidth: 1200), 396, "left max is 33 percent of wide window")
        assertEqual(SidebarLayout.leftMaxWidth(forWindowWidth: 180), 80, "left max never drops below min width")
        assertEqual(SidebarLayout.clampLeftWidth(700, windowWidth: 900), 297, "left width clamps to live 33 percent cap")
        assertEqual(SidebarLayout.clampLeftWidth(20, windowWidth: 900), 80, "left width clamps to min")
        assertEqual(SidebarLayout.clampLeftWidth(200, windowWidth: 900), 200, "default 200 remains valid when window is wide enough")
    }

    private static func assertEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        guard abs(actual - expected) < 0.001 else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
