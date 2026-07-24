import AppKit

extension TerminalNSView {
    private static let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let ghosttySurface = surface?.surface,
            let urls = droppedFileURLs(from: sender)
        else { return false }

        window?.makeFirstResponder(self)

        // Insert quoted paths without executing them, matching other terminals.
        let text = urls.map { shellQuotedPath($0.path) }.joined(separator: " ") + " "
        text.withCString { pointer in
            ghostty_surface_text(ghosttySurface, pointer, UInt(text.utf8.count))
        }
        return true
    }

    private func droppedFileURLs(from sender: NSDraggingInfo) -> [URL]? {
        guard
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: Self.fileURLReadingOptions
            ) as? [URL],
            !urls.isEmpty
        else { return nil }
        return urls
    }
}

private func shellQuotedPath(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
