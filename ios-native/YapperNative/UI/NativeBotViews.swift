import SwiftUI
import PhotosUI

struct NativeBotDirectoryView: View {
    let store: NativeStore
    @State private var query = ""
    @State private var category = ""
    @State private var sort = "popular"
    @State private var bots: [NativeDirectoryBot] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            if NativeDeveloperFixture.enabled { NativeDeveloperFixtureNotice() }
            Section {
                Picker("Kategorie", selection: $category) { Text("Alle").tag(""); ForEach(NativeBotCategory.allCases) { Text($0.label).tag($0.rawValue) } }
                Picker("Sortierung", selection: $sort) { Text("Meistgenutzt").tag("popular"); Text("Neueste").tag("new"); Text("Name").tag("name") }
            }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if loading && bots.isEmpty { ProgressView("Bots werden geladen …") }
            else if bots.isEmpty && error == nil { ContentUnavailableView("Keine passenden Bots", systemImage: "magnifyingglass", description: Text("Probiere einen anderen Namen oder eine andere Kategorie.")) }
            ForEach(bots) { bot in
                NavigationLink { NativeDirectoryBotView(store: store, bot: bot) } label: {
                    HStack(spacing: 12) {
                        NativeAvatar(name: bot.name, url: bot.profile?.avatarURL, presence: bot.online ? "online" : "offline", size: 44, decorationURL: bot.profile?.user.avatarDecorationURL, crop: bot.profile?.user.avatarCrop ?? .centered)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: bot.name).font(OriginalYapper.font(16, weight: .semibold))
                            Text(verbatim: bot.description).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).lineLimit(3)
                            Text("\(bot.serverCount) Server · \(bot.commandCount) Befehle").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        }
                    }.frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Community-Bots")
        .searchable(text: $query, prompt: "Bots oder Befehle suchen")
        .task(id: query + "\u{0}" + category + "\u{0}" + sort) { await load(debounce: true) }
        .refreshable { await load() }
        .yapperNavigation()
    }
    private func load(debounce: Bool = false) async {
        let key = query + category + sort; loading = true; error = nil
        defer { if key == query + category + sort { loading = false } }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { bots = []; return }
            #endif
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            let result = try await store.withAuthenticatedSession { api, session in try await api.developerBotDirectory(query: query, category: category, sort: sort, session: session) }
            guard !Task.isCancelled, key == query + category + sort else { return }; bots = result
        } catch is CancellationError {} catch { if key == query + category + sort { self.error = error.localizedDescription } }
    }
}

private struct NativeDirectoryBotView: View {
    let store: NativeStore
    let bot: NativeDirectoryBot
    @State private var showingInstall = false
    var body: some View {
        List {
            Section {
                NativeAvatar(name: bot.name, url: bot.profile?.avatarURL, presence: bot.online ? "online" : "offline", size: 72, crop: bot.profile?.user.avatarCrop ?? .centered)
                Text(verbatim: bot.name).font(OriginalYapper.font(24, weight: .bold))
                if bot.verifiedAt != nil { Label("Von Yapper geprüft", systemImage: "checkmark.seal") }
                Text(verbatim: bot.description)
                if !bot.ownerName.isEmpty { LabeledContent("Entwickelt von", value: bot.ownerName) }
                LabeledContent("Kategorie", value: bot.category.label)
                LabeledContent("Server", value: bot.serverCount.formatted())
                Button("Zu einem Server hinzufügen", systemImage: "plus.circle") { showingInstall = true }.frame(minHeight: 44)
            }
            if !bot.commands.isEmpty {
                Section("Befehle") { ForEach(bot.commands) { command in VStack(alignment: .leading, spacing: 4) { Text("/" + command.name).font(OriginalYapper.font(15).monospaced()); Text(verbatim: command.description).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) } } }
            }
            Text("Bots sehen und schreiben nur auf Servern, auf denen eine berechtigte Person sie hinzugefügt hat.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
        }
        .navigationTitle(bot.name)
        .sheet(isPresented: $showingInstall) { NavigationStack { NativeBotInstallView(store: store, botID: bot.id, name: bot.name) } }
        .yapperNavigation()
    }
}

struct NativeBotInstallView: View {
    let store: NativeStore
    let botID: String
    let name: String
    @State private var targets: [NativeBotInstallTarget] = []
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirming: NativeBotInstallTarget?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if NativeDeveloperFixture.enabled { NativeDeveloperFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if loading { ProgressView("Berechtigte Server werden geladen …") }
            else if targets.isEmpty && error == nil { Text("Du verwaltest noch keinen Server, auf dem dieser Bot hinzugefügt werden kann. Du brauchst dort Server verwalten.").foregroundStyle(YapperPalette.secondary) }
            ForEach(targets) { target in
                HStack {
                    Text(verbatim: target.name)
                    Spacer()
                    if target.added { Label("Hinzugefügt", systemImage: "checkmark") }
                    else { Button("Hinzufügen") { confirming = target }.frame(minHeight: 44).disabled(busy) }
                }
            }
        }
        .navigationTitle(name + " hinzufügen")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() }.disabled(busy) } }
        .confirmationDialog("Diesen Bot hinzufügen?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let target = confirming { Button("Zu " + target.name + " hinzufügen") { Task { await install(target) } } }
        } message: { Text("Der Bot kann auf diesem Server Nachrichten lesen und schreiben. Die Serverberechtigungen werden beim Hinzufügen erneut geprüft.") }
        .task { await load() }
        .yapperNavigation()
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { targets = []; return }
            #endif
            targets = try await store.withAuthenticatedSession { api, session in try await api.developerBotTargets(botID: botID, session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func install(_ target: NativeBotInstallTarget) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.developerInstallBot(botID: botID, serverID: target.id, session: session) }
            confirming = nil; await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeOwnedBotsView: View {
    let store: NativeStore
    let flags: Set<String>
    @State private var bots: [NativeOwnedBot] = []
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
            if loading && bots.isEmpty { ProgressView("Deine Bots werden geladen …") }
            else if bots.isEmpty && error == nil { ContentUnavailableView("Noch keine Bots", systemImage: "person.crop.square", description: Text("Erstelle einen Bot, füge ihn einem Server hinzu und führe ihn auf deinem Rechner aus.")) }
            ForEach(bots) { bot in
                NavigationLink { NativeOwnedBotView(store: store, original: bot, flags: flags) } label: {
                    VStack(alignment: .leading, spacing: 4) { Text(verbatim: bot.name).font(OriginalYapper.font(16, weight: .semibold)); Text(verbatim: bot.description).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).lineLimit(2) }.frame(minHeight: 44)
                }
            }
        }
        .navigationTitle("Meine Bots")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Neuer Bot", systemImage: "plus") { creating = true }.disabled(busy) } }
        .alert("Neuer Bot", isPresented: $creating) {
            TextField("Bot-Name", text: $name).textInputAutocapitalization(.never)
            Button("Abbrechen", role: .cancel) { name = "" }
            Button("Erstellen") { Task { await create() } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("Buchstaben, Zahlen, Punkte und Unterstriche. Der Server prüft dein aktuelles Bot-Limit.") }
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
            if NativeDeveloperFixture.enabled { bots = []; return }
            #endif
            bots = try await store.withAuthenticatedSession { api, session in try await api.developerOwnedBots(flags: flags, session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func create() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.developerCreateBot(name: name, session: session) }
            name = ""; await load()
            guard scenePhase == .active else {
                secret = nil; error = "Der Bot wurde erstellt. Das Token wurde beim Verlassen der App verworfen. Setze es im Bot erneut zurück, um einen neuen Wert anzuzeigen."; return
            }
            secret = NativeDeveloperSecret(label: "Bot-Token", value: result.token)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeOwnedBotView: View {
    let store: NativeStore
    let flags: Set<String>
    @State private var bot: NativeOwnedBot
    @State private var name: String
    @State private var details: String
    @State private var category: NativeBotCategory
    @State private var support: String
    @State private var hook: String
    @State private var busy = false
    @State private var error: String?
    @State private var secret: NativeDeveloperSecret?
    @State private var confirm = ""
    @State private var install = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    init(store: NativeStore, original: NativeOwnedBot, flags: Set<String>) {
        self.store = store; self.flags = flags; _bot = State(initialValue: original); _name = State(initialValue: original.name); _details = State(initialValue: original.description)
        _category = State(initialValue: original.category); _support = State(initialValue: original.supportInvite ?? ""); _hook = State(initialValue: original.webhookURL ?? "")
    }
    var body: some View {
        Form {
            if let error { NativeErrorBanner(message: error) }
            Section("Bot") {
                if flags.contains("bot_rename") { TextField("Benutzername", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("Bot-ID", value: bot.id).textSelection(.enabled)
                TextField("Beschreibung", text: $details, axis: .vertical).lineLimit(3...8)
                Picker("Kategorie", selection: $category) { ForEach(NativeBotCategory.allCases) { Text($0.label).tag($0) } }
                if flags.contains("bot_verified") { TextField("Support-Einladung", text: $support).textInputAutocapitalization(.never).autocorrectionDisabled() }
                NavigationLink { NativeBotProfileView(store: store, id: bot.id, name: bot.name) } label: { Label("Profil, Bild & Banner", systemImage: "person.crop.circle") }
            }
            Section("Server & Befehle") {
                Button("Zu einem Server hinzufügen", systemImage: "plus") { install = true }.frame(minHeight: 44)
                NavigationLink { NativeBotServerListView(store: store, id: bot.id) } label: { Label("Server verwalten", systemImage: "bubble.left.and.bubble.right") }
                NavigationLink { NativeBotCommandsView(store: store, id: bot.id) } label: { Label("Registrierte Befehle", systemImage: "terminal") }
                if flags.contains("custom_activities") { NavigationLink { NativeBotActivitiesView(store: store, id: bot.id) } label: { Label("Aktivitäten verwalten", systemImage: "gamecontroller") } }
            }
            Section("Zugang & Webhook") {
                TextField("Webhook-URL (optional)", text: $hook).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Webhook-Secret anzeigen") { Task { await perform("hook") } }.frame(minHeight: 44)
                Button("Bot-Token zurücksetzen", role: .destructive) { confirm = "token" }.frame(minHeight: 44)
            }
            Section("Community") {
                if let note = bot.reviewNote, !note.isEmpty { Text(verbatim: note).foregroundStyle(YapperPalette.secondary) }
                LabeledContent("Veröffentlichung", value: bot.isPublic ? (bot.verified ? "Veröffentlicht" : "Wird geprüft") : (bot.unlisted ? "Privat" : "Nicht veröffentlicht"))
                if flags.contains("bot_share_add"), !(bot.verified && (bot.isPublic || bot.unlisted)) {
                    Toggle("Serverbesitzer dürfen den Bot hinzufügen", isOn: Binding(get: { bot.shareable }, set: { value in Task { await perform(value ? "share" : "unshare") } }))
                }
                Button(bot.isPublic ? "Aus Community entfernen" : "Zur Veröffentlichung einreichen") { confirm = "publish" }.disabled(!bot.isPublic && bot.description.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count < 20).frame(minHeight: 44)
                if flags.contains("private_verify") { Button(bot.unlisted ? "Private Verifizierung zurückziehen" : "Private Verifizierung beantragen") { confirm = "private" }.disabled(!bot.unlisted && bot.description.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count < 20).frame(minHeight: 44) }
            }
            Section { Button("Bot endgültig löschen", role: .destructive) { confirm = "delete" }.frame(minHeight: 44) }
        }
        .navigationTitle(bot.name)
        .disabled(busy)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy) } }
        .confirmationDialog(confirm == "token" ? "Bot-Token zurücksetzen?" : confirm == "delete" ? "Bot endgültig löschen?" : "Änderung bestätigen?", isPresented: Binding(get: { !confirm.isEmpty }, set: { if !$0 { confirm = "" } }), titleVisibility: .visible) {
            Button(confirm == "delete" ? "Löschen" : "Bestätigen", role: confirm == "delete" || confirm == "token" ? .destructive : nil) { let action = confirm; confirm = ""; Task { await perform(action) } }
        } message: { Text(confirm == "token" ? "Das bisherige Token wird sofort ungültig. Ein gehosteter Bot kann neu starten oder anhalten." : confirm == "delete" ? "Der Bot verlässt alle Server. Sein Token wird ungültig. Die Aktion kann nicht rückgängig gemacht werden." : "Deine letzte gespeicherte Beschreibung wird für die Prüfung verwendet. Der aktuelle Status wird vom Server bestätigt.") }
        .sheet(isPresented: $install) { NavigationStack { NativeBotInstallView(store: store, botID: bot.id, name: bot.name) } }
        .sheet(item: $secret) { value in NavigationStack { NativeDeveloperSecretView(secret: value) } }
        .onChange(of: scenePhase) { _, value in if value != .active { secret = nil } }
        .yapperNavigation()
    }
    private func refresh() async throws {
        let rows = try await store.withAuthenticatedSession { api, session in try await api.developerOwnedBots(flags: flags, session: session) }
        guard let value = rows.first(where: { $0.id == bot.id }) else { throw NativeClientError.invalidResponse }; bot = value
    }
    private func save() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.developerUpdateBot(bot: bot, name: name, description: details, category: category, supportInvite: flags.contains("bot_verified") ? support : nil, webhookURL: hook, session: session) }
            try await refresh()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: String) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }
            #endif
            let value: String? = try await store.withAuthenticatedSession { api, session in
                switch action {
                case "token": return try await api.developerRotateBotToken(id: bot.id, session: session)
                case "hook": return try await api.developerBotWebhookSecret(id: bot.id, session: session)
                case "delete": try await api.developerDeleteBot(id: bot.id, session: session)
                case "share", "unshare": try await api.developerSetBotSharing(id: bot.id, enabled: action == "share", session: session)
                case "publish": try await api.developerSetBotPublication(id: bot.id, published: !bot.isPublic, session: session)
                case "private": try await api.developerSetBotPublication(id: bot.id, published: false, unlisted: !bot.unlisted, session: session)
                default: throw NativeClientError.invalidResponse
                }
                return nil
            }
            if action == "delete" { dismiss(); return }
            try await refresh()
            if let value {
                guard scenePhase == .active else {
                    secret = nil; error = action == "token" ? "Das Bot-Token wurde zurückgesetzt und beim Verlassen der App verworfen. Setze es erneut zurück, um einen neuen Wert anzuzeigen." : "Das Webhook-Secret wurde beim Verlassen der App verworfen. Du kannst es erneut anzeigen lassen."; return
                }
                secret = NativeDeveloperSecret(label: action == "token" ? "Neues Bot-Token" : "Webhook-Secret", value: value)
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeBotCommandsView: View {
    let store: NativeStore
    let id: String
    @State private var commands: [NativeBotCommand] = []
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        List {
            if let error { NativeErrorBanner(message: error) }
            if loading { ProgressView("Befehle werden geladen …") }
            else if commands.isEmpty && error == nil { Text("Der Bot hat noch keine Befehle registriert.").foregroundStyle(YapperPalette.secondary) }
            ForEach(commands) { command in VStack(alignment: .leading, spacing: 4) { Text("/" + command.name).font(OriginalYapper.font(15).monospaced()); Text(verbatim: command.description).foregroundStyle(YapperPalette.secondary) } }
        }.navigationTitle("Befehle").task {
            defer { loading = false }
            do { if NativeDeveloperFixture.enabled { return }; commands = try await store.withAuthenticatedSession { api, session in try await api.developerBotCommands(id: id, session: session) } }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }.yapperNavigation()
    }
}

private struct NativeBotServerListView: View {
    let store: NativeStore
    let id: String
    @State private var servers: [NativeServerTagChoice] = []
    @State private var removing: NativeServerTagChoice?
    @State private var busy = false
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        List {
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if loading { ProgressView("Server werden geladen …") }
            else if servers.isEmpty && error == nil { Text("Noch keinem Server hinzugefügt.").foregroundStyle(YapperPalette.secondary) }
            ForEach(servers) { server in HStack { Text(verbatim: server.name); Spacer(); Button("Entfernen", role: .destructive) { removing = server }.frame(minHeight: 44).disabled(busy) } }
        }
        .navigationTitle("Server")
        .task { await load() }
        .confirmationDialog("Bot von diesem Server entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let server = removing { Button("Von " + server.name + " entfernen", role: .destructive) { Task { await remove(server) } } }
        }.yapperNavigation()
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do { if NativeDeveloperFixture.enabled { servers = []; return }; servers = try await store.withAuthenticatedSession { api, session in try await api.developerBotServers(id: id, session: session) } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func remove(_ server: NativeServerTagChoice) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; try await store.withAuthenticatedSession { api, session in try await api.developerRemoveBotFromServer(botID: id, serverID: server.id, session: session) }; removing = nil; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeBotProfileView: View {
    let store: NativeStore
    let id: String
    let name: String
    @State private var profile: NativeProfileDetail?
    @State private var displayName = ""
    @State private var bio = ""
    @State private var avatar: PhotosPickerItem?
    @State private var banner: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if let profile {
                Section("Profil") {
                    NativeAvatar(name: profile.displayName, url: profile.avatarURL, size: 72)
                    TextField("Anzeigename", text: $displayName)
                    TextField("Bio", text: $bio, axis: .vertical).lineLimit(3...8)
                    Text("\(bio.utf16.count)/300").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                Section("Bilder") {
                    PhotosPicker(selection: $avatar, matching: .images) { Label("Profilbild auswählen", systemImage: "person.crop.circle") }.frame(minHeight: 44)
                    PhotosPicker(selection: $banner, matching: .images) { Label("Banner auswählen", systemImage: "photo") }.frame(minHeight: 44)
                    if let url = profile.bannerURL { NativeRemoteImage(url: url).frame(height: 100) }
                    if profile.avatarURL != nil { Button("Profilbild entfernen", role: .destructive) { Task { await remove("avatar") } }.frame(minHeight: 44) }
                    if profile.bannerURL != nil { Button("Banner entfernen", role: .destructive) { Task { await remove("banner") } }.frame(minHeight: 44) }
                }
            } else if error == nil { ProgressView("Bot-Profil wird geladen …") }
        }
        .navigationTitle(name + " · Profil")
        .disabled(busy)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy || profile == nil) } }
        .task { await load() }
        .onChange(of: avatar) { _, value in if let value { Task { await upload(value, kind: "avatar") } } }
        .onChange(of: banner) { _, value in if let value { Task { await upload(value, kind: "banner") } } }
        .yapperNavigation()
    }
    private func load() async {
        do { if NativeDeveloperFixture.enabled { return }; let rows = try await store.withAuthenticatedSession { api, session in try await api.socialProfiles(ids: [id], session: session) }; guard let profile = rows.first else { throw NativeClientError.invalidResponse }; self.profile = profile; displayName = profile.displayName; bio = profile.bio }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; try await store.withAuthenticatedSession { api, session in try await api.developerUpdateBotProfile(id: id, displayName: displayName, bio: bio, session: session) }; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func upload(_ item: PhotosPickerItem, kind: String) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false; avatar = nil; banner = nil }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; let picked = try await NativeDeveloperImage.read(item, maxBytes: 4 * 1_024 * 1_024); _ = try await store.withAuthenticatedSession { api, session in try await api.developerUploadBotProfileImage(id: id, kind: kind, data: picked.data, contentType: picked.type, session: session) }; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func remove(_ kind: String) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; try await store.withAuthenticatedSession { api, session in try await api.developerRemoveBotProfileImage(id: id, kind: kind, session: session) }; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeBotActivitiesView: View {
    let store: NativeStore
    let id: String
    @State private var activities: [NativeBotActivity] = []
    @State private var editing = false
    @State private var activityID: String?
    @State private var name = ""
    @State private var url = "https://"
    @State private var emoji = ""
    @State private var details = ""
    @State private var removing: NativeBotActivity?
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Form {
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            ForEach(activities) { activity in
                Section {
                    Text(verbatim: activity.emoji + " " + activity.name).font(OriginalYapper.font(16, weight: .semibold))
                    Text(verbatim: activity.url).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary).textSelection(.enabled)
                    Button("Bearbeiten") { activityID = activity.id; name = activity.name; url = activity.url; emoji = activity.emoji; details = activity.description; editing = true }.frame(minHeight: 44)
                    Button("Entfernen", role: .destructive) { removing = activity }.frame(minHeight: 44)
                }
            }
            if editing {
                Section("Aktivität") {
                    TextField("Name", text: $name)
                    TextField("HTTPS-Adresse", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Emoji (optional)", text: $emoji)
                    TextField("Beschreibung", text: $details, axis: .vertical)
                    Button("Speichern") { Task { await save() } }.frame(minHeight: 44)
                    Button("Abbrechen", role: .cancel) { editing = false }.frame(minHeight: 44)
                }
            } else if activities.count < 5 {
                Button("Aktivität hinzufügen", systemImage: "plus") { activityID = nil; name = ""; url = "https://"; emoji = ""; details = ""; editing = true }.frame(minHeight: 44)
            }
            Text("Ein Websitewechsel erfordert eine erneute Freigabe auf betroffenen Servern. Das Ausführen eingebetteter Web-Aktivitäten ist separat dokumentiert.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
        }
        .navigationTitle("Aktivitäten")
        .disabled(busy)
        .task { await load() }
        .confirmationDialog("Aktivität entfernen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let activity = removing { Button("Entfernen", role: .destructive) { Task { await remove(activity) } } }
        } message: { Text("In laufenden Anrufen kann diese Aktivität danach nicht mehr geladen werden.") }
        .yapperNavigation()
    }
    private func load() async {
        do { if NativeDeveloperFixture.enabled { activities = []; return }; activities = try await store.withAuthenticatedSession { api, session in try await api.developerBotActivities(id: id, session: session) } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; try await store.withAuthenticatedSession { api, session in try await api.developerSaveActivity(botID: id, activityID: activityID, name: name, url: url, emoji: emoji, description: details, session: session) }; editing = false; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func remove(_ value: NativeBotActivity) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do { if NativeDeveloperFixture.enabled { error = NativeDeveloperFixture.actionMessage; return }; try await store.withAuthenticatedSession { api, session in try await api.developerRemoveActivity(id: value.id, session: session) }; removing = nil; await load() }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
