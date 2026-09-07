import SwiftUI

extension SidebarView {
    var body: some View {
        GeometryReader { geometry in
            sidebarContent
                .environment(\.sidebarWidthMetrics, SidebarWidthMetrics(width: geometry.size.width))
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Header with title and global add buttons
            SidebarHeader()
                .windowFocusChrome()
                .modifier(SidebarNavigationDropTarget(target: .ungrouped))

            // Project sections
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(workspaceManager.collections) { collection in
                            SidebarCollectionSection(collection: collection)
                        }
                        if !workspaceManager.collections.isEmpty && !workspaceManager.ungroupedWorkspaceIds.isEmpty {
                            SidebarUngroupedHeader()
                        }
                        SidebarSectionContent(collectionId: nil)

                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: workspaceManager.workspaceRevealRevision) { _, revision in
                    let workspaceId = workspaceManager.selectedWorkspaceId
                    Task { @MainActor in
                        await Task.yield()
                        guard let workspaceId,
                            workspaceManager.workspaceRevealRevision == revision,
                            workspaceManager.selectedWorkspaceId == workspaceId
                        else { return }
                        proxy.scrollTo(workspaceId)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(ChromeColors.shellBackground)
        .environment(\.isCommandKeyHeld, commandKeyMonitor.isCommandHeld)
        .environmentObject(dropFeedback)
        .onAppear { commandKeyMonitor.start() }
        .onDisappear {
            commandKeyMonitor.stop()
            dropFeedback.end()
        }
    }
}

// MARK: - Sidebar Header

/// Top header with "Projects" label and a New Project action.
private struct SidebarHeader: View {
    @EnvironmentObject private var appSettings: AppSettings
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @State private var isAddHovered = false

    var body: some View {
        HStack(spacing: sidebarMetrics.isCompact ? 2 : nil) {
            Text("Workspaces")
                .font(
                    .system(
                        size: appSettings.presentationMetrics.textSize(forBaseSize: 11),
                        weight: .semibold
                    )
                )
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Menu {
                Button("New Workspace…") {
                    NotificationCenter.default.post(
                        name: .showNewWorkspaceSheet,
                        object: WorkspaceCreationRequest(projectId: nil, collectionId: nil))
                }
                Button("New Project…") {
                    NotificationCenter.default.post(name: .showNewProjectSheet, object: nil)
                }
                Button("New Collection…") {
                    NotificationCenter.default.post(name: .showCollectionSheet, object: nil)
                }
                .disabled(!workspaceManager.canCreateCollection)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isAddHovered ? ChromeColors.hoveredTabFill : Color.clear)
                    }
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isAddHovered = $0 }
            .cursor(.pointingHand)
            .help("New Workspace, Project, or Collection")
            .accessibilityLabel("New Workspace, Project, or Collection")
        }
        .padding(.horizontal, sidebarMetrics.isCompact ? 6 : 12)
        .padding(.vertical, 8)
        .padding(.top, 28)  // Space for titlebar traffic lights
    }
}

struct SidebarStackDiscoveryStatus: View {
    let projectId: UUID
    @EnvironmentObject private var workspaceManager: WorkspaceManager
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            if workspaceManager.refreshingWorkspaceStackProjectIds.contains(projectId) {
                ProgressView()
                    .controlSize(.mini)
                    .help("Refreshing local Stacks")
                    .accessibilityLabel("Refreshing Stacks")
            } else if let error = workspaceManager.workspaceStackErrors[projectId] {
                Button {
                    workspaceManager.refreshWorkspaceStacks(in: projectId)
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isHovered || isFocused ? ChromeColors.hoveredTabFill : Color.clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isFocused)
                .onHover { isHovered = $0 }
                .cursor(.pointingHand)
                .help("Stack discovery issue: \(error)\nRetry Stack discovery")
                .accessibilityLabel("Retry Stack discovery")
                .accessibilityValue(error)
            } else {
                Color.clear
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 20, height: 20)
    }
}
