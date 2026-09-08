import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct SidebarLayoutTests {
    @Test
    func leftSidebarMaximumWidthRespectsWindowBounds() {
        assertEqual(
            SidebarLayout.leftMaxWidth(forWindowWidth: 1200), 396, "left max is 33 percent of wide window"
        )
        assertEqual(
            SidebarLayout.leftMaxWidth(forWindowWidth: 180), 80, "left max never drops below min width")
    }

    @Test
    func leftSidebarWidthClampsToMinimumMaximumAndDefault() {
        assertEqual(
            SidebarLayout.clampLeftWidth(700, windowWidth: 900), 297,
            "left width clamps to live 33 percent cap")
        assertEqual(SidebarLayout.clampLeftWidth(20, windowWidth: 900), 80, "left width clamps to min")
        assertEqual(
            SidebarLayout.clampLeftWidth(200, windowWidth: 900), 200,
            "default 200 remains valid when window is wide enough")
    }

    @Test(arguments: [80.0, 159.0, 160.0, 200.0])
    func projectScopeStaysOutsideStackGutterWithoutConsumingStatusSlots(width: Double) {
        let metrics = SidebarWidthMetrics(width: width)
        let childLeading = metrics.rowPadding + metrics.projectContentInset
        #expect(childLeading - metrics.projectGuideOffset >= 6)
        #expect(metrics.projectIconWidth >= 12)
        // Even a forked Stack keeps its 20-point status target and a separate
        // compact process-count line after the fixed Project inset.
        let available =
            width - 2 * metrics.rowPadding - metrics.projectContentInset
            - metrics.stackGutterWidth(laneCount: 3) - metrics.rowSpacing
        #expect(available >= 20 + metrics.rowSpacing)
    }

    private func assertEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        #expect(abs(actual - expected) < 0.001, Comment(rawValue: message))
    }
}

extension SidebarLayoutTests {
    @Test(arguments: [80.0, 159.0, 160.0, 200.0], [false, true])
    func projectGuideEndsBeforeStandaloneEvenWithCollapsedStack(width: Double, stackCollapsed: Bool) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let standalone = Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: nil, branchName: "", workspaceType: .external,
                worktreePath: nil, title: "Standalone", customTitle: nil,
                currentDirectory: fixture.root.path, panelCount: 0))
        manager.workspaces.append(standalone)
        manager.ungroupedWorkspaceIds.append(standalone.id)
        fixture.collapsedStackIds = stackCollapsed ? [fixture.stackId] : []
        manager.selectedWorkspaceId = fixture.ordinary.id
        let metrics = SidebarWidthMetrics(width: width)
        let collectionInset: CGFloat = metrics.isCompact ? 0 : 8
        let items = try #require(manager.navigationSections.first?.blocks.first?.items)

        let project = ProjectSection(project: fixture.project, items: items)
        let projectImage = try await sidebarBitmap(project, manager: manager, width: width)
        let standaloneImage = try await sidebarBitmap(
            SidebarWorkspaceEntry(workspace: standalone), manager: manager, width: width)
        let combined = try await sidebarBitmap(
            VStack(spacing: 0) {
                project
                SidebarWorkspaceEntry(workspace: standalone)
            }, manager: manager, width: width)
        let scale = CGFloat(projectImage.pixelsWide) / width
        #expect(combined.pixelsWide == projectImage.pixelsWide)
        #expect(combined.pixelsWide == standaloneImage.pixelsWide)
        #expect(combined.pixelsHigh == projectImage.pixelsHigh + standaloneImage.pixelsHigh)
        let guideX = Int((collectionInset + metrics.projectGuideOffset) * scale)
        // The plain guide stays continuous across ordinary selection fills,
        // Stack headers, references, and either expanded or collapsed members.
        for y in Int(40 * scale)..<(projectImage.pixelsHigh - 2) {
            let guide = try #require(projectImage.colorAt(x: guideX, y: y)?.usingColorSpace(.deviceRGB))
            let beside = try #require(projectImage.colorAt(x: guideX - 4, y: y)?.usingColorSpace(.deviceRGB))
            #expect(guide.redComponent > beside.redComponent + 0.03)
        }
        // A following Standalone Workspace renders exactly as a direct row:
        // it inherits neither the Project inset nor the guide.
        for y in 0..<standaloneImage.pixelsHigh {
            for x in 0..<standaloneImage.pixelsWide {
                #expect(
                    combined.colorAt(x: x, y: projectImage.pixelsHigh + y)
                        == standaloneImage.colorAt(x: x, y: y))
            }
        }
    }

    private func sidebarBitmap(
        _ content: some View, manager: WorkspaceManager, width: Double
    ) async throws -> NSBitmapImageRep {
        let metrics = SidebarWidthMetrics(width: width)
        let collectionInset: CGFloat = metrics.isCompact ? 0 : 8
        let host = NSHostingView(
            rootView:
                content
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.black)
                .environmentObject(manager)
                .environmentObject(manager.settings)
                .environmentObject(AgentStatusStore())
                .environmentObject(TurnCompletionAttentionStore())
                .environmentObject(WorkspacePullRequestStatusModel())
                .environmentObject(SidebarNavigationDropFeedback())
                .environment(WindowFocusState())
                .environment(\.colorScheme, .dark)
                .environment(\.sidebarWidthMetrics, metrics)
                .environment(\.sidebarCollectionContentInset, collectionInset))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        window.setContentSize(NSSize(width: width, height: host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        return image
    }
}
