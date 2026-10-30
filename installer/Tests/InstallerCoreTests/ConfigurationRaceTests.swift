import Foundation
import Testing
@testable import InstallerCore

@Suite struct ConfigurationRaceTests {
    @Test func `profile changes during staging are preserved and installation is refused`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "plugins": ["original": true]])
        let destination = fixture.paths.defaultDestination
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let latest = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "enabled": false, "plugins": ["changed-elsewhere": true]], options: [.sortedKeys])
        let engine = InstallerEngine(paths: fixture.paths, runningExecutables: {
            // The second running-process check occurs after the staged copy.
            let siblings = try? FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            if siblings?.contains(where: { $0.lastPathComponent.hasPrefix(".YapperCord-stage-") }) == true {
                try latest.write(to: config, options: [.atomic])
            }
            return []
        })
        #expect(throws: (any Error).self) { try engine.install(source: source, destination: destination) }
        #expect(try Data(contentsOf: config) == latest)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let siblings = try FileManager.default.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(!siblings.contains(where: { $0.lastPathComponent.hasPrefix(".YapperCord-stage-") }))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.state.appendingPathComponent("Receipts").path))
    }
}
