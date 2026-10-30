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

    @Test func `prepared recovery keeps the prior app when replacement has the same ASAR`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source")
        let old = try fixture.app("Old")
        let marker = "Contents/Resources/prior-app.txt"
        let priorBytes = Data("original app recovery sentinel".utf8)
        try priorBytes.write(to: old.appendingPathComponent(marker))
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", old.path])
        let expectedHash = try fixture.engine.inspect(source).asarSHA256
        #expect(try fixture.engine.inspect(old).asarSHA256 == expectedHash)
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: old, to: fixture.paths.defaultDestination)
        let originalSettings: [String: Any] = ["schemaVersion": 1, "enabled": false, "plugins": ["keep": true], "custom": "prior"]
        try fixture.writeConfig(originalSettings)
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let originalConfig = try Data(contentsOf: config)

        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let backup = URL(fileURLWithPath: try #require(result.recoveryDirectory))
        let receipts = fixture.paths.state.appendingPathComponent("Receipts")
        let receipt = try #require(manager.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        let transaction = try #require(object["transaction"] as? String)
        // Recreate a crash after the prepared journal, before the prior app was moved.
        try manager.removeItem(at: fixture.paths.defaultDestination)
        try manager.moveItem(at: backup.appendingPathComponent("previous.app"), to: fixture.paths.defaultDestination)
        try originalConfig.write(to: config)
        let stage = fixture.paths.defaultDestination.deletingLastPathComponent().appendingPathComponent(".YapperCord-stage-\(transaction).app")
        try manager.copyItem(at: source, to: stage)
        object["phase"] = "prepared"
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)

        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)

        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256 == expectedHash)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent(marker)) == priorBytes)
        #expect(try Data(contentsOf: config) == originalConfig)
        #expect(!manager.fileExists(atPath: stage.path))
        #expect(!manager.fileExists(atPath: backup.appendingPathComponent("interrupted-Yapper.app").path))
        #expect(!manager.fileExists(atPath: receipt.path))
    }

    @Test func `interrupted restore keeps a moved back prior app when ASAR hashes are equal`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source")
        let old = try fixture.app("Old")
        let marker = "Contents/Resources/prior-app.txt"
        let priorBytes = Data("original app recovery sentinel".utf8)
        try priorBytes.write(to: old.appendingPathComponent(marker))
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", old.path])
        let expectedHash = try fixture.engine.inspect(source).asarSHA256
        #expect(try fixture.engine.inspect(old).asarSHA256 == expectedHash)
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: old, to: fixture.paths.defaultDestination)
        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let backup = URL(fileURLWithPath: try #require(result.recoveryDirectory))
        let removed = backup.appendingPathComponent("removed-Yapper.app")
        // Recreate a crash after both restore moves, before config/journal cleanup.
        try manager.moveItem(at: fixture.paths.defaultDestination, to: removed)
        try manager.moveItem(at: backup.appendingPathComponent("previous.app"), to: fixture.paths.defaultDestination)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": true, "plugins": ["recent-setting": true], "custom": "latest"])
        let receipts = fixture.paths.state.appendingPathComponent("Receipts")
        let receipt = try #require(manager.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["phase"] = "restoring"
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)

        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)

        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256 == expectedHash)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent(marker)) == priorBytes)
        #expect(try fixture.config()["enabled"] as? Bool == false)
        #expect(try fixture.config()["plugins"] as? [String: Bool] == ["recent-setting": true])
        #expect(try fixture.config()["custom"] as? String == "latest")
        #expect(manager.fileExists(atPath: removed.path))
        #expect(!manager.fileExists(atPath: backup.appendingPathComponent("interrupted-Yapper.app").path))
        #expect(!manager.fileExists(atPath: receipt.path))
    }

    @Test(arguments: ["backed-up", "copied"], [true, false])
    func `a missing backup during install recovery preserves the destination and journal`(phase: String, sameASAR: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source")
        let old = try fixture.app("Old", cord: sameASAR ? "0.1.0" : nil, version: sameASAR ? "1.1.0" : "1.0.0")
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: old, to: fixture.paths.defaultDestination)
        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let backup = URL(fileURLWithPath: try #require(result.recoveryDirectory))
        try manager.removeItem(at: backup.appendingPathComponent("previous.app"))
        let receipts = fixture.paths.state.appendingPathComponent("Receipts")
        let receipt = try #require(manager.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["phase"] = phase
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        let receiptBefore = try Data(contentsOf: receipt)
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let configBefore = try Data(contentsOf: config)
        let appBefore = try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256

        do {
            _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)
            Issue.record("Recovery accepted a missing prior backup without evidence of a completed rollback")
        } catch let error as InstallerFailure {
            #expect(error.localizedDescription.contains("backup is missing"))
        }

        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256 == appBefore)
        #expect(try Data(contentsOf: receipt) == receiptBefore)
        #expect(try Data(contentsOf: config) == configBefore)
        #expect(!manager.fileExists(atPath: backup.appendingPathComponent("interrupted-Yapper.app").path))
    }

    @Test(arguments: [false, true])
    func `recovery retry keeps the restored prior app after saving a replacement`(legacyRuntime: Bool) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source")
        let old = try fixture.app("Old")
        let marker = "Contents/Resources/prior-app.txt"
        let priorBytes = Data("original app recovery sentinel".utf8)
        try priorBytes.write(to: old.appendingPathComponent(marker))
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", old.path])
        let expectedHash = try fixture.engine.inspect(source).asarSHA256
        #expect(try fixture.engine.inspect(old).asarSHA256 == expectedHash)
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: old, to: fixture.paths.defaultDestination)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "plugins": ["keep": true]])
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let originalConfig = try Data(contentsOf: config)
        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let backup = URL(fileURLWithPath: try #require(result.recoveryDirectory))
        let recovered = backup.appendingPathComponent("interrupted-Yapper.app")
        // A prior rollback saved the replacement and restored the old app,
        // then stopped before its copied-phase journal could be cleaned up.
        try manager.moveItem(at: fixture.paths.defaultDestination, to: recovered)
        try manager.moveItem(at: backup.appendingPathComponent("previous.app"), to: fixture.paths.defaultDestination)
        var recoveredHash = expectedHash
        if legacyRuntime {
            let archive = recovered.appendingPathComponent("Contents/Resources/app.asar")
            let bundle = try ASARManifest.file("yappercord/bundle.js", from: archive, limit: 16_777_216)
            var bytes = try Data(contentsOf: archive)
            let member = try #require(bytes.range(of: bundle))
            bytes[member.lowerBound] ^= 1
            try bytes.write(to: archive)
            _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", recovered.path])
            recoveredHash = try fixture.engine.inspect(recovered, requireYapperCord: false).asarSHA256
            #expect(throws: (any Error).self) { try fixture.engine.inspect(recovered) }
        }
        let receipts = fixture.paths.state.appendingPathComponent("Receipts")
        let receipt = try #require(manager.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil).first)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        object["phase"] = "copied"
        object["expectedASAR"] = recoveredHash
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)

        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)

        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent(marker)) == priorBytes)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256 == expectedHash)
        #expect(try fixture.engine.inspect(recovered, requireYapperCord: false).asarSHA256 == recoveredHash)
        #expect(try Data(contentsOf: config) == originalConfig)
        #expect(!manager.fileExists(atPath: receipt.path))
    }
}
