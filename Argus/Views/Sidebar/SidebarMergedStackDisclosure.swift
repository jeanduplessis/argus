import SwiftUI

struct SidebarMergedStackDisclosure: View {
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.sidebarWidthMetrics) private var sidebarMetrics
    @Environment(\.sidebarCollectionContentInset) private var collectionContentInset
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: sidebarMetrics.headerSpacing) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: sidebarMetrics.disclosureWidth)
                    .accessibilityHidden(true)
                Text("\(count) merged \(count == 1 ? "PR" : "PRs")")
                    .font(.system(size: appSettings.presentationMetrics.textSize(forBaseSize: 10)))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .windowFocusChrome()
            .padding(.leading, collectionContentInset)
            .padding(.horizontal, sidebarMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
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
        .help(
            "\(isExpanded ? "Collapse" : "Show") Workspaces with merged Pull Requests. "
                + "Worktrees and branches are retained."
        )
        .accessibilityLabel("\(count) Workspaces with merged Pull Requests")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
