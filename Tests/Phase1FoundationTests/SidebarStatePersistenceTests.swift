import Foundation
import CoreGraphics

@main
struct SidebarStatePersistenceTests {
    static func main() async {
        await MainActor.run {
            let suiteName = "com.argus.tests.sidebar-state.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                fputs("FAIL: could not create test defaults suite\n", stderr)
                exit(1)
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let sidebar = SidebarState(defaults: defaults)
            sidebar.isVisible = false
            sidebar.width = 333

            let restoredSidebar = SidebarState(defaults: defaults)
            assertEqual(restoredSidebar.isVisible, false, "left sidebar visibility restores")
            assertEqual(restoredSidebar.width, 333, "left sidebar width restores")

            let gitSidebar = GitSidebarState(defaults: defaults)
            gitSidebar.isVisible = true
            gitSidebar.width = 444

            let restoredGitSidebar = GitSidebarState(defaults: defaults)
            assertEqual(restoredGitSidebar.isVisible, true, "right sidebar visibility restores")
            assertEqual(restoredGitSidebar.width, 444, "right sidebar width restores")
        }
    }

    private static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        guard actual == expected else {
            fputs("FAIL: \(message): expected \(expected), got \(actual)\n", stderr)
            exit(1)
        }
    }
}
