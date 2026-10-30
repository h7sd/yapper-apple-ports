import AppKit
import Foundation
import InstallerCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private enum InstallerOperation: Sendable {
    case install(source: URL, destination: URL, profile: URL, replace: Bool)
    case enable(app: URL, profile: URL, enabled: Bool)
    case restore(destination: URL)
    case inspect(app: URL)
}

@concurrent private func perform(_ operation: InstallerOperation) async throws -> OperationResult {
    let engine = InstallerEngine()
    switch operation {
    case .install(let source, let destination, let profile, let replace):
        return try engine.install(source: source, destination: destination, userData: profile, replaceExisting: replace)
    case .enable(let app, let profile, let enabled):
        return try engine.setEnabled(enabled, app: app, userData: profile)
    case .restore(let destination):
        return try engine.restore(destination: destination)
    case .inspect(let app):
        let inspection = try engine.inspect(app)
        return OperationResult(message: "Compatible Yapper \(inspection.appVersion) · YapperCord \(inspection.yappercordVersion ?? "unknown"). Nested signature and bundle links verified.", destination: app.path)
    }
}

private enum BundledSource {
    static var app: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Yapper.app"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Yapper.app")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct InstallerApplication: App {
    var body: some Scene {
        WindowGroup("YapperCord Installer") {
            InstallerView().frame(minWidth: 650, minHeight: 620)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

private struct InstallerView: View {
    @State private var source = BundledSource.app?.path ?? ""
    @State private var destination = InstallerPaths().defaultDestination.path
    @State private var profile = InstallerPaths().defaultUserData.path
    @State private var replace = false
    @State private var busy = false
    @State private var status = "Choose a compatible Yapper build to install. Existing app data stays in its profile."
    @State private var recoveryDirectory: String?
    @State private var showRestoreConfirmation = false
    private let logger = Logger(subsystem: "website.yapper.yappercord.installer", category: "operations")

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 36)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("YapperCord Installer").font(.largeTitle.bold())
                    Text("Built-in plugins for Yapper · \(InstallerEngine.version)").foregroundStyle(.secondary)
                }
            }
            Text("Install a compatible Yapper build, then enable its bundled plugin runtime. The app is validated before it replaces anything.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Compatible Yapper build") {
                pathRow(value: $source, placeholder: "Choose Yapper.app", action: chooseSource)
                    .padding(8)
            }
            GroupBox("Install destination") {
                VStack(alignment: .leading, spacing: 12) {
                    pathRow(value: $destination, placeholder: "Destination Yapper.app", action: chooseDestination)
                    Toggle("Allow replacement after creating a recovery backup", isOn: $replace)
                    Text("Quit Yapper and its background helpers first. No administrator access is requested.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            DisclosureGroup("Yapper profile") {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow(value: $profile, placeholder: "Yapper profile folder", action: chooseProfile)
                    Text("Use the default for standard Yapper launches. Change this only if you use a custom --user-data-dir. Only yappercord.json is changed; plugin settings are retained.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            HStack {
                Button("Validate build") { run(.inspect(app: url(source))) }.disabled(source.isEmpty)
                Spacer()
                Button("Install & enable") { run(.install(source: url(source), destination: url(destination), profile: url(profile), replace: replace)) }
                    .buttonStyle(.borderedProminent).disabled(source.isEmpty || destination.isEmpty)
            }
            Divider()
            HStack {
                Button("Enable installed app") { run(.enable(app: url(destination), profile: url(profile), enabled: true)) }
                Button("Disable") { run(.enable(app: url(destination), profile: url(profile), enabled: false)) }
                Spacer()
                Button("Restore / uninstall…") { showRestoreConfirmation = true }
            }
            VStack(alignment: .leading, spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let recoveryDirectory {
                    Button("Show recovery copies") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recoveryDirectory)
                    }.font(.caption)
                }
                Text("No downloads. No changes inside signed app bundles. Local ad-hoc signatures do not identify a trusted publisher.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        }
        .padding(28)
        .disabled(busy)
        .confirmationDialog("Restore the previous app?", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("Restore / uninstall") { run(.restore(destination: url(destination))) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("YapperCord will be disabled. The installer restores the app it backed up, or removes its installed copy from the destination if no prior app existed. Recovery copies and plugin settings are kept.")
        }
    }

    private func pathRow(value: Binding<String>, placeholder: String, action: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: value).textFieldStyle(.roundedBorder)
            Button("Choose…", action: action)
        }
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a compatible Yapper.app containing YapperCord \(InstallerEngine.version)."
        if panel.runModal() == .OK, let selected = panel.url { source = selected.path }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Yapper.app"
        panel.directoryURL = url(destination).deletingLastPathComponent()
        panel.message = "Choose where the compatible Yapper app will be copied."
        if panel.runModal() == .OK, let selected = panel.url { destination = selected.path }
    }

    private func chooseProfile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = url(profile)
        if panel.runModal() == .OK, let selected = panel.url { profile = selected.path }
    }

    private func url(_ string: String) -> URL {
        URL(fileURLWithPath: (string as NSString).expandingTildeInPath).standardizedFileURL
    }

    private func run(_ operation: InstallerOperation) {
        busy = true
        recoveryDirectory = nil
        status = "Validating the selected paths and signed app…"
        Task {
            defer { busy = false }
            do {
                let result = try await perform(operation)
                status = result.message
                recoveryDirectory = result.recoveryDirectory
            } catch {
                logger.error("Installer operation failed: \(error.localizedDescription, privacy: .private)")
                status = error.localizedDescription
            }
        }
    }
}

private enum InstallerCLI {
    static func run(_ arguments: [String]) -> Int32 {
        do {
            guard let command = arguments.first else { return 0 }
            if ["help", "--help", "-h"].contains(command) { print(help); return 0 }
            if ["version", "--version"].contains(command) { print(InstallerEngine.version); return 0 }
            var options: [String: String] = [:]
            var replace = false
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                if key == "--replace" { replace = true; index += 1; continue }
                guard ["--source", "--destination", "--app", "--user-data"].contains(key), index + 1 < arguments.count, options[key] == nil else {
                    throw InstallerFailure.invalid("Unknown, duplicate, or incomplete option: \(key)")
                }
                options[key] = arguments[index + 1]
                index += 2
            }
            func url(_ key: String, fallback: URL? = nil) throws -> URL {
                if let value = options[key], !value.isEmpty { return URL(fileURLWithPath: (value as NSString).expandingTildeInPath).standardizedFileURL }
                if let fallback { return fallback }
                throw InstallerFailure.invalid("Provide \(key) with an explicit local path.")
            }
            let engine = InstallerEngine()
            let profile = try url("--user-data", fallback: engine.paths.defaultUserData)
            switch command {
            case "inspect": try output(engine.inspect(url("--app")))
            case "install":
                let source = try url("--source", fallback: BundledSource.app)
                try output(engine.install(source: source, destination: url("--destination", fallback: engine.paths.defaultDestination), userData: profile, replaceExisting: replace))
            case "enable", "disable":
                try output(engine.setEnabled(command == "enable", app: url("--app"), userData: profile))
            case "restore", "uninstall":
                try output(engine.restore(destination: url("--destination", fallback: engine.paths.defaultDestination)))
            default: throw InstallerFailure.invalid("Unknown command: \(command). Run --help.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 2
        }
    }

    private static func output(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static let help = """
    YapperCord Installer \(InstallerEngine.version)
    With no arguments, opens the native installer.

    inspect --app /path/Yapper.app
    install --source /path/compatible/Yapper.app [--destination ~/Applications/Yapper.app] [--replace]
    enable --app /path/Yapper.app [--user-data /path/to/Yapper-profile]
    disable --app /path/Yapper.app [--user-data /path/to/Yapper-profile]
    restore|uninstall [--destination ~/Applications/Yapper.app]

    install can omit --source only when a compatible Yapper.app is bundled or adjacent.
    Replacement always requires --replace and creates a recovery backup.
    All commands refuse to change a running target app. No administrator access or network downloads.
    """
}

@main struct InstallerLauncher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty { InstallerApplication.main() }
        else { Darwin.exit(InstallerCLI.run(arguments)) }
    }
}
