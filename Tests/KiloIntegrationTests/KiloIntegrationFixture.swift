import Foundation

@testable import Argus

enum KiloIntegrationFixtureError: Error { case injected }

struct KiloIntegrationFixture {
    let root: URL
    let plugin: URL
    func write(_ text: String, named: String) throws {
        try text.write(to: root.appendingPathComponent(named), atomically: true, encoding: .utf8)
    }
    func service(environment: [String: String] = [:], inject: ((KiloIntegrationFailurePoint) throws -> Void)? = nil)
        -> KiloIntegrationService
    {
        var environment = environment
        if environment["KILO_CONFIG_DIR"] == nil {
            environment["KILO_CONFIG_DIR"] = root.path
        }
        return KiloIntegrationService(
            environment: environment, homeDirectory: root.deletingLastPathComponent(), pluginSourceURL: plugin,
            injectFailure: inject)
    }
}

func withKiloIntegrationFixture(_ body: (KiloIntegrationFixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("argus-kilo-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("source.js")
    try "/* Argus-owned Kilo TUI plugin */\nexport default {};\n".write(to: plugin, atomically: true, encoding: .utf8)
    try body(KiloIntegrationFixture(root: root, plugin: plugin))
}
