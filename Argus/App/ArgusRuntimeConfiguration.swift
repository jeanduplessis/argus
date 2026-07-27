import Foundation

/// Build-time identity and storage locations for one local Argus instance.
/// The unqualified build preserves the stable application's existing paths.
struct ArgusRuntimeConfiguration: Sendable {
    static let current = ArgusRuntimeConfiguration()

    let variant: String?
    let homeDirectory: URL

    init(
        variant: String? = Bundle.main.object(forInfoDictionaryKey: "ArgusBuildVariant") as? String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let normalized = variant?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.variant = normalized?.isEmpty == false ? normalized : nil
        self.homeDirectory = homeDirectory
    }

    var applicationSupportDirectory: URL {
        let base = homeDirectory.appendingPathComponent("Library/Application Support/Argus", isDirectory: true)
        return variantDirectory(under: base)
    }

    var cacheDirectory: URL {
        let base = homeDirectory.appendingPathComponent("Library/Caches/Argus", isDirectory: true)
        return variantDirectory(under: base)
    }

    var runtimeDirectory: URL {
        let base = homeDirectory.appendingPathComponent(".argus", isDirectory: true)
        return variantDirectory(under: base)
    }

    var sessionSnapshotURL: URL {
        applicationSupportDirectory.appendingPathComponent("session.json")
    }

    var reviewSessionURL: URL {
        applicationSupportDirectory.appendingPathComponent("review-session.json")
    }

    var reviewCacheDirectoryURL: URL {
        cacheDirectory.appendingPathComponent("Review", isDirectory: true)
    }

    var socketURL: URL {
        runtimeDirectory.appendingPathComponent("argus.sock")
    }

    var worktreeBaseURL: URL {
        runtimeDirectory.appendingPathComponent("worktrees", isDirectory: true)
    }

    private func variantDirectory(under base: URL) -> URL {
        guard let variant else { return base }
        return base
            .appendingPathComponent("Variants", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }
}
