import Foundation

/// Whether libghostty may treat a directory as Ghostty's resource pack.
///
/// Ghostty uses `GHOSTTY_RESOURCES_DIR` as proof that terminfo lives at
/// `dirname(dir)/terminfo`. A nonempty value makes it set `TERM=xterm-ghostty`
/// and `TERMINFO` to that sibling. Argus's application Resources directory
/// is not that layout, so pointing Ghostty at it advertises a TERM name
/// with no usable terminfo entry.
enum GhosttyResources {
    static let resourcesDirectoryKey = "GHOSTTY_RESOURCES_DIR"

    /// Prefer a real bundled Ghostty pack; otherwise keep a valid inherited
    /// directory. Return nil when neither exists so the caller can unset the
    /// variable rather than leave a lying value in the process environment.
    static func directoryForEnvironment(
        bundleResourcePath: String?,
        inherited: String?,
        fileManager: FileManager = .default
    ) -> String? {
        if let bundleResourcePath,
            let bundled = bundledDirectory(
                resourcePath: bundleResourcePath,
                fileManager: fileManager
            )
        {
            return bundled
        }
        if let inherited, isValidResourcesDirectory(inherited, fileManager: fileManager) {
            return inherited
        }
        return nil
    }

    /// Ghostty.app layout: `Resources/ghostty` plus sibling `Resources/terminfo`.
    static func bundledDirectory(
        resourcePath: String,
        fileManager: FileManager = .default
    ) -> String? {
        let resources = URL(fileURLWithPath: resourcePath, isDirectory: true)
        let ghosttyDirectory = resources.appendingPathComponent("ghostty", isDirectory: true).path
        guard isValidResourcesDirectory(ghosttyDirectory, fileManager: fileManager) else {
            return nil
        }
        return ghosttyDirectory
    }

    /// True when `dirname(path)/terminfo/78/xterm-ghostty` exists, matching
    /// the sibling path Ghostty assigns to `TERMINFO`.
    static func isValidResourcesDirectory(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !path.isEmpty else { return false }
        let terminfoEntry = URL(fileURLWithPath: path, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("terminfo", isDirectory: true)
            .appendingPathComponent("78", isDirectory: true)
            .appendingPathComponent("xterm-ghostty")
        return fileManager.fileExists(atPath: terminfoEntry.path)
    }
}
