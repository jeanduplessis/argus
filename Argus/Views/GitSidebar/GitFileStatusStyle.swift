import SwiftUI

extension GitFileStatus {
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
