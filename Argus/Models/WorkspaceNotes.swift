import Foundation

/// Bounds for Workspace Notes, the plain-text Markdown a user writes for one Workspace.
enum WorkspaceNotes {
    /// Largest Workspace Notes value, in UTF-8 bytes, that Argus edits or restores.
    static let maximumUTF8ByteCount = 1_048_576

    static func isWithinLimit(_ notes: String) -> Bool {
        notes.utf8.count <= maximumUTF8ByteCount
    }

    /// Returns whether replacing `removedText` with `insertedText` keeps notes
    /// currently `currentUTF8ByteCount` bytes long within the limit.
    static func fitsAfterReplacing(
        currentUTF8ByteCount: Int,
        removedText: String,
        insertedText: String
    ) -> Bool {
        let resultingCount = currentUTF8ByteCount - removedText.utf8.count + insertedText.utf8.count
        return resultingCount <= maximumUTF8ByteCount
    }
}
