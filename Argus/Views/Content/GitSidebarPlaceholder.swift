// GitSidebarPlaceholder.swift
// Argus
//
// Placeholder view for the right git-status sidebar.
// Will be replaced with a full implementation in Phase 3.

import SwiftUI

struct GitSidebarPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 24))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Git Status")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            Text("Coming in Phase 3")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
    }
}
