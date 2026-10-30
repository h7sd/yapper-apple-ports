import CryptoKit
import CoreFoundation
import Darwin
import Foundation

public enum InstallerFailure: Error, LocalizedError, Sendable {
    case invalid(String)
    case running(String)
    case command(String)
    case recovery(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .running(let message), .command(let message), .recovery(let message): message
        }
    }
}

public struct InstallerPaths: Sendable {
    public let home: URL
    public let globalApplications: URL
    public var defaultDestination: URL { home.appendingPathComponent("Applications/Yapper.app") }
    public var defaultUserData: URL { home.appendingPathComponent("Library/Application Support/Yapper") }
    public var state: URL { home.appendingPathComponent("Library/Application Support/YapperCord Installer") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, globalApplications: URL = URL(fileURLWithPath: "/Applications")) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.globalApplications = globalApplications.resolvingSymlinksInPath().standardizedFileURL
    }
}

public struct AppInspection: Codable, Sendable {
    public let path: String
    public let appVersion: String
    public let yappercordVersion: String?
    public let asarSHA256: String
    public let runtimeBundleSHA256: String?
}

public struct OperationResult: Codable, Sendable {
    public let message: String
    public let destination: String
    public let recoveryDirectory: String?

    public init(message: String, destination: String, recoveryDirectory: String? = nil) {
        self.message = message
        self.destination = destination
        self.recoveryDirectory = recoveryDirectory
    }
}

private struct Receipt: Codable {
    let schemaVersion: Int
    let transaction: String
    let destination: String
    let userData: String
    let expectedASAR: String
    let hadPreviousApp: Bool
    let previousASAR: String?
    let previousConfig: Data?
    let enabledConfigSHA256: String
    var phase: String
}

private struct OperationLock: Codable {
    let pid: Int32
    let token: String
}

public struct InstallerEngine: Sendable {
    public static let version = "0.1.0"
    public static let runtimeBundleSHA256 = "e87ad714ad8cafb088870dcdf41d78247f415cbc29311242be2cdf676cc57bba"
    public let paths: InstallerPaths
    private let runningExecutables: @Sendable () throws -> [String]

    public init(paths: InstallerPaths = InstallerPaths(), runningExecutables: @escaping @Sendable () throws -> [String] = InstallerEngine.systemRunningExecutables) {
        self.paths = paths
        self.runningExecutables = runningExecutables
    }

    public func inspect(_ app: URL, requireYapperCord: Bool = true) throws -> AppInspection {
        let app = app.standardizedFileURL
        try requireAppPath(app)
        try validatePortableLinks(app)
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "website.yapper.desktop",
              info["CFBundleExecutable"] as? String == "Yapper" else {
            throw InstallerFailure.invalid("Choose a Yapper.app with bundle identifier website.yapper.desktop.")
        }
        _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let asar = app.appendingPathComponent("Contents/Resources/app.asar")
        let manifest = try ASARManifest.read(from: asar)
        guard manifest["productName"] as? String == "Yapper" else {
            throw InstallerFailure.invalid("This app does not use the expected Yapper application profile.")
        }
        let cordVersion = manifest["yappercordVersion"] as? String
        if requireYapperCord && cordVersion != Self.version {
            throw InstallerFailure.invalid("This installer needs a Yapper build containing YapperCord \(Self.version). It does not patch older apps.")
        }
        var runtimeHash: String?
        if requireYapperCord {
            let bundle = try ASARManifest.file("yappercord/bundle.js", from: asar, limit: 16_777_216)
            let checksum = try ASARManifest.file("yappercord/bundle.sha256", from: asar, limit: 256)
            let declared = String(decoding: checksum, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)
            runtimeHash = Self.hash(bundle)
            guard runtimeHash == Self.runtimeBundleSHA256, declared == runtimeHash else {
                throw InstallerFailure.invalid("The built-in YapperCord bundle does not match this installer's reviewed 0.1.0 checksum.")
            }
        }
        return AppInspection(path: app.path, appVersion: manifest["version"] as? String ?? "unknown", yappercordVersion: cordVersion, asarSHA256: try Self.hashFile(asar), runtimeBundleSHA256: runtimeHash)
    }

    public func install(source: URL, destination: URL, userData: URL? = nil, replaceExisting: Bool = false) throws -> OperationResult {
        let source = source.standardizedFileURL
        let destination = try destinationPath(destination)
        let userData = try profilePath(userData ?? paths.defaultUserData)
        guard source != destination else {
            throw InstallerFailure.invalid("Source and destination are the same app. Use Enable for this existing compatible app.")
        }
        let inspected = try inspect(source)
        try refuseRunning([source, destination])
        return try withLock(destination) {
            let manager = FileManager.default
            let receiptURL = self.receiptURL(destination)
            guard !manager.fileExists(atPath: receiptURL.path) else {
                throw InstallerFailure.recovery("A prior installation receipt exists. Restore that installation before installing again.")
            }
            let prior: AppInspection?
            if manager.fileExists(atPath: destination.path) {
                guard replaceExisting else { throw InstallerFailure.invalid("Destination already exists. Explicitly allow replacement with a backup, or choose another destination.") }
                prior = try inspect(destination, requireYapperCord: false)
            } else { prior = nil }
            let config = userData.appendingPathComponent("yappercord.json")
            let oldConfig = try existingConfig(config)
            let newConfig = try configData(oldConfig, enabled: true)
            let transaction = UUID().uuidString
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".YapperCord-stage-\(transaction).app")
            let backup = backupDirectory(destination, transaction: transaction)
            try rejectSymlinkAncestors(backup)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rejectSymlinkAncestors(destination.deletingLastPathComponent())
            _ = try Self.run("/usr/bin/ditto", ["--rsrc", "--extattr", "--qtn", source.path, stage.path])
            var hasReceipt = false
            defer { if !hasReceipt { try? manager.removeItem(at: stage) } }
            let staged = try inspect(stage)
            guard staged.asarSHA256 == inspected.asarSHA256 else { throw InstallerFailure.invalid("Staged app differs from the selected source.") }
            try refuseRunning([source, destination])
            if let prior {
                guard try inspect(destination, requireYapperCord: false).asarSHA256 == prior.asarSHA256 else {
                    throw InstallerFailure.invalid("Destination changed during preparation. Nothing was replaced.")
                }
            } else if manager.fileExists(atPath: destination.path) {
                throw InstallerFailure.invalid("Destination appeared during preparation. Nothing was replaced.")
            }
            var receipt = Receipt(schemaVersion: 1, transaction: transaction, destination: destination.path, userData: userData.path, expectedASAR: inspected.asarSHA256,
                                  hadPreviousApp: prior != nil, previousASAR: prior?.asarSHA256, previousConfig: oldConfig, enabledConfigSHA256: Self.hash(newConfig), phase: "prepared")
            try writeReceipt(receipt, to: receiptURL)
            hasReceipt = true
            do {
                try manager.createDirectory(at: backup, withIntermediateDirectories: true)
                if prior != nil {
                    try manager.moveItem(at: destination, to: backup.appendingPathComponent("previous.app"))
                    receipt.phase = "backed-up"
                    try writeReceipt(receipt, to: receiptURL)
                }
                try manager.moveItem(at: stage, to: destination)
                receipt.phase = "copied"
                try writeReceipt(receipt, to: receiptURL)
                try writeConfig(newConfig, to: config)
                receipt.phase = "installed"
                try writeReceipt(receipt, to: receiptURL)
                return OperationResult(message: "Installed Yapper and enabled its built-in YapperCord runtime. Plugin settings were preserved.", destination: destination.path, recoveryDirectory: backup.path)
            } catch {
                do {
                    try rollback(receipt, destination: destination)
                    hasReceipt = false
                    throw InstallerFailure.recovery("Installation failed and was rolled back: \(error.localizedDescription)")
                } catch let rollbackError as InstallerFailure {
                    if case .recovery(let message) = rollbackError, message.hasPrefix("Installation failed and was rolled back:") { throw rollbackError }
                    throw InstallerFailure.recovery("Installation was interrupted. Use Restore to recover. \(rollbackError.localizedDescription)")
                } catch {
                    throw InstallerFailure.recovery("Installation was interrupted. Use Restore to recover. \(error.localizedDescription)")
                }
            }
        }
    }

    public func setEnabled(_ enabled: Bool, app: URL, userData: URL? = nil) throws -> OperationResult {
        let app = app.standardizedFileURL
        _ = try inspect(app)
        try refuseRunning([app])
        let profile = try profilePath(userData ?? paths.defaultUserData)
        return try withLock(app) {
            let config = profile.appendingPathComponent("yappercord.json")
            try writeConfig(configData(existingConfig(config), enabled: enabled), to: config)
            return OperationResult(message: enabled ? "YapperCord is enabled. Open Yapper to use it." : "YapperCord is disabled. Plugin settings were preserved.", destination: app.path)
        }
    }

    public func restore(destination: URL) throws -> OperationResult {
        let destination = try destinationPath(destination)
        try refuseRunning([destination])
        return try withLock(destination) {
            let manager = FileManager.default
            let receiptURL = self.receiptURL(destination)
            var receipt = try readReceipt(receiptURL, destination: destination)
            if receipt.phase != "installed" {
                try rollback(receipt, destination: destination)
                return OperationResult(message: "Recovered the interrupted installation and restored its prior state.", destination: destination.path)
            }
            let backup = backupDirectory(destination, transaction: receipt.transaction)
            let previous = backup.appendingPathComponent("previous.app")
            if receipt.hadPreviousApp {
                guard try inspect(previous, requireYapperCord: false).asarSHA256 == receipt.previousASAR else { throw InstallerFailure.recovery("The previous app backup has changed. Nothing was removed.") }
            }
            guard try inspect(destination).asarSHA256 == receipt.expectedASAR else {
                throw InstallerFailure.recovery("Installed app changed after installation. Use Disable to preserve the new app; Restore will not overwrite it.")
            }
            let configURL = try profilePath(URL(fileURLWithPath: receipt.userData)).appendingPathComponent("yappercord.json")
            let disabled = try configData(existingConfig(configURL), enabled: false)
            let removed = backup.appendingPathComponent("removed-Yapper.app")
            guard !manager.fileExists(atPath: removed.path) else { throw InstallerFailure.recovery("A recovery copy already exists. Inspect the backup folder before continuing.") }
            receipt.phase = "restoring"
            try writeReceipt(receipt, to: receiptURL)
            try manager.moveItem(at: destination, to: removed)
            do {
                if receipt.hadPreviousApp { try manager.moveItem(at: previous, to: destination) }
                try writeConfig(disabled, to: configURL)
                let archived = backup.appendingPathComponent("receipt.json")
                try writeReceipt(receipt, to: archived)
                try manager.removeItem(at: receiptURL)
            } catch {
                if receipt.hadPreviousApp && manager.fileExists(atPath: destination.path) { try? manager.moveItem(at: destination, to: previous) }
                if !manager.fileExists(atPath: destination.path) { try? manager.moveItem(at: removed, to: destination) }
                throw InstallerFailure.recovery("Restore could not finish; the installed app was kept where possible. \(error.localizedDescription)")
            }
            return OperationResult(message: receipt.hadPreviousApp ? "Restored the previous app and disabled YapperCord. Plugin settings and recovery copies were kept." : "Removed the installed app from its destination and disabled YapperCord. A recovery copy and plugin settings were kept.", destination: destination.path, recoveryDirectory: backup.path)
        }
    }

    private func rollback(_ receipt: Receipt, destination: URL) throws {
        let manager = FileManager.default
        let backup = backupDirectory(destination, transaction: receipt.transaction)
        let previous = backup.appendingPathComponent("previous.app")
        if manager.fileExists(atPath: destination.path) {
            let current = try inspect(destination, requireYapperCord: false)
            if current.asarSHA256 == receipt.expectedASAR {
                let recovered = backup.appendingPathComponent("interrupted-Yapper.app")
                try manager.createDirectory(at: backup, withIntermediateDirectories: true)
                guard !manager.fileExists(atPath: recovered.path) else { throw InstallerFailure.recovery("A prior recovery copy must be reviewed first.") }
                try manager.moveItem(at: destination, to: recovered)
            } else if current.asarSHA256 != receipt.previousASAR {
                throw InstallerFailure.recovery("Destination changed during recovery. It was left untouched.")
            }
        }
        if manager.fileExists(atPath: previous.path) {
            guard !manager.fileExists(atPath: destination.path) else { throw InstallerFailure.recovery("Destination is occupied; the previous app remains in its backup folder.") }
            guard try inspect(previous, requireYapperCord: false).asarSHA256 == receipt.previousASAR else { throw InstallerFailure.recovery("Backup integrity check failed.") }
            try manager.moveItem(at: previous, to: destination)
        }
        let config = try profilePath(URL(fileURLWithPath: receipt.userData)).appendingPathComponent("yappercord.json")
        if receipt.phase == "restoring" {
            try writeConfig(configData(existingConfig(config), enabled: false), to: config)
        } else if let current = try existingConfig(config), Self.hash(current) == receipt.enabledConfigSHA256 {
            if let old = receipt.previousConfig { try writeConfig(old, to: config) }
            else { try manager.removeItem(at: config) }
        }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".YapperCord-stage-\(receipt.transaction).app")
        if manager.fileExists(atPath: stage.path) {
            guard try inspect(stage).asarSHA256 == receipt.expectedASAR else { throw InstallerFailure.recovery("Staging app changed and was left untouched.") }
            try manager.removeItem(at: stage)
        }
        try manager.removeItem(at: receiptURL(destination))
    }

    private func destinationPath(_ value: URL) throws -> URL {
        let destination = value.standardizedFileURL
        try requireAppPath(destination)
        let inHome = contains(destination, in: paths.home)
        let inApplications = destination.deletingLastPathComponent() == paths.globalApplications
        guard inHome || inApplications else { throw InstallerFailure.invalid("Choose an app destination inside your home folder or directly in /Applications. The installer never requests administrator access.") }
        guard !destination.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else { throw InstallerFailure.invalid("An app cannot be installed inside another app bundle.") }
        return destination
    }

    private func profilePath(_ value: URL) throws -> URL {
        let profile = value.standardizedFileURL
        guard profile.isFileURL, contains(profile, in: paths.home), !profile.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw InstallerFailure.invalid("The Yapper profile must be a folder inside your home directory, outside app bundles.")
        }
        try rejectSymlinkAncestors(profile)
        try rejectSymlinkAncestors(profile.appendingPathComponent("yappercord.json"))
        return profile
    }

    private func requireAppPath(_ app: URL) throws {
        guard app.isFileURL, app.pathExtension.lowercased() == "app", app.lastPathComponent != ".app" else { throw InstallerFailure.invalid("Choose a local .app bundle.") }
        try rejectSymlinkAncestors(app)
    }

    private func rejectSymlinkAncestors(_ value: URL) throws {
        var cursor = URL(fileURLWithPath: "/")
        for component in value.standardizedFileURL.pathComponents.dropFirst() {
            cursor.appendPathComponent(component)
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // Foundation normalizes these protected macOS root aliases back
                // to /var, /tmp, and /etc even after resolvingSymlinksInPath().
                if ["/var", "/tmp", "/etc"].contains(cursor.path),
                   let target = try? FileManager.default.destinationOfSymbolicLink(atPath: cursor.path),
                   ["/private" + cursor.path, "private" + cursor.path].contains(target) {
                    continue
                }
                throw InstallerFailure.invalid("A selected path passes through a symbolic link. Choose its real location instead.")
            }
        }
    }

    private func validatePortableLinks(_ app: URL) throws {
        guard let entries = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw InstallerFailure.invalid("App bundle cannot be read.") }
        for case let entry as URL in entries {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                let resolved = entry.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
                guard !target.hasPrefix("/"), contains(resolved, in: app), FileManager.default.fileExists(atPath: entry.path) else {
                    throw InstallerFailure.invalid("App contains an absolute, escaping, or broken symbolic link. Obtain a fresh compatible build.")
                }
            }
        }
    }

    private func refuseRunning(_ apps: [URL]) throws {
        let executables = try runningExecutables()
        for app in apps {
            let prefix = app.path + "/Contents/"
            if executables.contains(where: { $0.hasPrefix(prefix) }) { throw InstallerFailure.running("Quit \(app.lastPathComponent), including its background helpers, before changing it.") }
        }
    }

    private func existingConfig(_ url: URL) throws -> Data? {
        try rejectSymlinkAncestors(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 1_048_576 else { throw InstallerFailure.invalid("YapperCord settings exceed the 1 MiB safety limit.") }
        let data = try Data(contentsOf: url)
        _ = try configData(data, enabled: false)
        return data
    }

    private func configData(_ old: Data?, enabled: Bool) throws -> Data {
        var object: [String: Any] = [:]
        if let old {
            guard let parsed = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw InstallerFailure.invalid("Existing YapperCord settings are not a JSON object; they were left untouched.") }
            object = parsed
            if let schema = object["schemaVersion"] {
                guard let number = schema as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == 1 else {
                    throw InstallerFailure.invalid("Settings use an unsupported schema; they were left untouched.")
                }
            }
        }
        object["schemaVersion"] = 1
        object["enabled"] = enabled
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private func writeConfig(_ data: Data, to url: URL) throws {
        try rejectSymlinkAncestors(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func contains(_ child: URL, in parent: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path + "/")
    }

    private func identifier(_ destination: URL) -> String { Self.hash(Data(destination.path.utf8)) }
    private func receiptURL(_ destination: URL) -> URL { paths.state.appendingPathComponent("Receipts/\(identifier(destination)).json") }
    private func backupDirectory(_ destination: URL, transaction: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".YapperCord-Backups/\(identifier(destination))/\(transaction)")
    }

    private func writeReceipt(_ value: Receipt, to url: URL) throws {
        try rejectSymlinkAncestors(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readReceipt(_ url: URL, destination: URL) throws -> Receipt {
        try rejectSymlinkAncestors(url)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 2_097_152 else { throw InstallerFailure.recovery("Installation receipt exceeds its safety limit.") }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard receipt.schemaVersion == 1, receipt.destination == destination.path, UUID(uuidString: receipt.transaction) != nil,
              ["prepared", "backed-up", "copied", "installed", "restoring"].contains(receipt.phase) else { throw InstallerFailure.recovery("Installation receipt is invalid. No app was changed.") }
        _ = try profilePath(URL(fileURLWithPath: receipt.userData))
        try rejectSymlinkAncestors(backupDirectory(destination, transaction: receipt.transaction))
        return receipt
    }

    private func withLock<T>(_ destination: URL, action: () throws -> T) throws -> T {
        try rejectSymlinkAncestors(paths.state)
        let locks = paths.state.appendingPathComponent("Locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.state.path)
        let lockURL = locks.appendingPathComponent("\(identifier(destination)).json")
        try rejectSymlinkAncestors(lockURL)
        if FileManager.default.fileExists(atPath: lockURL.path) {
            let owner = try JSONDecoder().decode(OperationLock.self, from: Data(contentsOf: lockURL))
            guard owner.pid > 0, kill(owner.pid, 0) != 0, errno == ESRCH else { throw InstallerFailure.running("Another installer operation is active. Wait for it to finish.") }
            try FileManager.default.removeItem(at: lockURL)
        }
        let lock = OperationLock(pid: getpid(), token: UUID().uuidString)
        try JSONEncoder().encode(lock).write(to: lockURL, options: [.withoutOverwriting])
        defer { try? FileManager.default.removeItem(at: lockURL) }
        return try action()
    }

    public static func systemRunningExecutables() throws -> [String] {
        try run("/bin/ps", ["-axo", "comm="]).split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallerFailure.command("\(URL(fileURLWithPath: executable).lastPathComponent) could not validate or copy the selected app (exit \(process.terminationStatus)). No signature or security checks were bypassed.") }
        return String(decoding: data, as: UTF8.self)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum ASARManifest {
    static func read(from url: URL) throws -> [String: Any] {
        guard let manifest = try JSONSerialization.jsonObject(with: file("package.json", from: url, limit: 1_048_576)) as? [String: Any] else { throw InstallerFailure.invalid("Application manifest is invalid.") }
        return manifest
    }

    static func file(_ member: String, from url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 8), prefix.count == 8 else { throw InstallerFailure.invalid("ASAR header is truncated.") }
        let size = UInt64(littleEndian32(prefix, at: 4))
        guard littleEndian32(prefix, at: 0) == 4, size >= 8, size <= 16_777_216, size <= total - min(total, 8) else { throw InstallerFailure.invalid("ASAR header size is invalid.") }
        guard let header = try handle.read(upToCount: Int(size)), header.count == Int(size) else { throw InstallerFailure.invalid("ASAR header is truncated.") }
        let jsonSize = Int(littleEndian32(header, at: 4))
        guard jsonSize <= header.count - 8, let tree = try JSONSerialization.jsonObject(with: header.subdata(in: 8..<(8 + jsonSize))) as? [String: Any] else { throw InstallerFailure.invalid("ASAR header is invalid.") }
        var node = tree
        for component in member.split(separator: "/") {
            guard component != ".", component != "..", let files = node["files"] as? [String: Any], let child = files[String(component)] as? [String: Any] else { throw InstallerFailure.invalid("Required packed ASAR file is missing: \(member)") }
            node = child
        }
        let entry = node
        guard
              entry["unpacked"] as? Bool != true, entry["link"] == nil,
              let rawOffset = entry["offset"] as? String, let offset = UInt64(rawOffset),
              let length = entry["size"] as? NSNumber, length.doubleValue.rounded() == length.doubleValue,
              length.int64Value > 0, length.int64Value <= limit else { throw InstallerFailure.invalid("ASAR member exceeds its bound or is not packed: \(member)") }
        let contentStart = 8 + size
        guard offset <= total - min(total, contentStart), UInt64(length.int64Value) <= total - contentStart - offset else { throw InstallerFailure.invalid("ASAR manifest is outside the archive.") }
        try handle.seek(toOffset: contentStart + offset)
        guard let data = try handle.read(upToCount: length.intValue), data.count == length.intValue else { throw InstallerFailure.invalid("ASAR member is truncated.") }
        return data
    }

    private static func littleEndian32(_ data: Data, at index: Int) -> UInt32 {
        let bytes = Array(data[index..<(index + 4)])
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
}
