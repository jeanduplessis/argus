import SwiftUI

extension GitFileStatus {
    var systemImage: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .modified: return "circle.fill"
        case .deleted: return "minus.circle.fill"
        case .renamed: return "arrow.right.circle.fill"
        case .copied: return "doc.on.doc.fill"
        case .typeChanged: return "questionmark.circle.fill"
        case .untracked: return "questionmark.circle.fill"
        case .unmerged: return "exclamationmark.triangle.fill"
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
