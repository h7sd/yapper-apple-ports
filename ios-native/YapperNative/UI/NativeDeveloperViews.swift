import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct NativeDeveloperView: View {
    let store: NativeStore
    @State private var flags: Set<String>?
    @State private var error: String?
    var body: some View {
        List {
            if NativeDeveloperFixture.enabled { NativeDeveloperFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if let flags {
                NavigationLink { NativeBotDirectoryView(store: store) } label: { Label("Community-Bots", systemImage: "square.grid.2x2") }.accessibilityIdentifier("native.developer.directory")
                if flags.contains("bot_api") {
                    NavigationLink { NativeOwnedBotsView(store: store, flags: flags) } label: { Label("Meine Bots", systemImage: "person.crop.square") }.accessibilityIdentifier("native.developer.bots")
                }
                if flags.contains("oauth") {
                    NavigationLink { NativeOAuthApplicationsView(store: store) } label: { Label("Login mit Yapper", systemImage: "key.horizontal") }.accessibilityIdentifier("native.developer.oauth")
                }
                Section("Dokumentation") {
                    Link("Bot- und OAuth-Dokumentation", destination: URL(string: "https://www.yapin.gg/developers")!).frame(minHeight: 44)
                }
            } else if error == nil { ProgressView("Entwicklerbereich wird geladen …") }
        }
        .navigationTitle("Apps & Bots")
        .task { await load() }
        .yapperNavigation()
    }
    private func load() async {
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { flags = ["bot_api", "oauth", "bot_verified", "bot_rename", "bot_share_add", "private_verify", "custom_activities"]; return }
            #endif
            flags = try await store.withAuthenticatedSession { api, session in try await api.communityFlags(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeOAuthApplicationsView: View {
    let store: NativeStore
    @State private var apps: [NativeOAuthApplication] = []
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var creating = false
    @State private var name = ""
    @State private var secret: NativeDeveloperSecret?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        List {
            if NativeDeveloperFixture.enabled { NativeDeveloperFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if loading && apps.isEmpty { ProgressView("Apps werden geladen …") }
            else if apps.isEmpty && error == nil { ContentUnavailableView("Noch keine Apps", systemImage: "key.horizontal", description: Text("Erstelle eine App, damit sich Menschen auf deiner Website mit Yapper anmelden können.")) }
            ForEach(apps) { app in
                NavigationLink { NativeOAuthApplicationView(store: store, original: app) } label: {
                    HStack(spacing: 12) {
                        NativeAvatar(name: app.name, url: NativeConfiguration.publicAsset(bucket: "icons", path: app.iconPath), size: 42)
                        VStack(alignment: .leading, spacing: 4) { Text(verbatim: app.name).font(OriginalYapper.font(16, weight: .semibold)); Text("\(app.users) Nutzer · \(app.redirectURIs.count) Weiterleitungsadressen").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                    }.frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Login mit Yapper")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Neue App", systemImage: "plus") { creating = true }.disabled(busy || apps.count >= 10) } }
        .alert("Neue App", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Abbrechen", role: .cancel) { name = "" }
            Button("Erstellen") { Task { await create() } }.disabled(!(2...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count))
        } message: { Text("Der Name wird beim Anmelden angezeigt. 2 bis 40 Zeichen.") }
        .sheet(item: $secret) { value in NavigationStack { NativeDeveloperSecretView(secret: value) } }
        .onChange(of: scenePhase) { _, value in if value != .active { secret = nil } }
        .task { await load() }
        .refreshable { await load() }
        .yapperNavigation()
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { apps = []; return }
            #endif
            apps = try await store.withAuthenticatedSession { api, session in try await api.developerOAuthApplications(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func create() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.developerCreateOAuthApplication(name: name, session: session) }
            name = ""; await load()
            guard scenePhase == .active else {
                secret = nil; error = "Die App wurde erstellt. Das Secret wurde beim Verlassen der App verworfen. Setze es in den App-Einstellungen erneut zurück."; return
            }
            secret = NativeDeveloperSecret(label: "Client-Secret für " + result.app.name, value: result.secret)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeOAuthApplicationView: View {
    let store: NativeStore
    @State private var app: NativeOAuthApplication
    @State private var name: String
    @State private var details: String
    @State private var redirects: [String]
    @State private var icon: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    @State private var resetSecret = false
    @State private var removeApp = false
    @State private var secret: NativeDeveloperSecret?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    init(store: NativeStore, original: NativeOAuthApplication) {
        self.store = store; _app = State(initialValue: original); _name = State(initialValue: original.name)
        _details = State(initialValue: original.description); _redirects = State(initialValue: original.redirectURIs.isEmpty ? [""] : original.redirectURIs)
    }
    var body: some View {
        Form {
            if let error { NativeErrorBanner(message: error) }
            Section("App") {
                NativeAvatar(name: app.name, url: NativeConfiguration.publicAsset(bucket: "icons", path: app.iconPath), size: 64).accessibilityHidden(true)
                PhotosPicker(selection: $icon, matching: .images) { Label("App-Symbol auswählen", systemImage: "photo") }.frame(minHeight: 44)
                if app.iconPath != nil { Button("Symbol entfernen", role: .destructive) { Task { await changeIcon("") } }.frame(minHeight: 44) }
                TextField("Name", text: $name)
                TextField("Beschreibung", text: $details, axis: .vertical).lineLimit(3...8)
            }
            Section {
                ForEach(redirects.indices, id: \.self) { index in
                    HStack {
                        TextField("https://deine-seite.example/callback", text: $redirects[index]).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Entfernen", systemImage: "minus.circle", role: .destructive) { redirects.remove(at: index); if redirects.isEmpty { redirects = [""] } }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    if !redirects[index].isEmpty && !NativeDeveloperInput.redirectURI(redirects[index]) { Text("Verwende HTTPS. HTTP ist nur für localhost erlaubt.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.danger) }
                }
                Button("Adresse hinzufügen", systemImage: "plus") { redirects.append("") }.disabled(redirects.count >= 10).frame(minHeight: 44)
            } header: { Text("Weiterleitungsadressen") } footer: { Text("Bis zu 10 Adressen, die beim Login genau übereinstimmen müssen.") }
            Section("Zugangsdaten") {
                LabeledContent("Client-ID", value: app.id).textSelection(.enabled)
                Button("Client-Secret zurücksetzen", systemImage: "arrow.clockwise") { resetSecret = true }.frame(minHeight: 44)
            }
            Section { Button("App endgültig entfernen", role: .destructive) { removeApp = true }.frame(minHeight: 44) }
        }
        .navigationTitle(app.name)
        .disabled(busy)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy) } }
        .confirmationDialog("Client-Secret zurücksetzen?", isPresented: $resetSecret, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { Task { await rotate() } }
        } message: { Text("Das bisherige Secret funktioniert sofort nicht mehr. Bereits ausgestellte Nutzertoken bleiben gültig.") }
        .confirmationDialog("Diese App endgültig entfernen?", isPresented: $removeApp, titleVisibility: .visible) {
            Button("App entfernen", role: .destructive) { Task { await remove() } }
        } message: { Text("Die Client-ID und alle Token dieser App werden ungültig. Die Aktion kann nicht rückgängig gemacht werden.") }
        .sheet(item: $secret) { value in NavigationStack { NativeDeveloperSecretView(secret: value) } }
        .onChange(of: scenePhase) { _, value in if value != .active { secret = nil } }
        .onChange(of: icon) { _, value in if let value { Task { await uploadIcon(value) } } }
        .yapperNavigation()
    }
    private func save(iconPath: String? = nil) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            app = try await store.withAuthenticatedSession { api, session in try await api.developerUpdateOAuthApplication(id: app.id, name: name, description: details, redirectURIs: redirects, iconPath: iconPath, session: session) }
            name = app.name; details = app.description; redirects = app.redirectURIs.isEmpty ? [""] : app.redirectURIs
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func uploadIcon(_ item: PhotosPickerItem) async {
        guard !busy else { return }; busy = true; error = nil
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { busy = false; error = NativeDeveloperFixture.actionMessage; return }
            #endif
            let picked = try await NativeDeveloperImage.read(item, maxBytes: 8 * 1_024 * 1_024)
            let path = try await store.withAuthenticatedSession { api, session in try await api.uploadMedia(bucket: "icons", data: picked.data, filename: "app-icon", contentType: picked.type, session: session) }
            app = try await store.withAuthenticatedSession { api, session in try await api.developerUpdateOAuthIcon(id: app.id, path: path, session: session) }
            busy = false
        } catch is CancellationError { busy = false } catch { busy = false; self.error = error.localizedDescription }
        icon = nil
    }
    private func changeIcon(_ path: String) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            app = try await store.withAuthenticatedSession { api, session in try await api.developerUpdateOAuthIcon(id: app.id, path: path, session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func rotate() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            let value = try await store.withAuthenticatedSession { api, session in try await api.developerRotateOAuthSecret(id: app.id, session: session) }
            guard scenePhase == .active else {
                secret = nil; error = "Das Secret wurde zurückgesetzt und beim Verlassen der App verworfen. Setze es erneut zurück, um einen neuen Wert anzuzeigen."; return
            }
            secret = NativeDeveloperSecret(label: "Neues Client-Secret", value: value)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func remove() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.developerRemoveOAuthApplication(id: app.id, session: session) }; dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeDeveloperSecret: Identifiable { let id = UUID(); let label: String; let value: String }
struct NativeDeveloperSecretView: View {
    let secret: NativeDeveloperSecret
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    var body: some View {
        List {
            Section {
                Text(verbatim: secret.value).font(OriginalYapper.font(15).monospaced()).privacySensitive()
                Button(copied ? "Kopiert" : "Kopieren", systemImage: "doc.on.doc") {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: secret.value]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(90)]); copied = true
                }.frame(minHeight: 44)
            } footer: { Text("Wird nur jetzt angezeigt. Bewahre den Wert auf deinem Server auf. Er wird in dieser App nicht gespeichert.") }
        }
        .navigationTitle(secret.label)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        .yapperNavigation()
    }
}

enum NativeDeveloperFixture {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }
    static let actionMessage = "In der Testansicht werden keine Bots oder Apps geändert."
}
struct NativeDeveloperFixtureNotice: View { var body: some View { Label("Testansicht · Keine echten Bots oder Apps", systemImage: "testtube.2").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) } }
enum NativeDeveloperImage {
    struct Picked: Sendable { let data: Data; let type: String }
    static func read(_ item: PhotosPickerItem, maxBytes: Int) async throws -> Picked {
        guard let data = try await item.loadTransferable(type: Data.self), data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw NativeClientError.invalidResponse }
        if let raw = CGImageSourceGetType(source), let type = UTType(raw as String)?.preferredMIMEType, NativeMediaUploadPolicy.imageTypes.contains(type) { return Picked(data: data, type: type) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4_096]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.9), jpeg.count <= maxBytes else { throw NativeClientError.invalidResponse }
        return Picked(data: jpeg, type: "image/jpeg")
    }
}
