import Foundation
import Testing
@testable import InstallerCore

@Suite struct MetadataUpgradeTests {
    private let finderInfo = "0000000000000000000100000000000000000000000000000000000000000000"
    private let attributes = [
        ("", "com.apple.FinderInfo"),
        ("", "com.apple.quarantine"),
        ("", "dev.yapper.metadata-fixture"),
        ("Contents/Frameworks/Yapper Helper (Renderer).app", "com.apple.FinderInfo"),
        ("Contents/Resources/metadata.fixture", "com.apple.ResourceFork")
    ]

    private func addSignedNestedHelper(to app: URL) throws {
        let manager = FileManager.default
        let helper = app.appendingPathComponent("Contents/Frameworks/Yapper Helper (Renderer).app")
        let contents = helper.appendingPathComponent("Contents")
        try manager.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try manager.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: contents.appendingPathComponent("MacOS/Yapper Helper (Renderer)"))
        let info: [String: Any] = ["CFBundleIdentifier": "website.yapper.desktop.helper.Renderer", "CFBundleExecutable": "Yapper Helper (Renderer)", "CFBundlePackageType": "APPL", "CFBundleName": "Yapper Helper (Renderer)", "CFBundleVersion": "1.0.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("signed nested metadata resource".utf8).write(to: app.appendingPathComponent("Contents/Resources/metadata.fixture"))
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", helper.path])
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        _ = try InstallerEngine.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    private func addMetadata(to app: URL) throws {
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", finderInfo, app.path])
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0081;6553f100;Yapinplugger Metadata Fixture;fixture", app.path])
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-w", "dev.yapper.metadata-fixture", "preserve this attribute", app.path])
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", finderInfo, app.appendingPathComponent("Contents/Frameworks/Yapper Helper (Renderer).app").path])
        _ = try InstallerEngine.run("/usr/bin/xattr", ["-w", "com.apple.ResourceFork", "resource fork fixture", app.appendingPathComponent("Contents/Resources/metadata.fixture").path])
    }

    private func metadata(in app: URL) throws -> [String] {
        try attributes.map { relativePath, name in
            let file = relativePath.isEmpty ? app : app.appendingPathComponent(relativePath)
            return try InstallerEngine.run("/usr/bin/xattr", ["-px", name, file.path])
        }
    }

    @Test func `explicit upgrade and restore preserve metadata on the previous app`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source", canonical: "0.1.0")
        let old = try fixture.app("Old", cord: nil, version: "1.0.0")
        try addSignedNestedHelper(to: old)
        let archivePath = "Contents/Resources/app.asar"
        let sealPath = "Contents/_CodeSignature/CodeResources"
        let originalArchive = try Data(contentsOf: old.appendingPathComponent(archivePath))
        let originalSeal = try Data(contentsOf: old.appendingPathComponent(sealPath))
        try addMetadata(to: old)
        let originalMetadata = try metadata(in: old)
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: old, to: fixture.paths.defaultDestination)
        #expect(try metadata(in: fixture.paths.defaultDestination) == originalMetadata)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "plugins": ["keep": true], "custom": "retained"])
        let profileSentinel = fixture.paths.defaultUserData.appendingPathComponent("profile-data.fixture")
        let profileBytes = Data("existing profile data".utf8)
        try profileBytes.write(to: profileSentinel)

        do {
            _ = try InstallerEngine.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.paths.defaultDestination.path])
            Issue.record("Metadata-affected destination unexpectedly passed strict original verification")
        } catch InstallerFailure.metadataSignature {}
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).appVersion == "1.0.0")
        #expect(try metadata(in: fixture.paths.defaultDestination) == originalMetadata)
        #expect(throws: (any Error).self) { try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination) }
        #expect(try metadata(in: fixture.paths.defaultDestination) == originalMetadata)

        let result = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
        let backup = URL(fileURLWithPath: try #require(result.recoveryDirectory)).appendingPathComponent("previous.app")
        #expect(try metadata(in: backup) == originalMetadata)
        #expect(try Data(contentsOf: backup.appendingPathComponent(archivePath)) == originalArchive)
        #expect(try Data(contentsOf: backup.appendingPathComponent(sealPath)) == originalSeal)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).yapinpluggerVersion == "0.1.0")
        #expect(try fixture.config()["enabled"] as? Bool == true)
        #expect(try Data(contentsOf: profileSentinel) == profileBytes)

        _ = try fixture.engine.restore(destination: fixture.paths.defaultDestination)

        #expect(try metadata(in: fixture.paths.defaultDestination) == originalMetadata)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent(archivePath)) == originalArchive)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent(sealPath)) == originalSeal)
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination, requireYapperCord: false).appVersion == "1.0.0")
        #expect(try fixture.config()["enabled"] as? Bool == false)
        #expect(try fixture.config()["plugins"] as? [String: Bool] == ["keep": true])
        #expect(try fixture.config()["custom"] as? String == "retained")
        #expect(try Data(contentsOf: profileSentinel) == profileBytes)
    }

    @Test func `metadata does not hide tampering in a previous destination`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let manager = FileManager.default
        let source = try fixture.app("Source")
        let old = try fixture.app("Old", cord: nil, version: "1.0.0")
        try addSignedNestedHelper(to: old)
        try addMetadata(to: old)
        let archive = old.appendingPathComponent("Contents/Resources/app.asar")
        let file = try FileHandle(forWritingTo: archive)
        try file.seekToEnd(); try file.write(contentsOf: Data("signed resource tampering".utf8)); try file.close()
        let tamperedArchive = try Data(contentsOf: archive)
        let originalMetadata = try metadata(in: old)
        try manager.createDirectory(at: fixture.paths.defaultDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: old, to: fixture.paths.defaultDestination)
        try fixture.writeConfig(["schemaVersion": 1, "enabled": false, "custom": "keep"])
        let config = fixture.paths.defaultUserData.appendingPathComponent("yappercord.json")
        let originalConfig = try Data(contentsOf: config)

        // Initial codesign may report content damage before metadata. Exercise
        // the isolated-copy verifier too, so its full signature check is required.
        do {
            try fixture.engine.verifyAppWithMetadata(fixture.paths.defaultDestination, requireYapperCord: false)
            Issue.record("The isolated metadata-validation copy accepted changed signed contents")
        } catch let failure as InstallerFailure {
            #expect(failure.localizedDescription.contains("code-signature verification"))
            #expect(!failure.localizedDescription.contains(fixture.root.path))
            #expect(!failure.localizedDescription.contains("Yapinplugger-LegacyValidation-"))
        }

        do {
            _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination, replaceExisting: true)
            Issue.record("Metadata hid a changed signed resource")
        } catch let failure as InstallerFailure {
            #expect(failure.localizedDescription.contains("signature"))
            #expect(!failure.localizedDescription.contains(fixture.root.path))
            #expect(!failure.localizedDescription.contains("Yapinplugger-LegacyValidation-"))
        }

        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent("Contents/Resources/app.asar")) == tamperedArchive)
        #expect(try metadata(in: fixture.paths.defaultDestination) == originalMetadata)
        #expect(try Data(contentsOf: config) == originalConfig)
        #expect(!manager.fileExists(atPath: fixture.paths.state.appendingPathComponent("Receipts").path))
        #expect(!manager.fileExists(atPath: fixture.paths.defaultDestination.deletingLastPathComponent().appendingPathComponent(".YapperCord-Backups").path))
    }

    @Test func `compatible metadata affected source installs a clean signed app without changing the source`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source", canonical: "0.1.0")
        try addSignedNestedHelper(to: source)
        try addMetadata(to: source)
        let originalMetadata = try metadata(in: source)
        let originalArchive = try Data(contentsOf: source.appendingPathComponent("Contents/Resources/app.asar"))
        let originalSeal = try Data(contentsOf: source.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        let quarantine = try InstallerEngine.run("/usr/bin/xattr", ["-px", "com.apple.quarantine", source.path])
        let custom = try InstallerEngine.run("/usr/bin/xattr", ["-px", "dev.yapper.metadata-fixture", source.path])
        #expect(try fixture.engine.inspect(source).runtimeBundleSHA256 == InstallerEngine.runtimeBundleSHA256)

        _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination)

        _ = try InstallerEngine.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fixture.paths.defaultDestination.path])
        #expect(try fixture.engine.inspect(fixture.paths.defaultDestination).runtimeBundleSHA256 == InstallerEngine.runtimeBundleSHA256)
        #expect(try metadata(in: source) == originalMetadata)
        #expect(try Data(contentsOf: source.appendingPathComponent("Contents/Resources/app.asar")) == originalArchive)
        #expect(try Data(contentsOf: source.appendingPathComponent("Contents/_CodeSignature/CodeResources")) == originalSeal)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent("Contents/Resources/app.asar")) == originalArchive)
        #expect(try Data(contentsOf: fixture.paths.defaultDestination.appendingPathComponent("Contents/_CodeSignature/CodeResources")) == originalSeal)
        #expect(try InstallerEngine.run("/usr/bin/xattr", ["-px", "com.apple.quarantine", fixture.paths.defaultDestination.path]) == quarantine)
        #expect(try InstallerEngine.run("/usr/bin/xattr", ["-px", "dev.yapper.metadata-fixture", fixture.paths.defaultDestination.path]) == custom)
        for (relativePath, name) in attributes where name == "com.apple.FinderInfo" || name == "com.apple.ResourceFork" {
            let file = relativePath.isEmpty ? fixture.paths.defaultDestination : fixture.paths.defaultDestination.appendingPathComponent(relativePath)
            #expect(throws: (any Error).self) { try InstallerEngine.run("/usr/bin/xattr", ["-p", name, file.path]) }
        }
        #expect(try fixture.config()["enabled"] as? Bool == true)
    }

    @Test func `metadata does not hide signed content tampering in a compatible new source`() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let source = try fixture.app("Source", canonical: "0.1.0")
        try addSignedNestedHelper(to: source)
        try addMetadata(to: source)
        let archive = source.appendingPathComponent("Contents/Resources/app.asar")
        let file = try FileHandle(forWritingTo: archive)
        try file.seekToEnd(); try file.write(contentsOf: Data("signed resource tampering".utf8)); try file.close()
        let originalMetadata = try metadata(in: source)
        let tamperedArchive = try Data(contentsOf: archive)

        do {
            try fixture.engine.verifyAppWithMetadata(source, requireYapperCord: true)
            Issue.record("The compatible temporary copy accepted changed signed contents")
        } catch let failure as InstallerFailure {
            #expect(failure.localizedDescription.contains("code-signature verification"))
        }

        do {
            _ = try fixture.engine.install(source: source, destination: fixture.paths.defaultDestination)
            Issue.record("Changed signed contents were accepted as a new source")
        } catch let failure as InstallerFailure {
            #expect(failure.localizedDescription.contains("signature"))
        }

        #expect(try metadata(in: source) == originalMetadata)
        #expect(try Data(contentsOf: archive) == tamperedArchive)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.defaultDestination.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.defaultUserData.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.state.path))
    }
}
