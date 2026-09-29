import AppKit
import SwiftUI
import Testing

@testable import Argus

@Suite(.serialized)
@MainActor
struct ProjectCollectionUITests {
    @Test(arguments: [80.0, 159.0, 160.0, 200.0])
    func nativeHeaderDisclosureKeepsSelectionAndFitsAllocatedWidth(width: Double) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let collection = try #require(manager.createCollection(name: "Client aPI with a long Collection name"))
        manager.moveWorkspace(fixture.child.id, toCollection: collection.id)
        let selection = manager.selectedWorkspaceId
        let header = SidebarCollectionHeader(collection: collection)
            .modifier(SidebarNavigationDropTarget(target: .collection(collection.id)))
            .environmentObject(SidebarNavigationDropFeedback())
            .environmentObject(manager)
            .environmentObject(manager.settings)
            .environment(WindowFocusState())
            .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: width))
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        let host = NSHostingView(rootView: header)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width - 16, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let button = try #require(
            accessibilityDescendants(host).first {
                $0.accessibilityIdentifier?() == "collection-\(collection.id)"
            })
        #expect(button.accessibilityRole?() == .button)
        let frame = try #require(button.accessibilityFrame?())
        #expect(abs(frame.width - (width - 16)) <= 1)
        #expect(window.convertToScreen(host.convert(host.bounds, to: nil)).contains(frame))
        #expect((button.accessibilityFrame?().height ?? 0) >= 20)
        #expect(button.accessibilityPerformPress?() == true)
        #expect(manager.collections.first?.isExpanded == false)
        #expect(manager.selectedWorkspaceId == selection)
        #expect(manager.workspaceRevealRevision == 0)
    }

    @Test(arguments: [80.0, 159.0, 160.0, 200.0], [WorkspaceType.mainCheckout, .worktree, .external])
    func hierarchyInsetsKeepWorkspaceSelectionFullWidth(width: Double, type: WorkspaceType) async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        let isStackMember = type == .worktree
        let workspace = standaloneOrProjectWorkspace(type: type, fixture: fixture)
        let row = SidebarWorkspaceRow(
            workspace: workspace, globalIndex: 2, shortcutDigit: 2,
            isSelected: true, onSelect: { manager.selectWorkspace(workspace.id) },
            stackRelationship: isStackMember
                ? WorkspaceStackRow(
                    branch: "feature/child", parentBranch: "feature/parent", dependentBranches: [],
                    workspaceId: fixture.child.id, lane: 2) : nil,
            showsStackGutter: isStackMember
        )
        .environmentObject(manager)
        .environmentObject(manager.settings)
        .environmentObject(AgentStatusStore())
        .environmentObject(TurnCompletionAttentionStore())
        .environmentObject(WorkspacePullRequestStatusModel())
        .environment(WindowFocusState())
        .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: width))
        .environment(\.sidebarCollectionContentInset, width < 160 ? 0 : 8)
        .environment(
            \.sidebarProjectContentInset, type == .external ? 0 : SidebarWidthMetrics(width: width).projectContentInset
        )
        .environment(\.sidebarStackLaneCount, 3)
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        let host = NSHostingView(rootView: row)
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
        let button = try #require(
            accessibilityDescendants(host).first {
                $0.accessibilityRole?() == .button && $0.accessibilityLabel?()?.hasPrefix("Workspace 2") == true
            })
        let frame = try #require(button.accessibilityFrame?())
        #expect(abs(frame.width - (width - 16)) <= 1)
        #expect(window.convertToScreen(host.convert(host.bounds, to: nil)).contains(frame))
        #expect(button.accessibilityPerformPress?() == true)
        #expect(manager.workspaceRevealRevision == 1)
        #expect(manager.selectedWorkspaceId == workspace.id)
    }

    private func standaloneOrProjectWorkspace(type: WorkspaceType, fixture: WorkspaceStackTestFixture) -> Workspace {
        guard type == .external else { return type == .worktree ? fixture.child : fixture.parent }
        let workspace = Workspace(
            snapshot: WorkspaceSnapshot(
                id: UUID(), projectId: nil, branchName: "", workspaceType: .external,
                worktreePath: nil, title: "Standalone", customTitle: nil,
                currentDirectory: fixture.root.path, panelCount: 0))
        fixture.manager.workspaces.append(workspace)
        fixture.manager.ungroupedWorkspaceIds.append(workspace.id)
        return workspace
    }

    @Test
    func collapsedSummaryShowsProjectWorkspaceAndUnacknowledgedAttention() async throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        fixture.project.displayName = "Client API"
        fixture.child.setCustomTitle("Implement feature")
        let attention = TurnCompletionAttentionStore()
        let target = TurnCompletionAttentionTarget(workspaceId: fixture.child.id, tabId: UUID())
        _ = attention.record(agentKey: "test", eventId: "complete", target: target, isViewed: false)
        let summary = SidebarCollapsedWorkspaceSummary(
            workspaceIds: fixture.manualOrder, showsProjectContext: true
        )
        .environmentObject(manager)
        .environmentObject(manager.settings)
        .environmentObject(attention)
        .environment(WindowFocusState())
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        let host = NSHostingView(rootView: summary)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let labels = accessibilityDescendants(host).flatMap { element in
            let value: String? = element.accessibilityValue?()
            return [element.accessibilityLabel?(), value].compactMap { $0 }
        }.joined(separator: " ")
        #expect(labels.contains("Client API / Implement feature"))
        #expect(labels.contains("Turn Completion Attention"))
        #expect(attention.attentionTargets == [target])
        #expect(manager.selectedWorkspaceId == fixture.child.id)
    }

}

extension ProjectCollectionUITests {
    @Test
    func creationAndExplicitMoveActionsAreWiredToNativeSheetsAndManager() throws {
        let app = try SourceContract("Argus/App/ArgusApp.swift")
        let header = try SourceContract("Argus/Views/Sidebar/SidebarView+Header.swift")
        for source in [app, header] {
            source.contains("Button(\"New Collection…\")", "both menus expose Collection creation")
            source.contains("name: .showCollectionSheet", "both menus use the native sheet route")
        }
        try SourceContract("Argus/Views/MainWindowView.swift").contains(
            ".sheet(item: $collectionSheetRequest)", "Collection naming uses a sheet, not a content window")
        let collections = try SourceContract("Argus/Views/Sidebar/SidebarView+Collections.swift")
        collections.containsAll(
            [
                "Menu(\"Move to Collection\")", "Button(\"No Collection\")", "Button(\"Remove Collection\")",
                "Button(\"Rename Collection…\")",
                ".cursor(.pointingHand)", ".onHover", ".focused($isFocused)", ".contentShape(Rectangle())"
            ], "explicit actions and native interaction are available without dragging")
        collections.excludes(".textCase(", "Collection names retain entered casing")
        collections.excludes("collection.projectIds.count", "Collection headers do not show counts")
    }

    @Test
    func collectionHeaderDropFeedbackIsFullWidthTransientAndIndependentOfDisclosure() throws {
        let collections = try SourceContract("Argus/Views/Sidebar/SidebarView+Collections.swift")
        let sectionHeader = try collections.section(
            after: "VStack(spacing: 0) {", before: "if collection.isExpanded {")
        #expect(sectionHeader.contains("SidebarCollectionHeader(collection: collection)"))
        #expect(sectionHeader.contains(".modifier(SidebarNavigationDropTarget(target: .collection(collection.id)))"))
        let dragging = try SourceContract("Argus/Views/Sidebar/SidebarNavigationDragging.swift")
        let feedback = try dragging.section(after: ".overlay {", before: ".onDrop(")
        for fragment in [
            "placement == .append", ".fill(Color.accentColor.opacity(0.12))",
            ".stroke(Color.accentColor, lineWidth: 1)",
            ".allowsHitTesting(false)", ".accessibilityHidden(true)"
        ] {
            #expect(feedback.contains(fragment))
        }
        dragging.contains("feedback.exit(feedbackId)", "exit releases only its own feedback region")
        let drop = try dragging.section(after: "func performDrop(info: DropInfo) -> Bool {", before: "guard")
        #expect(drop.contains("feedback.end()"))
        dragging.contains("info.itemProviders(for: [.item])", "mixed payload rejection includes non-navigation items")
    }

    @Test
    func feedbackRenderingUsesRegionIdentityAndClearsLinesAndOutlines() throws {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let feedback = SidebarNavigationDropFeedback()
        let collection = try #require(fixture.manager.createCollection(name: "Work"))
        let header = UUID()
        let repositoryHeading = UUID()

        func accentPixels() throws -> (header: Int, repositoryHeading: Int) {
            // Both regions append to the same Collection, but only one may light up.
            let content = VStack(spacing: 8) {
                Color.black.frame(width: 120, height: 32)
                    .modifier(SidebarNavigationDropTarget(target: .collection(collection.id), feedbackId: header))
                Color.black.frame(width: 120, height: 32)
                    .modifier(
                        SidebarNavigationDropTarget(target: .collection(collection.id), feedbackId: repositoryHeading))
            }
            .accentColor(.blue)
            .environmentObject(fixture.manager)
            .environmentObject(feedback)
            let image = try #require(ImageRenderer(content: content).cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var counts = [0, 0]
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.blueComponent > 0.5 && color.redComponent < 0.3 {
                        counts[y < bitmap.pixelsHigh / 2 ? 0 : 1] += 1
                    }
                }
            }
            return (counts[0], counts[1])
        }

        #expect(try accentPixels() == (0, 0))
        feedback.enter(header, placement: .append)
        let outline = try accentPixels()
        #expect(outline.header > 100)
        #expect(outline.repositoryHeading == 0)
        feedback.enter(repositoryHeading, placement: .before)
        feedback.exit(header)
        feedback.update(header, placement: .append)
        let line = try accentPixels()
        #expect(line.header == 0)
        #expect(line.repositoryHeading >= 120)
        feedback.end()
        feedback.update(repositoryHeading, placement: .before)
        #expect(try accentPixels() == (0, 0))
        feedback.enter(header, placement: .append)
        feedback.exit(header)
        feedback.update(header, placement: .append)
        #expect(try accentPixels() == (0, 0))
    }

    @Test
    func collectionNewProjectUsesAFreshUUIDScopedSheetRequest() throws {
        let collections = try SourceContract("Argus/Views/Sidebar/SidebarView+Collections.swift")
        let firstAction = try collections.section(after: ".contextMenu {", before: "Button(\"Rename Collection…\")")
        #expect(firstAction.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Button(\"New Workspace…\")"))
        #expect(firstAction.contains("name: .showNewProjectSheet, object: collection.id"))
        let window = try SourceContract("Argus/Views/MainWindowView.swift")
        let request = try window.section(
            after: "private struct NewProjectSheetRequest: Identifiable {",
            before: "struct WorkspaceCreationRequest")
        #expect(request.contains("let id = UUID()"))
        #expect(request.contains("let collectionId: UUID?"))
        window.containsAll(
            [
                "@State private var newProjectSheetRequest: NewProjectSheetRequest?",
                ".sheet(item: $newProjectSheetRequest) { request in",
                "NewProjectSheet(collectionId: request.collectionId)"
            ], "sheet lifetime owns its destination and cancellation clears the request")
        let receive = try window.section(
            after: ".onReceive(NotificationCenter.default.publisher(for: .showNewProjectSheet)) { notification in",
            before: ".onReceive(NotificationCenter.default.publisher(for: .showNewWorkspaceSheet))")
        #expect(
            receive.contains(
                "newProjectSheetRequest = NewProjectSheetRequest(collectionId: notification.object as? UUID)"))
        for path in ["Argus/App/ArgusApp.swift", "Argus/Views/Sidebar/SidebarView+Header.swift"] {
            try SourceContract(path).contains(
                "name: .showNewProjectSheet, object: nil", "top-level actions explicitly request no Collection")
        }
        let sheet = try SourceContract("Argus/Views/Dialogs/NewProjectSheet.swift")
        sheet.containsAll(
            [
                "let collectionId: UUID?", "collectionId: collectionId", "await workspaceManager.createProject(",
                "Button(\"Cancel\") { dismiss() }", ".keyboardShortcut(.cancelAction)",
                ".keyboardShortcut(.defaultAction)", "Collection no longer exists. Cancel and open New Project again."
            ], "existing native sheet passes the destination to the creation boundary and reports stale destinations")
        sheet.excludes("workspaceManager.moveProject", "membership is not a create-then-move view operation")
    }

    func accessibilityDescendants(_ object: AnyObject) -> [AnyObject] {
        [object] + (object.accessibilityChildren?() ?? []).flatMap { accessibilityDescendants($0 as AnyObject) }
    }
}

extension ProjectCollectionUITests {
    /// AppKit lazily enables its native AX tree when an accessibility client requests it.
    /// Unit tests are not an AX client: enable the advertised process-local attribute,
    /// then restore it. No system preference or Accessibility permission is changed.
    func enableNativeAccessibility() throws -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let application = NSApplication.shared
        try #require(application.accessibilityIsAttributeSettable(attribute))
        let previous = application.accessibilityAttributeValue(attribute)
        application.accessibilitySetValue(true, forAttribute: attribute)
        return { application.accessibilitySetValue(previous, forAttribute: attribute) }
    }
}

extension ProjectCollectionUITests {
    @Test(arguments: [80.0, 159.0, 160.0, 200.0], [false, true])
    func projectDisclosureWithRepositorySymbolAndColorFitsAndRemainsSectionLocal(width: Double, hasColor: Bool)
        async throws
    {
        let fixture = try WorkspaceStackTestFixture()
        defer { fixture.cleanup() }
        let manager = fixture.manager
        fixture.project.color = hasColor ? .purple : nil
        let collection = try #require(manager.createCollection(name: "Other section"))
        manager.moveWorkspace(fixture.ordinary.id, toCollection: collection.id)
        manager.workspaceStackErrors[fixture.project.id] = "Local test diagnostic"
        let otherDisclosure = manager.repositoryDisclosure(for: fixture.project.id, in: collection.id)
        let selectedId = manager.selectedWorkspaceId
        let items = try #require(manager.navigationSections.last?.blocks.first?.items)
        let content = ProjectSection(project: fixture.project, items: items)
            .environmentObject(manager)
            .environmentObject(manager.settings)
            .environmentObject(TurnCompletionAttentionStore())
            .environmentObject(AgentStatusStore())
            .environmentObject(WorkspacePullRequestStatusModel())
            .environmentObject(SidebarNavigationDropFeedback())
            .environment(WindowFocusState())
            .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: width))
        let restoreAccessibility = try enableNativeAccessibility()
        defer { restoreAccessibility() }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width - 16, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        let controls = accessibilityDescendants(host)
        let disclosure = try #require(
            controls.first { $0.accessibilityLabel?() == "\(fixture.project.displayName), Project" })
        let retry = try #require(controls.first { $0.accessibilityLabel?() == "Retry Stack discovery" })
        let disclosureFrame = try #require(disclosure.accessibilityFrame?())
        let retryFrame = try #require(retry.accessibilityFrame?())
        #expect(disclosureFrame.width >= 20 && disclosureFrame.height >= 20)
        #expect(retryFrame.width >= 20 && retryFrame.height >= 20)
        #expect(disclosureFrame.maxX <= retryFrame.minX)
        #expect(retryFrame.maxX - disclosureFrame.minX <= width - 16)
        let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        #expect(disclosureFrame.minX >= contentFrame.minX && retryFrame.maxX <= contentFrame.maxX)
        #expect(disclosure.accessibilityPerformPress?() == true)
        #expect(!fixture.isExpanded)
        #expect(manager.repositoryDisclosure(for: fixture.project.id, in: collection.id) == otherDisclosure)
        #expect(manager.selectedWorkspaceId == selectedId)
    }
}

// Pixel regions use the hosting view's top-left point coordinates, not the outer sidebar width.
extension ProjectCollectionUITests {
    func sidebarForegroundPixelCount(
        _ bitmap: NSBitmapImageRep, in rect: CGRect, scale: CGFloat, threshold: CGFloat = 0.7
    ) -> Int {
        guard rect.maxX > 0, rect.maxY > 0, rect.minX * scale < CGFloat(bitmap.pixelsWide),
            rect.minY * scale < CGFloat(bitmap.pixelsHigh)
        else { return 0 }
        var count = 0
        for y in max(0, Int(rect.minY * scale))..<min(bitmap.pixelsHigh, Int(rect.maxY * scale)) {
            for x in max(0, Int(rect.minX * scale))..<min(bitmap.pixelsWide, Int(rect.maxX * scale)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.7,
                    min(color.redComponent, color.greenComponent, color.blueComponent) > threshold
                {
                    count += 1
                }
            }
        }
        return count
    }
}
