import Foundation
import Testing
@testable import InstallerCore

@Suite struct RecoveryTests {
    @Test func `interrupted restore recovers the prior app without reverting recent plugin preferences`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let old = try fixture.app("Old", cord: nil, version: "1.0.0")
        try FileManager.default.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old, to: fixture.paths.defaultDestination)
        _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": true, "plugins": ["recent-setting": true]])
        let receipts = fixture.paths.state.appendingPathComponent("Receipts")
        let receipt = try #require(FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["phase"] = "restoring"
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).appVersion == "1.0.0")
        #expect(try fixture.config()["enabled"] as? Bool == false)
        #expect(try fixture.config()["plugins"] as? [String: Bool] == ["recent-setting": true])
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
    }

    @Test func `truncated manifest cannot request an unbounded allocation`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YapperCord-ASAR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([4, 0, 0, 0, 8, 0, 0, 0, 4, 0, 0, 0, 255, 255, 255, 255]).write(to: root)
        #expect(throws: (any Error).self) { try ASARManifest.read(from: root) }
    }
}
