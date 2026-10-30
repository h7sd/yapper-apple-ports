import Foundation
import Testing
@testable import InstallerCore

@Suite struct LegacyReceiptTests {
    @Test func `legacy runtime can be disabled and restored but cannot be enabled as a new source`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let previous = try fixture.app("Previous", cord: nil, version: "1.0.0")
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: previous, to: fixture.paths.defaultDestination)
        _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let archive = fixture.paths.defaultDestination.appendingPathComponent("Contents/Resources/app.asar")
        let bundle = try ASARManifest.file("yappercord/bundle.js", from: archive, limit: 16_777_216)
        var bytes = try Data(contentsOf: archive)
        let member = try #require(bytes.range(of: bundle))
        bytes[member.lowerBound] ^= 1
        try bytes.write(to: archive)
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", fixture.paths.defaultDestination.path])
        let legacyInspection = try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false)
        let receipt = try #require(manager.contentsOfDirectory(at: fixture.paths.state.appendingPathComponent("Receipts"), includingPropertiesForKeys: nil).first)
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        // Model an older installer's valid journal for a different runtime build.
        journal["expectedASAR"] = legacyInspection.asarSHA256
        try JSONSerialization.data(withJSONObject: journal).write(to: receipt)
        #expect(throws: (any Error).self) { try fixture.engine.inspect(fixture.paths.defaultDestination) }
        #expect(throws: (any Error).self) { try fixture.engine.setEnabled(true, app: fixture.paths.defaultDestination) }
        _ = try fixture.engine.setEnabled(false, app: fixture.paths.defaultDestination)
        #expect(try fixture.config()["enabled"] as? Bool == false)
        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).appVersion == "1.0.0")
        #expect(!manager.fileExists(atPath: receipt.path))
    }
}
