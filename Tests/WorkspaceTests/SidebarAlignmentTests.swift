import AppKit
import SwiftUI
import Testing

@testable import Argus

extension SidebarLayoutTests {
    @Test
    func repositoryAndWorkspaceSymbolsAreDistinctAndAvailable() {
        #expect(WorkspaceType.mainCheckout.icon == "apple.terminal.on.rectangle")
        #expect(WorkspaceType.external.icon == WorkspaceType.mainCheckout.icon)
        #expect(WorkspaceType.worktree.icon == WorkspaceType.mainCheckout.icon)
        for symbol in ["tray.full", WorkspaceType.mainCheckout.icon] {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, Comment(rawValue: symbol))
        }
    }

    @Test(arguments: [80.0, 159.0, 160.0, 200.0], [false, true])
    func projectAndStandaloneIconsAndNamesAlign(width: Double, hasColor: Bool) async throws {
        for collectionInset: CGFloat in width < 160 ? [0] : [0, 8] {
            try await verifyAlignment(width: width, hasColor: hasColor, collectionInset: collectionInset)
        }
    }

    private func verifyAlignment(width: Double, hasColor: Bool, collectionInset: CGFloat) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        fixture.project.displayName = "MMM"
        fixture.project.color = hasColor ? .purple : nil
        let standalone = externalWorkspace(projectId: nil, directory: "/tmp/sidebar")
        let associatedExternal = externalWorkspace(
            projectId: fixture.project.id, directory: "/tmp/project-associated")
        fixture.manager.workspaces.append(associatedExternal)
        fixture.manager.selectedWorkspaceId = nil
        let metrics = SidebarWidthMetrics(width: width)
        let project = try await sidebarBitmap(
            ProjectSection(project: fixture.project, items: []), manager: fixture.manager, width: width,
            isKeyWindow: true, collectionInset: collectionInset)
        let direct = try await sidebarBitmap(
            SidebarWorkspaceEntry(workspace: standalone), manager: fixture.manager, width: width, isKeyWindow: true,
            collectionInset: collectionInset)
        let associated = try await sidebarBitmap(
            SidebarWorkspaceEntry(workspace: associatedExternal)
                .environment(\.sidebarProjectContentInset, metrics.projectContentInset),
            manager: fixture.manager, width: width, isKeyWindow: true, collectionInset: collectionInset)
        let scale = CGFloat(project.pixelsWide) / width
        let projectNameX = try primaryTextLeadingEdge(project)
        let standaloneNameX = try primaryTextLeadingEdge(direct)
        let associatedNameX = try primaryTextLeadingEdge(associated)
        let expectedProjectNameX =
            8 + collectionInset + metrics.rowPadding + metrics.projectDisclosureWidth
            + metrics.headerSpacing + metrics.projectIconWidth + metrics.rowSpacing
        #expect(abs(projectNameX / scale - expectedProjectNameX) <= 2)
        #expect(abs(projectNameX - standaloneNameX) <= scale)
        #expect(
            abs(
                (associatedNameX - standaloneNameX) / scale
                    - (metrics.projectContentInset - metrics.standaloneContentInset)) <= 1)
        try verifyIconAndChevronPixels(project: project, direct: direct, width: width, collectionInset: collectionInset)
        try attachBitmap(project, named: "project-\(Int(width))-inset-\(Int(collectionInset))-color-\(hasColor).png")
        try attachBitmap(direct, named: "standalone-\(Int(width))-inset-\(Int(collectionInset)).png")
        fixture.project.color = hasColor ? nil : .purple
        let otherColor = try await sidebarBitmap(
            ProjectSection(project: fixture.project, items: []), manager: fixture.manager, width: width,
            isKeyWindow: true, collectionInset: collectionInset)
        #expect(project.pixelsWide == otherColor.pixelsWide)
        #expect(project.pixelsHigh == otherColor.pixelsHigh)
        #expect(try primaryTextLeadingEdge(otherColor) == projectNameX)
        let firstPNG = try #require(project.representation(using: .png, properties: [:]))
        let secondPNG = try #require(otherColor.representation(using: .png, properties: [:]))
        #expect(firstPNG != secondPNG, "Optional Project color remains visible")
    }

    private func externalWorkspace(projectId: UUID?, directory: String) -> Workspace {
        Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: projectId, branchName: "", workspaceType: .external,
                worktreePath: nil, title: "MMM", customTitle: nil,
                currentDirectory: directory, panelCount: 0))
    }

    private func attachBitmap(_ bitmap: NSBitmapImageRep, named name: String) throws {
        Attachment.record(try #require(bitmap.representation(using: .png, properties: [:])), named: name)
    }

    private func verifyIconAndChevronPixels(
        project: NSBitmapImageRep, direct: NSBitmapImageRep, width: Double, collectionInset: CGFloat
    ) throws {
        let metrics = SidebarWidthMetrics(width: width)
        let scale = CGFloat(project.pixelsWide) / width
        let center = 8 + collectionInset + metrics.projectGuideOffset
        let iconRange = (center - 10)..<(center + 10)
        let projectIcon = try neutralGlyphBounds(project, columns: iconRange, scale: scale)
        let workspaceIcon = try neutralGlyphBounds(direct, columns: iconRange, scale: scale)
        #expect(abs(projectIcon.midX - workspaceIcon.midX) <= 1, "Rendered SF Symbol centers align")
        #expect(abs(projectIcon.midX - center) <= 1)
        #expect(abs(workspaceIcon.midX - center) <= 1)
        #expect(projectIcon.width >= 10 && workspaceIcon.width >= 10, "Both complete symbols remain visible")

        let chevronCenter = 8 + collectionInset + metrics.rowPadding + metrics.projectDisclosureWidth / 2
        let chevron = try neutralGlyphBounds(project, columns: (chevronCenter - 6)..<(chevronCenter + 6), scale: scale)
        let renderer = ImageRenderer(
            content: Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(90))
                .frame(width: 20, height: 20)
                .background(Color.black)
                .environment(\.colorScheme, .dark))
        renderer.scale = scale
        let reference = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let referenceChevron = try neutralGlyphBounds(reference, columns: 0..<20, scale: scale)
        #expect(abs(chevron.width - referenceChevron.width) <= 1, "The chevron is not clipped by its reservation")
        #expect(abs(chevron.height - referenceChevron.height) <= 1)
        #expect(
            chevron.minX >= 8 + collectionInset && chevron.maxX < projectIcon.minX, "Chevron stays clear of the icon")
    }

    private func neutralGlyphBounds(
        _ bitmap: NSBitmapImageRep, columns: Range<CGFloat>, scale: CGFloat
    ) throws -> CGRect {
        var bounds = CGRect.null
        for x in max(0, Int(columns.lowerBound * scale))..<min(bitmap.pixelsWide, Int(columns.upperBound * scale)) {
            for y in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                if minimum > 0.2 && maximum - minimum < 0.03 {
                    bounds = bounds.union(
                        CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
                }
            }
        }
        #expect(!bounds.isNull, "The native renderer must produce visible glyph pixels")
        return bounds
    }

    /// Only primary name glyphs are bright neutral pixels; symbols and subtitles are secondary.
    private func primaryTextLeadingEdge(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.75 {
                    return CGFloat(x)
                }
            }
        }
        Issue.record("No primary name glyphs rendered")
        return -1
    }

    func sidebarBitmap(
        _ content: some View, manager: WorkspaceManager, width: Double, isKeyWindow: Bool = false,
        collectionInset: CGFloat? = nil
    ) async throws -> NSBitmapImageRep {
        let metrics = SidebarWidthMetrics(width: width)
        let collectionInset = collectionInset ?? (metrics.isCompact ? 0 : 8)
        let focus = WindowFocusState()
        let host = NSHostingView(
            rootView:
                content
                // Production derives metrics from the outer width, then pads the list by 8 on each side.
                .frame(width: width - 16)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.black)
                .environmentObject(manager)
                .environmentObject(manager.settings)
                .environmentObject(AgentStatusStore())
                .environmentObject(TurnCompletionAttentionStore())
                .environmentObject(WorkspacePullRequestStatusModel())
                .environmentObject(SidebarNavigationDropFeedback())
                .environment(focus)
                .environment(\.colorScheme, .dark)
                .environment(\.sidebarWidthMetrics, metrics)
                .environment(\.sidebarCollectionContentInset, collectionInset))
        let window = SidebarRenderingWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.simulatedIsKeyWindow = isKeyWindow
        focus.attach(to: window)
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

private final class SidebarRenderingWindow: NSWindow {
    var simulatedIsKeyWindow = false
    override var isKeyWindow: Bool { simulatedIsKeyWindow }
}
