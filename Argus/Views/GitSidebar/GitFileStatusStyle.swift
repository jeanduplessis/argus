import SwiftUI

extension GitFileStatus {
    var systemImage: String? {
        switch self {
        case .added, .modified, .deleted, .untracked: return nil
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .typeChanged: return "wrench.and.screwdriver"
        case .unmerged: return "exclamationmark.triangle"
        }
    }

    var displayName: String {
        switch self {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .untracked: return "Untracked"
        case .unmerged: return "Merge conflict"
        }
    }

    var tintColor: Color {
        switch self {
        case .added, .untracked: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .renamed, .copied: return .blue
        case .typeChanged: return .purple
        case .unmerged: return .yellow
        }
    }
}
