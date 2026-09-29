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
        #expect(metrics.projectIconWidth == 20)
        #expect(metrics.projectGuideOffset == (metrics.isCompact ? 18 : 33))
        let directIconCenter = metrics.rowPadding + metrics.standaloneContentInset + 10
        #expect(directIconCenter == metrics.projectGuideOffset)
        let projectName = metrics.projectGuideOffset + metrics.projectIconWidth / 2 + metrics.rowSpacing
        #expect(projectName == directIconCenter + 10 + metrics.rowSpacing)
        // Even a forked Stack keeps its 20-point status target and a separate
        // compact process-count line after the fixed Project inset.
        let available =
            width - 16 - (metrics.isCompact ? 0 : 8) - 2 * metrics.rowPadding - metrics.projectContentInset
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
        let guideX = Int((8 + collectionInset + metrics.projectGuideOffset) * scale)
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

}

// Share the serialized native accessibility suite: AX enablement is process-local.
extension ProjectCollectionUITests {
    @Test(arguments: [80.0, 159.0, 160.0, 200.0])
    func stackStatusAndShortcutKeepSelectionAndProcessGeometry(width: Double) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let workspace = fixture.child
        let panel = try #require(workspace.addTerminalPanel())
        panel.surface.needsConfirmQuitOverride = true
        let model = unavailablePullRequestModel(fixture: fixture)
        let metrics = SidebarWidthMetrics(width: width)
        let selection = manager.selectedWorkspaceId
        let activeTab = workspace.activeTabId
        let focusedPane = workspace.activePanelId
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        let host = NSHostingView(rootView: statusRow(fixture: fixture, model: model, width: width, commandHeld: false))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width - 16, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let (rowFrame, iconFrame) = try verifyStatusGeometry(host: host, width: width, settings: manager.settings)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(workspace.activeTabId == activeTab && workspace.activePanelId == focusedPane)

        host.rootView = statusRow(fixture: fixture, model: model, width: width, commandHeld: true)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(!accessibilityDescendants(host).contains { $0.accessibilityLabel?() == "Show Pull Request status" })
        let shortcutRow = try #require(
            accessibilityDescendants(host).first { $0.accessibilityLabel?()?.hasPrefix("Workspace 2") == true })
        let shortcutFrame = try #require(shortcutRow.accessibilityFrame?())
        expectSameSidebarFrame(shortcutFrame, rowFrame)
        #expect(shortcutRow.accessibilityLabel?()?.contains("1 running process") == true)
        #expect(shortcutRow.accessibilityPerformPress?() == true)
        #expect(manager.workspaceRevealRevision == 1)
        #expect(manager.selectedWorkspaceId == workspace.id)
        #expect(workspace.activeTabId == activeTab && workspace.activePanelId == focusedPane)
        panel.surface.needsConfirmQuitOverride = false
        host.rootView = statusRow(fixture: fixture, model: model, width: width, commandHeld: false)
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        try verifyZeroProcessGeometry(host: host, rowFrame: rowFrame, iconFrame: iconFrame, metrics: metrics)
    }

    private func verifyStatusGeometry(host: NSView, width: Double, settings: AppSettings) throws -> (CGRect, CGRect) {
        let metrics = SidebarWidthMetrics(width: width)
        let collectionInset: CGFloat = metrics.isCompact ? 0 : 8
        let controls = accessibilityDescendants(host)
        let row = try #require(controls.first { $0.accessibilityLabel?()?.hasPrefix("Workspace 2") == true })
        let icon = try #require(controls.first { $0.accessibilityLabel?() == "Show Pull Request status" })
        #expect(!accessibilityDescendants(row).contains { $0 === icon }, "Pull Request control is not inside selection")
        let rowFrame = try #require(row.accessibilityFrame?())
        let iconFrame = try #require(icon.accessibilityFrame?())
        #expect(abs(rowFrame.width - (width - 16)) <= 1)
        #expect(iconFrame.width == 20 && iconFrame.height == 20)
        #expect(
            abs(
                iconFrame.minX - rowFrame.minX - collectionInset - metrics.rowPadding
                    - metrics.projectContentInset - metrics.stackGutterWidth(laneCount: 3) - metrics.rowSpacing) <= 1)
        #expect(row.accessibilityLabel?()?.contains("1 running process") == true)
        #expect(row.accessibilityLabel?()?.contains("Recorded parent: feature/parent") == true)
        let window = try #require(host.window)
        let rowBounds = host.convert(window.convertFromScreen(rowFrame), from: nil)
        #expect(host.bounds.contains(rowBounds))
        let iconBounds = host.convert(window.convertFromScreen(iconFrame), from: nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let renderer = ImageRenderer(
            content: CountBadge(count: 1).environmentObject(settings).environment(\.colorScheme, .dark))
        renderer.scale = scale
        let reference = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let badgeSize = CGSize(
            width: CGFloat(reference.pixelsWide) / scale, height: CGFloat(reference.pixelsHigh) / scale)
        let padding = settings.presentationMetrics.workspaceRowVerticalPadding
        let badge = CGRect(
            x: metrics.isCompact ? iconBounds.minX : rowBounds.maxX - metrics.rowPadding - badgeSize.width,
            y: metrics.isCompact ? rowBounds.maxY - padding - badgeSize.height : rowBounds.minY + padding,
            width: badgeSize.width, height: badgeSize.height)
        #expect(rowBounds.contains(badge), "The complete running-count badge fits inside the actual list row")
        #expect(rowBounds.contains(iconBounds), "The complete 20-point status control fits inside the actual list row")
        let referencePixels = sidebarForegroundPixelCount(
            reference, in: CGRect(origin: .zero, size: badgeSize), scale: scale)
        #expect(referencePixels > 0)
        #expect(
            sidebarForegroundPixelCount(bitmap, in: badge, scale: scale) >= referencePixels * 9 / 10,
            "The visible running-count glyph is not clipped or replaced by its accessible label")
        #expect(
            sidebarForegroundPixelCount(bitmap, in: iconBounds, scale: scale, threshold: 0.25) > 10,
            "The status symbol is visibly rendered within its contained control")
        return (rowFrame, iconFrame)
    }

    private func verifyZeroProcessGeometry(
        host: NSView, rowFrame: CGRect, iconFrame: CGRect, metrics: SidebarWidthMetrics
    ) throws {
        let idleRow = try #require(
            accessibilityDescendants(host).first { $0.accessibilityLabel?()?.hasPrefix("Workspace 2") == true })
        #expect(idleRow.accessibilityLabel?()?.contains("1 running process") == false)
        let idleFrame = try #require(idleRow.accessibilityFrame?())
        #expect(idleFrame.width == rowFrame.width)
        if metrics.isCompact {
            expectSameSidebarFrame(idleFrame, rowFrame)
        }
        let restoredIcon = try #require(
            accessibilityDescendants(host).first { $0.accessibilityLabel?() == "Show Pull Request status" })
        let restoredIconFrame = try #require(restoredIcon.accessibilityFrame?())
        #expect(restoredIconFrame.minX == iconFrame.minX)
        #expect(restoredIconFrame.size == iconFrame.size)
    }

    private func expectSameSidebarFrame(_ actual: CGRect, _ expected: CGRect) {
        // Native accessibility frames may round to adjacent backing pixels.
        #expect(abs(actual.minX - expected.minX) <= 1)
        #expect(abs(actual.minY - expected.minY) <= 1)
        #expect(abs(actual.width - expected.width) <= 1)
        #expect(abs(actual.height - expected.height) <= 1)
    }

    private func unavailablePullRequestModel(fixture: WorkspaceStackTestFixture) -> WorkspacePullRequestStatusModel {
        let workspace = fixture.child
        let model = WorkspacePullRequestStatusModel(automaticallySchedules: false)
        model.update(
            targets: [
                WorkspacePullRequestTarget(
                    workspaceID: workspace.id, projectID: fixture.project.id,
                    repositoryPath: fixture.project.repositoryPath, worktreePath: workspace.currentDirectory)
            ],
            selectedWorkspaceID: workspace.id, isEnabled: true, isActive: false)
        model.publish(WorkspacePullRequestState(error: .unauthenticated, hasLoaded: true), for: workspace.id)
        return model
    }

    private func statusRow(
        fixture: WorkspaceStackTestFixture, model: WorkspacePullRequestStatusModel, width: Double, commandHeld: Bool
    ) -> some View {
        let manager = fixture.manager
        let workspace = fixture.child
        let metrics = SidebarWidthMetrics(width: width)
        let collectionInset: CGFloat = metrics.isCompact ? 0 : 8
        return SidebarWorkspaceRow(
            workspace: workspace, globalIndex: 2, shortcutDigit: 2,
            isSelected: true, onSelect: { manager.selectWorkspace(workspace.id) },
            stackRelationship: WorkspaceStackRow(
                branch: "feature/child", parentBranch: "feature/parent", dependentBranches: [],
                workspaceId: workspace.id, lane: 2), showsStackGutter: true
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .environmentObject(manager)
        .environmentObject(manager.settings)
        .environmentObject(AgentStatusStore())
        .environmentObject(TurnCompletionAttentionStore())
        .environmentObject(model)
        .environment(WindowFocusState())
        .environment(\.sidebarWidthMetrics, metrics)
        .environment(\.sidebarCollectionContentInset, collectionInset)
        .environment(\.sidebarProjectContentInset, metrics.projectContentInset)
        .environment(\.sidebarStackLaneCount, 3)
        .environment(\.isCommandKeyHeld, commandHeld)
    }

}
