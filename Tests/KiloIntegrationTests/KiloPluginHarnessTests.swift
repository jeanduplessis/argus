import Foundation
import Testing

struct KiloPluginHarnessTests {
    @Test
    func pluginBehavioralHarnessPasses() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let harness = repositoryRoot.appendingPathComponent("Tests/KiloIntegrationTests/plugin-events.mjs")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["node", harness.path]
        process.currentDirectoryURL = repositoryRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let result = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "plugin-events.mjs failed: \(result)")
    }
}
