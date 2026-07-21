// SidebarDivider.swift
// Argus
//
// Draggable dividers between the sidebar/content/git-sidebar columns.
// Each divider is a 1px visible line with a 12px invisible hit zone for
// drag gestures. The cursor changes to a horizontal-resize arrow on hover.

import AppKit
import SwiftUI

// MARK: - Left Sidebar Divider

/// Divider between the left sidebar and the content area.
/// Dragging right increases `position`; dragging left decreases it.
struct SidebarDivider: View {
    @Binding var position: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(
                        // .global: translation must track raw mouse movement, not the
                        // divider's own on-screen position — that position moves every
                        // time `position` changes, which would otherwise feed back into
                        // the drag and make it overshoot/oscillate.
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartWidth == nil {
                                    dragStartWidth = position
                                }
                                let newWidth =
                                    (dragStartWidth ?? position)
                                    + value.translation.width
                                withTransaction(Transaction(animation: nil)) {
                                    position = max(minValue, min(maxValue, newWidth))
                                }
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            )
            // Neighboring siblings in the HStack paint after this divider and would
            // otherwise cover half of the invisible hit zone above; keep it on top.
            .zIndex(1)
    }
}

// MARK: - Right Git Sidebar Divider

/// Divider between the content area and the right git sidebar.
/// Dragging left increases the sidebar width; dragging right decreases it
/// (inverted compared to `SidebarDivider`).
struct GitSidebarDivider: View {
    @Binding var position: CGFloat
    let minValue: CGFloat
    let maxValue: CGFloat

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .cursor(.resizeLeftRight)
                    .gesture(
                        // .global: translation must track raw mouse movement, not the
                        // divider's own on-screen position — that position moves every
                        // time `position` changes, which would otherwise feed back into
                        // the drag and make it overshoot/oscillate.
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStartWidth == nil {
                                    dragStartWidth = position
                                }
                                // Invert: dragging left (negative translation)
                                // should increase the git sidebar width.
                                let newWidth =
                                    (dragStartWidth ?? position)
                                    - value.translation.width
                                withTransaction(Transaction(animation: nil)) {
                                    position = max(minValue, min(maxValue, newWidth))
                                }
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            )
            // Neighboring siblings in the HStack paint after this divider and would
            // otherwise cover half of the invisible hit zone above; keep it on top.
            .zIndex(1)
    }
}

// MARK: - Cursor Modifier

extension View {
    /// Pushes the given cursor while the pointer hovers over this view.
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { hovering in
            if hovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
