import Foundation
import Testing

@testable import Argus

@Suite
struct GhosttyResourcesTests {
    @Test
    func aBundleWithoutTerminfoDoesNotAdvertiseGhosttyResources() throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-ghostty-resources-empty")
        defer { temporary.remove() }

        #expect(
            GhosttyResources.directoryForEnvironment(
                bundleResourcePath: temporary.url.path,
                inherited: nil
            ) == nil
        )
        #expect(
            GhosttyResources.directoryForEnvironment(
                bundleResourcePath: temporary.url.path,
                inherited: temporary.url.path
            ) == nil
        )
    }

    @Test
    func aBundledGhosttyLayoutWinsOverInheritedPaths() throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-ghostty-resources-bundled")
        defer { temporary.remove() }
        let ghosttyDirectory = try writeGhosttyResourceLayout(in: temporary.url)

        #expect(
            GhosttyResources.directoryForEnvironment(
                bundleResourcePath: temporary.url.path,
                inherited: "/not/a/ghostty/pack"
            ) == ghosttyDirectory
        )
    }

    @Test
    func aValidInheritedGhosttyDirectoryIsKeptWhenTheBundleHasNone() throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-ghostty-resources-inherited")
        defer { temporary.remove() }
        let resources = temporary.url.appendingPathComponent("Resources", isDirectory: true)
        let ghosttyDirectory = try writeGhosttyResourceLayout(in: resources)
        let emptyBundle = try TestTemporaryDirectory(prefix: "argus-ghostty-resources-bundle-empty")
        defer { emptyBundle.remove() }

        #expect(
            GhosttyResources.directoryForEnvironment(
                bundleResourcePath: emptyBundle.url.path,
                inherited: ghosttyDirectory
            ) == ghosttyDirectory
        )
    }

    @Test
    func anEmptyInheritedValueIsIgnored() throws {
        let temporary = try TestTemporaryDirectory(prefix: "argus-ghostty-resources-empty-inherited")
        defer { temporary.remove() }

        #expect(
            GhosttyResources.directoryForEnvironment(
                bundleResourcePath: temporary.url.path,
                inherited: ""
            ) == nil
        )
        #expect(GhosttyResources.isValidResourcesDirectory("") == false)
    }
}

private func writeGhosttyResourceLayout(in resources: URL) throws -> String {
    let terminfoEntry =
        resources
        .appendingPathComponent("terminfo", isDirectory: true)
        .appendingPathComponent("78", isDirectory: true)
        .appendingPathComponent("xterm-ghostty")
    try FileManager.default.createDirectory(
        at: terminfoEntry.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data().write(to: terminfoEntry)
    return resources.appendingPathComponent("ghostty", isDirectory: true).path
}
