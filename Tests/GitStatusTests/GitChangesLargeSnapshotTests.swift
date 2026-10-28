import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Argus

/// Returns one fixed Git Status Snapshot for every request.
private final class FixedGitStatusService: GitStatusProviding, @unchecked Sendable {
    let result: GitStatusLoadState

    init(result: GitStatusLoadState) {
        self.result = result
    }

    func status(rootPath: String) async -> GitStatusLoadState { result }
    func initializeRepository(rootPath: String) async -> GitStatusLoadState { result }

    func performFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        path: String
    ) async -> GitStatusLoadState { result }

    func performBulkFileOperation(
        _ operation: GitStatusFileOperation,
        rootPath: String,
        paths: [String]
    ) async -> GitStatusLoadState { result }
}

@MainActor
@Suite(.serialized)
struct GitChangesLargeSnapshotTests {
    /// Building every row of a large Change Tree blocked the main thread for
    /// about a second when switching to a Workspace with many changes. Only
    /// rows in view, and rows scrolled into view, may be built.
    @Test(.timeLimit(.minutes(1)))
    func largeChangeTreeBuildsRowsOnlyWhenTheyAreInView() async throws {
        let files = (0..<GitStatusSummary.displayFileLimit).map { index in
            GitFileChange(
                path: "src/module\(index % 5)/file\(String(format: "%03d", index)).txt",
                status: .untracked,
                sectionKind: .untracked
            )
        }
        let filePaths = Set(files.map(\.path))
        let lastPath = try #require(files.last?.path)
        // A temporary Workspace Root keeps the Changes View watcher away from
        // the default Standalone Workspace directory, the home directory.
        let root = try TestTemporaryDirectory(prefix: "argus-large-snapshot")
        defer { root.remove() }
        let (host, viewModel) = try makeChangesView(files: files, workspaceRoot: root.url.path)
        let window = makeWindow(containing: host)
        defer {
            window.contentView = nil
            window.close()
        }

        // Laying out once instantiates the Changes View, which starts its own
        // refresh. Await the published snapshot instead of polling so this
        // test does not occupy the main actor while other suites need it.
        host.layoutSubtreeIfNeeded()
        for await state in viewModel.$state.values {
            if case .loaded = state { break }
        }

        // The accessibility attribute is process-wide and other suites toggle
        // it. Keep this block free of suspension points so no other main-actor
        // test can interleave while it is enabled.
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        host.layoutSubtreeIfNeeded()
        let builtPaths = builtFileRowPaths(in: host, filePaths: filePaths)
        #expect(!builtPaths.isEmpty, "rows in view are built")
        #expect(
            builtPaths.count < files.count / 4,
            "rows outside the viewport must not be built; built \(builtPaths.count) of \(files.count)")
        #expect(!builtPaths.contains(lastPath))

        try scrollToBottom(in: host)
        host.layoutSubtreeIfNeeded()
        #expect(
            builtFileRowPaths(in: host, filePaths: filePaths).contains(lastPath),
            "rows scrolled into view are built")
    }

    /// Hosts the Changes View for a selected Standalone Workspace whose Git
    /// Status Snapshot contains `files` as untracked changes.
    private func makeChangesView(
        files: [GitFileChange],
        workspaceRoot: String
    ) throws -> (NSView, GitStatusViewModel) {
        let defaults = try #require(UserDefaults(suiteName: "ArgusGitChangesLargeSnapshot-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        let manager = WorkspaceManager(settings: settings, environment: ["ARGUS_UNDER_TEST": "1"])
        let workspace = try #require(manager.addWorkspace(workingDirectory: workspaceRoot))
        let summary = GitStatusSummary(
            rootPath: workspace.currentDirectory, branchName: "main", upstreamName: nil,
            aheadCount: 0, behindCount: 0, untrackedFiles: files)
        let viewModel = GitStatusViewModel(service: FixedGitStatusService(result: .loaded(summary)))
        let host = NSHostingView(
            rootView: GitSidebarView()
                .frame(width: 300, height: 400)
                .environmentObject(manager)
                .environmentObject(settings)
                .environmentObject(viewModel)
                .environmentObject(RightSidebarSessionState())
                .environment(WindowFocusState())
        )
        return (host, viewModel)
    }

    private func makeWindow(containing host: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func scrollToBottom(in host: NSView) throws {
        let scrollView = try #require(firstScrollView(in: host))
        let documentHeight = try #require(scrollView.documentView).frame.height
        let bottomOffset = max(0, documentHeight - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func builtFileRowPaths(in host: NSView, filePaths: Set<String>) -> Set<String> {
        Set(
            accessibilityDescendants(host).compactMap { element in
                guard let label = element.accessibilityLabel?(), filePaths.contains(label) else { return nil }
                return label
            })
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func accessibilityDescendants(_ object: AnyObject) -> [AnyObject] {
        [object] + (object.accessibilityChildren?() ?? []).flatMap { accessibilityDescendants($0 as AnyObject) }
    }

    /// AppKit builds its native accessibility tree only for an accessibility
    /// client. Enable the process-local attribute for the test, then restore it.
    private func enableNativeAccessibility() throws -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let application = NSApplication.shared
        try #require(application.accessibilityIsAttributeSettable(attribute))
        let previous = application.accessibilityAttributeValue(attribute)
        application.accessibilitySetValue(true, forAttribute: attribute)
        return { application.accessibilitySetValue(previous, forAttribute: attribute) }
    }
}
