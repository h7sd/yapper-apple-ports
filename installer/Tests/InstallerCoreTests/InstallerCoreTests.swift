import CryptoKit
import Foundation
import Testing
@testable import InstallerCore

struct Fixture {
    let root: URL
    let home: URL
    var paths: InstallerPaths { InstallerPaths(home: home, globalApplications: root.appendingPathComponent("GlobalApplications")) }
    var engine: InstallerEngine { InstallerEngine(paths: paths, runningExecutables: { [] }) }

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("YapperCordTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("Home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func app(_ name: String, cord: String? = "0.1.0", canonical: String? = nil, version: String = "1.1.0", bundleID: String = "website.yapper.desktop") throws -> URL {
        let app = home.appendingPathComponent("Sources/\(name).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: contents.appendingPathComponent("MacOS/Yapper"))
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Yapper", "CFBundlePackageType": "APPL", "CFBundleName": "Yapper", "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var manifest: [String: Any] = ["productName": "Yapper", "name": "yapper-desktop", "version": version]
        if let cord { manifest["yappercordVersion"] = cord }
        if let canonical { manifest["yapinpluggerVersion"] = canonical }
        try archive(manifest).write(to: contents.appendingPathComponent("Resources/app.asar"))
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    func writeConfig(_ object: Any) throws {
        try FileManager.default.createDirectory(at: paths.defaultUserData, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: paths.defaultUserData.appendingPathComponent("yappercord.json"))
    }

    func config() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.defaultUserData.appendingPathComponent("yappercord.json"))) as? [String: Any])
    }

    private func archive(_ manifest: [String: Any]) throws -> Data {
        var content = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        var files: [String: Any] = ["package.json": ["size": content.count, "offset": "0"]]
        if manifest["yappercordVersion"] != nil || manifest["yapinpluggerVersion"] != nil {
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let bundle = try Data(contentsOf: repository.appendingPathComponent("macos/yappercord/bundle.js"))
            let checksum = Data((InstallerEngine.runtimeBundleSHA256 + "  bundle.js\n").utf8)
            let bundleEntry: [String: Any] = ["size": bundle.count, "offset": String(content.count)]
            content.append(bundle)
            let checksumEntry: [String: Any] = ["size": checksum.count, "offset": String(content.count)]
            content.append(checksum)
            files["yappercord"] = ["files": ["bundle.js": bundleEntry, "bundle.sha256": checksumEntry]]
        }
        let headerJSON = try JSONSerialization.data(withJSONObject: ["files": files], options: [.sortedKeys])
        let padded = (headerJSON.count + 3) & ~3
        var header = word(UInt32(padded + 4))
        header.append(word(UInt32(headerJSON.count)))
        header.append(headerJSON)
        header.append(Data(repeating: 0, count: padded - headerJSON.count))
        var result = word(4)
        result.append(word(UInt32(header.count)))
        result.append(header)
        result.append(content)
        return result
    }

    private func word(_ number: UInt32) -> Data {
        Data([UInt8(number & 255), UInt8((number >> 8) & 255), UInt8((number >> 16) & 255), UInt8((number >> 24) & 255)])
    }
}

@Suite struct InstallerCoreTests {
    @Test func `compatible app is read without executing it`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let inspection = try fixture.engine.inspect(source)
        #expect(inspection.yappercordVersion == "0.1.0")
        #expect(inspection.yapinpluggerVersion == "0.1.0")
        #expect(inspection.appVersion == "1.1.0")
        #expect(inspection.asarSHA256.count == 64)
        #expect(fixture.paths.defaultUserData.lastPathComponent == "Yapper")
    }

    @Test func `canonical marker works without legacy marker and takes precedence`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let canonical = try fixture.app("Canonical", cord: nil, canonical: "0.1.0")
        #expect(try fixture.engine.inspect(canonical).yapinpluggerVersion == "0.1.0")
        let future = try fixture.app("Future", canonical: "0.2.0")
        #expect(throws: (any Error).self) { try fixture.engine.inspect(future) }
    }

    @Test func `automatic source is bundled and never an adjacent app`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let resources = fixture.home.appendingPathComponent("Setup.app/Contents/Resources")
        let adjacent = resources.deletingLastPathComponent().appendingPathComponent("Yapper.app")
        try FileManager.default.createDirectory(at: adjacent, withIntermediateDirectories: true)
        #expect(InstallerSourceSelection.bundledApp(resourceDirectory: resources) == nil)
        let bundled = resources.appendingPathComponent("Yapper.app")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        #expect(InstallerSourceSelection.bundledApp(resourceDirectory: resources)?.path == bundled.path)
        #expect(InstallerSourceSelection.bundledApp(resourceDirectory: nil) == nil)
    }

    @Test func `Finder metadata rejection gives the bundled setup recovery action`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", "0000000000000000000100000000000000000000000000000000000000000000", source.path])
        do {
            _ = try fixture.engine.inspect(source)
            Issue.record("Finder metadata was accepted")
        } catch let error as InstallerFailure {
            #expect(error.localizedDescription.contains("Finder metadata"))
            #expect(error.localizedDescription.contains("Use bundled client"))
            #expect(!error.localizedDescription.contains(fixture.home.path))
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(arguments: [nil, "0.2.0", "1.0.0"])
    func `missing or incompatible runtime is refused`(version: String?) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source", cord: version)
        #expect(throws: (any Error).self) { try fixture.engine.inspect(source) }
    }

    @Test func `new install and restore preserve plugin data and recovery copy`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "plugins": ["example": ["enabled": true]], "custom": "keep"])
        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).asarSHA256 == fixture.engine.inspect(source).asarSHA256)
        #expect(try fixture.config()["enabled"] as? Bool == true)
        #expect(try fixture.config()["custom"] as? String == "keep")
        #expect(try fixture.config()["plugins"] as? [String: [String: Bool]] == ["example": ["enabled": true]])
        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.defaultDestination.path))
        #expect(try fixture.config()["enabled"] as? Bool == false)
        #expect(try fixture.config()["custom"] as? String == "keep")
        let recovery = try #require(result.recoveryDirectory)
        #expect(FileManager.default.fileExists(atPath: recovery + "/removed-Yapper.app"))
    }

    @Test func `existing app requires explicit replacement and is restored byte for byte`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let old = try fixture.app("Old", cord: nil, version: "1.0.0")
        try FileManager.default.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old, to: fixture.paths.defaultDestination)
        let before = try fixture.engine.inspect(old, requireYapperCord: false).asarSHA256
        #expect(throws: (any Error).self) { try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination) }
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).asarSHA256 == before)
        _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).asarSHA256 == before)
        #expect(try fixture.config()["enabled"] as? Bool == false)
    }

    @Test func `running source or target is refused before mutation`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let executable = source.appendingPathComponent("Contents/MacOS/Yapper").path
        let engine = InstallerEngine(paths: fixture.paths, runningExecutables: { [executable] })
        #expect(throws: (any Error).self) { try engine.install(source: source, destination: fixture.paths.defaultDestination) }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.defaultDestination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.defaultUserData.path))
    }

    @Test func `signature tampering is rejected`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let manifest = source.appendingPathComponent("Contents/Resources/app.asar")
        let file = try FileHandle(forWritingTo: manifest)
        try file.seekToEnd(); try file.write(contentsOf: Data("changed".utf8)); try file.close()
        #expect(throws: (any Error).self) { try fixture.engine.inspect(source) }
    }

    @Test func `a validly re-signed app with a changed runtime is rejected by the reviewed checksum`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let archive = source.appendingPathComponent("Contents/Resources/app.asar")
        var data = try Data(contentsOf: archive)
        let originalBundle = try ASARManifest.file("yappercord/bundle.js", from: archive, limit: 16_777_216)
        let start = try #require(data.range(of: originalBundle))
        data[start.lowerBound] = 46
        try data.write(to: archive)
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        do {
            _ = try fixture.engine.inspect(source)
            Issue.record("Changed runtime was accepted")
        } catch let error as InstallerFailure {
            #expect(error.localizedDescription.contains("checksum"))
        }
    }

    @Test func `symlinked destination and config are rejected`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let outside = fixture.root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = fixture.home.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try fixture.engine.install(source: source, destination: alias.appendingPathComponent("Yapper.app")) }
        try FileManager.default.createDirectory(at: fixture.paths.defaultUserData, withIntermediateDirectories: true)
        let sentinel = fixture.home.appendingPathComponent("sentinel.json")
        let original = Data("{\"keep\":true}".utf8)
        try original.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.paths.defaultUserData.appendingPathComponent("yappercord.json"), withDestinationURL: sentinel)
        #expect(throws: (any Error).self) { try fixture.engine.setEnabled(true, app: source) }
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func `escaping bundle symlink is rejected`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Contents/Resources/outside"), withDestinationURL: fixture.home)
        #expect(throws: (any Error).self) { try fixture.engine.inspect(source) }
    }

    @Test(arguments: ["[]", "{\"schemaVersion\":2}", "{\"schemaVersion\":true}", "{\"schemaVersion\":\"future\"}", "not-json"])
    func `invalid settings are preserved rather than replaced`(contents: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        try FileManager.default.createDirectory(at: fixture.paths.defaultUserData, withIntermediateDirectories: true)
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let data = Data(contents.utf8)
        try data.write(to: config)
        #expect(throws: (any Error).self) { try fixture.engine.setEnabled(true, app: source) }
        #expect(try Data(contentsOf: config) == data)
    }

    @Test func `restore refuses an app changed after install while disable remains available`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination)
        let changed = try fixture.app("Updated", version: "1.2.0")
        try FileManager.default.removeItem(at: fixture.paths.defaultDestination)
        try FileManager.default.copyItem(at: changed, to: fixture.paths.defaultDestination)
        #expect(throws: (any Error).self) { try fixture.engine.restore(destination: fixture.paths.defaultDestination) }
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).appVersion == "1.2.0")
        _ = try fixture.engine.setEnabled(false, app: fixture.paths.defaultDestination)
        #expect(try fixture.config()["enabled"] as? Bool == false)
    }

    @Test func `a config write failure rolls back the app replacement`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source")
        let old = try fixture.app("Old", cord: nil, version: "1.0.0")
        try FileManager.default.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: old, to: fixture.paths.defaultDestination)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "custom": "preserve"])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.paths.defaultUserData.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.paths.defaultUserData.path) }
        #expect(throws: (any Error).self) { try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true) }
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).appVersion == "1.0.0")
        #expect(try fixture.config()["custom"] as? String == "preserve")
        #expect(try fixture.config()["enabled"] as? Bool == false)
    }

    @Test func `truncated and oversized ASAR headers are rejected`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let archive = fixture.home.appendingPathComponent("bad.asar")
        try Data([4, 0, 0, 0, 255, 255, 255, 255]).write(to: archive)
        #expect(throws: (any Error).self) { try ASARManifest.read(from: archive) }
        try Data([4, 0]).write(to: archive)
        #expect(throws: (any Error).self) { try ASARManifest.read(from: archive) }
    }
}
