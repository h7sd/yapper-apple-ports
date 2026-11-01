import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct NativeServerToolsView: View {
    let model: NativeServerDetailModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Community") {
                    NavigationLink { NativeServerToolList(model: model, tool: .events) } label: { Label("Ereignisse", systemImage: "calendar") }
                    NavigationLink { NativeServerSupportView(model: model) } label: { Label("Tickets und Beitritt", systemImage: "ticket") }
                }
                Section("Verwaltung") {
                    if model.allows("manage_roles") { NavigationLink { NativeEveryonePermissionView(model: model) } label: { Label("Standardberechtigungen", systemImage: "person.3.sequence") } }
                    ForEach(NativeServerTool.allCases.filter { $0 != .events && available($0) }) { tool in
                        NavigationLink { NativeServerToolList(model: model, tool: tool) } label: { Label(tool.title, systemImage: tool.icon) }
                    }
                    if model.allows("manage_server") { NavigationLink { NativeServerBrandingView(model: model) } label: { Label("Serverprofil und Darstellung", systemImage: "paintpalette") } }
                }
            }
            .navigationTitle("Serverfunktionen")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .yapperNavigation()
        }
    }

    private func available(_ tool: NativeServerTool) -> Bool {
        guard let permission = tool.permission else { return true }
        return model.allows(permission) || ((tool == .requests || tool == .audit) && model.allows("manage_server"))
    }
}

private struct NativeServerToolList: View {
    let model: NativeServerDetailModel
    let tool: NativeServerTool
    @State private var records: [NativeServerToolRecord] = []
    @State private var loading = false
    @State private var busy = false
    @State private var more = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var channelID = ""
    @State private var auditAction = ""
    @State private var auditActor = ""
    @State private var knownActions: Set<String> = []
    @State private var adding = false
    @State private var editing: NativeServerToolRecord?
    @State private var deleting: NativeServerToolRecord?
    @State private var declining: NativeServerToolRecord?
    @State private var composing: NativeServerToolRecord?
    @State private var secret: NativeServerShareValue?
    @State private var pendingSecret: NativeServerShareValue?
    @State private var rotating: NativeServerToolRecord?

    private var canCreate: Bool { tool == .events ? model.allows("manage_events") : [.emojis, .webhooks, .templates].contains(tool) }
    private var loadIdentity: String { [channelID, auditAction, auditActor].joined(separator: "|") }

    var body: some View {
        list
            .navigationTitle(tool.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canCreate { ToolbarItem(placement: .topBarTrailing) { Button { if tool == .templates { createTemplate() } else { adding = true } } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("\(tool.title): hinzufügen").disabled(busy) } }
            }
            .task(id: loadIdentity) { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $adding, onDismiss: { secret = pendingSecret; pendingSecret = nil }) { creationSheet }
            .sheet(item: $editing) { record in editSheet(record) }
            .sheet(item: $declining) { record in
                NativeServerTextSheet(title: "Anfrage ablehnen", field: "Nachricht an die Person (optional)", submit: "Ablehnen", allowsEmpty: true) { text in
                    try await model.store.withAuthenticatedSession { api, session in try await api.nativeDecideJoinRequest(id: record.id, accept: false, note: text, session: session) }
                    await load()
                }
            }
            .sheet(item: $composing) { record in NativeWebhookPostEditor(model: model, webhook: record) }
            .sheet(item: $secret) { value in NativeServerShareSheet(value: value) }
            .confirmationDialog(tool == .events ? "Ereignis absagen?" : tool == .bans ? "Sperre aufheben?" : "Diesen Eintrag löschen?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                if let record = deleting { Button(tool == .bans ? "Sperre aufheben" : tool == .events ? "Absagen" : "Löschen", role: .destructive) { remove(record) } }
            }
            .confirmationDialog("Webhook-Link erneuern?", isPresented: Binding(get: { rotating != nil }, set: { if !$0 { rotating = nil } }), titleVisibility: .visible) { if let record = rotating { Button("Link erneuern", role: .destructive) { rotate(record) } } } message: { Text("Der bisherige Link funktioniert danach nicht mehr.") }
            .onAppear { if tool == .webhooks && channelID.isEmpty { channelID = model.snapshot?.channels.first(where: { $0.kind == "text" })?.id ?? "" } }
            .yapperNavigation()
    }

    private var list: some View {
        List {
            filters
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            ForEach(records) { record in
                Group {
                    if tool == .events {
                        NavigationLink { NativeServerEventDetail(model: model, event: record) { Task { await load() } } } label: { recordLabel(record) }
                    } else if tool == .audit {
                        DisclosureGroup { auditDetails(record) } label: { recordLabel(record) }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            recordLabel(record)
                            if tool == .templates, let url = URL(string: "https://yapin.gg/template/" + record.id) { ShareLink("Vorlage teilen", item: url).frame(minHeight: 44) }
                            if tool == .requests { requestActions(record) }
                        }
                    }
                }.contextMenu { contextActions(record) }
            }
            if loading || busy { ProgressView().frame(maxWidth: .infinity) }
            else if more { Button("Weitere Einträge laden") { Task { await load(append: true) } }.frame(minHeight: 44) }
            else if records.isEmpty && error == nil { ContentUnavailableView("Keine Einträge", systemImage: tool.icon) }
        }
        .scrollContentBackground(.hidden).background(YapperPalette.background.ignoresSafeArea())
    }

    @ViewBuilder private var filters: some View {
        if tool == .webhooks {
            Picker("Kanal", selection: $channelID) {
                ForEach(model.snapshot?.channels.filter { $0.kind == "text" } ?? []) { Text("#" + $0.name).tag($0.id) }
            }
        }
        if tool == .audit {
            Picker("Aktion", selection: $auditAction) {
                Text("Alle Aktionen").tag("")
                ForEach(knownActions.sorted(), id: \.self) { Text(NativeServerToolRecord.auditLabels[$0] ?? $0.replacingOccurrences(of: "_", with: " ")).tag($0) }
            }
            Picker("Mitglied", selection: $auditActor) {
                Text("Alle Mitglieder").tag("")
                ForEach(model.snapshot?.members ?? []) { Text($0.displayName).tag($0.id) }
            }
        }
    }

    private func recordLabel(_ record: NativeServerToolRecord) -> some View {
        HStack(spacing: 12) {
            if tool == .emojis, let url = NativeConfiguration.publicAsset(bucket: "emojis", path: record.row["path"].string) { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Image(systemName: "face.smiling") }.frame(width: 40, height: 40) }
            VStack(alignment: .leading, spacing: 5) {
                Text(displayTitle(record)).font(OriginalYapper.font(16, weight: .semibold))
                if let description = record.row["description"].string, !description.isEmpty { Text(description).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).lineLimit(3) }
                if let date = record.row[tool == .events ? "starts_at" : "created_at"].string.flatMap({ try? NativeDate.parse($0) }) { Text(date, format: .dateTime.day().month().year().hour().minute()).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                if tool == .requests {
                    if let message = record.row["message"].string, !message.isEmpty { Text(message).font(OriginalYapper.font(14)) }
                    ForEach(Array(record.row["answers"].array.enumerated()), id: \.offset) { index, answer in if let text = answer.string, !text.isEmpty { Text("\(index + 1). \(text)").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) } }
                }
                if tool == .audit, let target = record.row["target_name"].string { Text(target).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) }
            }
        }.padding(.vertical, 6).frame(minHeight: 44)
    }

    private func displayTitle(_ record: NativeServerToolRecord) -> String {
        if tool == .bans || tool == .requests, let uid = record.row["user_id"].string,
           let member = model.snapshot?.members.first(where: { $0.id == uid }) { return member.displayName }
        return record.title
    }

    @ViewBuilder private func auditDetails(_ record: NativeServerToolRecord) -> some View {
        if let actor = record.row["actor_id"].string { Text("Geändert von: " + (model.snapshot?.members.first(where: { $0.id == actor })?.displayName ?? "Mitglied")) }
        ForEach(Array(record.row["extra"]["changes"].array.enumerated()), id: \.offset) { _, change in
            if let key = change["k"].string { Text(key.replacingOccurrences(of: "_", with: " ") + ": " + (change["from"].string ?? "–") + " → " + (change["to"].string ?? "–")) }
        }
        if let reason = record.row["extra"]["reason"].string { Text(reason) }
    }

    private func requestActions(_ record: NativeServerToolRecord) -> some View {
        HStack {
            Button("Annehmen") { run { api, session in try await api.nativeDecideJoinRequest(id: record.id, accept: true, note: "", session: session) } }.buttonStyle(.borderedProminent)
            Button("Ablehnen", role: .destructive) { declining = record }.buttonStyle(.bordered)
        }.disabled(busy).frame(minHeight: 44)
    }

    @ViewBuilder private func contextActions(_ record: NativeServerToolRecord) -> some View {
        switch tool {
        case .emojis:
            Button("Umbenennen") { editing = record }
            Button("Emoji löschen", role: .destructive) { deleting = record }
        case .webhooks:
            Button("Umbenennen") { editing = record }
            Button("Nachricht veröffentlichen") { composing = record }
            Button("Webhook-Link erneuern") { rotating = record }
            Button("Webhook löschen", role: .destructive) { deleting = record }
        case .templates: Button("Server aus Vorlage erstellen") { editing = record }
        case .bans: Button("Sperre aufheben") { deleting = record }
        default: EmptyView()
        }
    }

    @ViewBuilder private var creationSheet: some View {
        switch tool {
        case .events: NativeServerEventEditor(model: model, event: nil) { Task { await load() } }
        case .emojis: NativeServerEmojiEditor(model: model) { Task { await load() } }
        case .webhooks:
            NativeServerTextSheet(title: "Webhook erstellen", field: "Name", submit: "Erstellen") { name in
                let result = try await model.store.withAuthenticatedSession { api, session in try await api.nativeWebhookCreate(channelID: channelID, name: name, session: session) }
                if let id = result["id"].string, let token = result["token"].string { showWebhookLink(id: id, token: token) }
                await load()
            }
        default: EmptyView()
        }
    }

    @ViewBuilder private func editSheet(_ record: NativeServerToolRecord) -> some View {
        NativeServerTextSheet(title: tool == .templates ? "Server aus Vorlage" : "Umbenennen", field: "Name", initial: record.title, submit: tool == .templates ? "Server erstellen" : "Speichern") { name in
            try await model.store.withAuthenticatedSession { api, session in
                if tool == .emojis { try await api.nativeRenameServerEmoji(id: record.id, name: name, session: session) }
                else if tool == .webhooks { try await api.nativeWebhookRename(id: record.id, name: name, session: session) }
                else if tool == .templates { _ = try await api.nativeServerFromTemplate(code: record.id, name: name, session: session) }
            }
            await load()
        }
    }

    private func load(append: Bool = false) async {
        guard let snapshot = model.snapshot else { return }
        let current = UUID(); generation = current; loading = true; error = nil
        let before = append ? records.last?.row["created_at"].string : nil
        defer { if generation == current { loading = false } }
        do {
            let result = try await model.store.withAuthenticatedSession { api, session in try await api.nativeServerTool(tool, snapshot: snapshot, channelID: channelID.isEmpty ? nil : channelID, before: before, auditAction: auditAction.isEmpty ? nil : auditAction, auditActor: auditActor.isEmpty ? nil : auditActor, session: session) }
            guard generation == current else { return }
            let existing = append ? records : []; var seen = Set(existing.map(\.id))
            records = existing + result.filter { seen.insert($0.id).inserted }; more = tool == .audit && result.count == 50
            knownActions.formUnion(result.compactMap { $0.row["action"].string })
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }

    private func run(_ operation: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await model.store.withAuthenticatedSession(operation); await load() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func remove(_ record: NativeServerToolRecord) {
        run { api, session in
            switch tool {
            case .emojis: try await api.nativeDeleteServerEmoji(record, session: session)
            case .webhooks: try await api.nativeWebhookDelete(id: record.id, session: session)
            case .bans: try await api.nativeModerateMember(serverID: model.serverID, userID: record.id, action: "unban_member", session: session)
            default: break
            }
        }
    }

    private func createTemplate() {
        run { api, session in
            let code = try await api.nativeCreateTemplate(serverID: model.serverID, session: session)
            if let url = URL(string: "https://yapin.gg/template/" + code) { secret = NativeServerShareValue(title: "Servervorlage", url: url, sensitive: false) }
        }
    }

    private func rotate(_ record: NativeServerToolRecord) {
        run { api, session in
            let value = try await api.nativeWebhookRotate(id: record.id, session: session)
            guard let token = value.string else { throw NativeClientError.invalidResponse }
            showWebhookLink(id: record.id, token: token)
        }
    }

    private func showWebhookLink(id: String, token: String) {
        let url = URL(string: "https://www.yapin.gg/api/webhooks")!.appendingPathComponent(id).appendingPathComponent(token)
        let value = NativeServerShareValue(title: "Webhook-Link", url: url, sensitive: true)
        if adding { pendingSecret = value } else { secret = value }
    }
}

private struct NativeServerShareValue: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let sensitive: Bool
}

private struct NativeServerShareSheet: View {
    let value: NativeServerShareValue
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if value.sensitive { Text("Jede Person mit diesem Link kann über den Webhook posten. Teile ihn nur mit Personen und Diensten, denen du vertraust.") }
                Text(value.url.absoluteString).textSelection(.enabled)
                ShareLink("Link teilen", item: value.url).frame(minHeight: 44)
            }
            .navigationTitle(value.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }.yapperNavigation()
        }
    }
}

private struct NativeWebhookPostEditor: View {
    let model: NativeServerDetailModel
    let webhook: NativeServerToolRecord
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var title = ""
    @State private var description = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Nachricht als \(webhook.title)") { TextField("Nachricht", text: $content, axis: .vertical).lineLimit(3...8) }
                Section("Informationsfeld (optional)") { TextField("Titel", text: $title); TextField("Beschreibung", text: $description, axis: .vertical).lineLimit(3...8) }
                if let error { NativeErrorBanner(message: error) }
                if busy { ProgressView("Wird veröffentlicht …") }
            }
            .navigationTitle("Webhook-Nachricht").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Veröffentlichen") {
                        Task {
                            busy = true; error = nil; defer { busy = false }
                            do { try await model.store.withAuthenticatedSession { api, session in try await api.nativeWebhookPost(id: webhook.id, text: content, title: title, description: description, session: session) }; dismiss() }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(busy || (content.isEmpty && title.isEmpty && description.isEmpty))
                }
            }.yapperNavigation()
        }.interactiveDismissDisabled(busy)
    }
}

private struct NativeServerEventDetail: View {
    let model: NativeServerDetailModel
    let event: NativeServerToolRecord
    let changed: () -> Void
    @State private var interested = false
    @State private var editing = false
    @State private var error: String?
    @State private var busy = false
    @State private var eventAction: String?
    @State private var state: String
    init(model: NativeServerDetailModel, event: NativeServerToolRecord, changed: @escaping () -> Void) {
        self.model = model; self.event = event; self.changed = changed
        _interested = State(initialValue: event.row["me"].bool ?? false)
        _state = State(initialValue: event.row["status"].string ?? "scheduled")
    }
    var body: some View {
        Form {
            if let url = NativeConfiguration.publicAsset(bucket: "banners", path: event.row["cover_path"].string) { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.clear }.frame(maxHeight: 220) }
            Section {
                Text(event.title).font(OriginalYapper.font(24, weight: .bold))
                if let starts = event.row["starts_at"].string.flatMap({ try? NativeDate.parse($0) }) { LabeledContent("Beginn", value: starts.formatted(date: .abbreviated, time: .shortened)) }
                if let ends = event.row["ends_at"].string.flatMap({ try? NativeDate.parse($0) }) { LabeledContent("Ende", value: ends.formatted(date: .abbreviated, time: .shortened)) }
                if let location = event.row["location"].string { LabeledContent("Ort", value: location) }
                if let description = event.row["description"].string, !description.isEmpty { Text(description) }
            }
            Section {
                Button(interested ? "Nicht mehr interessiert" : "Interessiert") {
                    let desired = !interested
                    perform { api, session in try await api.nativeEventInterest(id: event.id, interested: desired, session: session); interested = desired }
                }
                if let cid = event.row["channel_id"].string, let channel = model.snapshot?.channels.first(where: { $0.id == cid }) { NativeCallButton(store: model.store, channelID: channel.id, title: channel.name, serverID: model.serverID) }
                ShareLink("Ereignis teilen", item: URL(string: "https://yapin.gg/event/" + event.id)!).frame(minHeight: 44)
            }.disabled(busy)
            if model.allows("manage_events") {
                Section("Verwalten") {
                    Button("Ereignis bearbeiten") { editing = true }
                    if state == "scheduled" { Button("Jetzt starten") { eventAction = "start" } }
                    if state == "active" { Button("Ereignis beenden") { eventAction = "end" } }
                    if state == "active" || state == "scheduled" { Button("Ereignis absagen", role: .destructive) { eventAction = "cancel" } }
                }.disabled(busy)
            }
            if let error { NativeErrorBanner(message: error) }
            if busy { ProgressView("Wird gespeichert …") }
        }
        .navigationTitle(event.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) { NativeServerEventEditor(model: model, event: event, changed: changed) }
        .confirmationDialog("Ereignis ändern?", isPresented: Binding(get: { eventAction != nil }, set: { if !$0 { eventAction = nil } }), titleVisibility: .visible) {
            if let action = eventAction {
                Button(action == "start" ? "Jetzt starten" : action == "end" ? "Beenden" : "Absagen", role: action == "start" ? nil : .destructive) {
                    perform { api, session in try await api.nativeEventAction(id: event.id, action: action, session: session); state = action == "start" ? "active" : action == "end" ? "completed" : "canceled" }
                }
            }
        }.yapperNavigation()
    }

    private func perform(_ operation: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await model.store.withAuthenticatedSession(operation); changed() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
}

private struct NativeServerEventEditor: View {
    let model: NativeServerDetailModel
    let event: NativeServerToolRecord?
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var starts = Date().addingTimeInterval(3600)
    @State private var ends = Date().addingTimeInterval(7200)
    @State private var hasEnd = false
    @State private var channelID = ""
    @State private var location = ""
    @State private var announceID = ""
    @State private var repeatRule = "none"
    @State private var cover: NativeServerSelectedImage?
    @State private var busy = false
    @State private var error: String?
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $title)
                    TextField("Beschreibung", text: $description, axis: .vertical).lineLimit(3...8)
                    NativeServerPhotoInput(title: cover == nil ? "Titelbild auswählen" : "Titelbild ändern", maxPixels: 1600) { cover = $0 }
                }
                Section("Wann?") {
                    DatePicker("Beginn", selection: $starts)
                    Toggle("Endzeit festlegen", isOn: $hasEnd)
                    if hasEnd { DatePicker("Ende", selection: $ends, in: starts...) }
                    Picker("Wiederholen", selection: $repeatRule) { Text("Nie").tag("none"); Text("Wöchentlich").tag("weekly") }
                }
                Section("Wo?") {
                    Picker("Sprachkanal", selection: $channelID) {
                        Text("Anderer Ort").tag("")
                        ForEach(model.snapshot?.channels.filter { $0.kind == "voice" } ?? []) { Text($0.name).tag($0.id) }
                    }
                    if channelID.isEmpty { TextField("Ort oder Link", text: $location) }
                    Picker("Ankündigen in", selection: $announceID) {
                        Text("Nicht ankündigen").tag("")
                        ForEach(model.snapshot?.channels.filter { $0.kind == "text" } ?? []) { Text("#" + $0.name).tag($0.id) }
                    }
                }
                if let error { NativeErrorBanner(message: error) }
                if busy { ProgressView("Ereignis wird gespeichert …") }
            }
            .navigationTitle(event == nil ? "Ereignis erstellen" : "Ereignis bearbeiten").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (channelID.isEmpty && location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                guard let event else { return }
                title = event.title; description = event.row["description"].string ?? ""
                starts = event.row["starts_at"].string.flatMap { try? NativeDate.parse($0) } ?? starts
                if let date = event.row["ends_at"].string.flatMap({ try? NativeDate.parse($0) }) { hasEnd = true; ends = date }
                channelID = event.row["channel_id"].string ?? ""; location = event.row["location"].string ?? ""; announceID = event.row["announce_channel_id"].string ?? ""; repeatRule = event.row["repeat"].string ?? "none"
            }.yapperNavigation()
        }.interactiveDismissDisabled(busy)
    }

    private func save() async {
        busy = true; error = nil; defer { busy = false }
        do {
            try await model.store.withAuthenticatedSession { api, session in
                var coverPath = event?.row["cover_path"].string
                if let cover { coverPath = try await api.uploadMedia(bucket: "banners", data: cover.data, filename: "event-cover.png", contentType: cover.contentType, purpose: "event", session: session) }
                do { try await api.nativeEventSave(serverID: model.serverID, eventID: event?.id, title: title, description: description, starts: starts, ends: hasEnd ? ends : nil, channelID: channelID.isEmpty ? nil : channelID, location: channelID.isEmpty ? location.trimmingCharacters(in: .whitespacesAndNewlines) : nil, announceID: announceID.isEmpty ? nil : announceID, repeatRule: repeatRule, coverPath: coverPath, session: session) }
                catch {
                    if cover != nil, let coverPath { _ = try? await api.webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string("banners"), "path": .string(coverPath)]), session: session) }
                    throw error
                }
            }
            changed(); dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerSelectedImage: Sendable {
    let data: Data
    let contentType: String
    let animated: Bool
}

private struct NativeServerPhotoInput: View {
    let title: String
    let maxPixels: Int
    var preserveAnimation = false
    let onSelected: (NativeServerSelectedImage) -> Void
    @State private var selection: PhotosPickerItem?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) { Label(title, systemImage: "photo").frame(minHeight: 44) }.disabled(loading)
            if loading { ProgressView("Bild wird vorbereitet …") }
            if let error { Text(error).foregroundStyle(YapperPalette.danger).font(OriginalYapper.font(13)) }
        }
        .task(id: selection) {
            guard let selection else { return }
            loading = true; error = nil; defer { loading = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self), data.count <= 20 * 1024 * 1024,
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw NativeClientError.api(status: 400, message: "Dieses Bild konnte nicht gelesen werden.") }
                let animated = CGImageSourceGetCount(source) > 1
                if preserveAnimation && animated {
                    let type = selection.supportedContentTypes.compactMap(\.preferredMIMEType).first ?? "image/gif"
                    guard data.count <= 1024 * 1024, ["image/gif", "image/webp", "image/png"].contains(type) else { throw NativeClientError.api(status: 413, message: "Animierte Emojis dürfen höchstens 1 MB groß sein.") }
                    onSelected(NativeServerSelectedImage(data: data, contentType: type, animated: true)); return
                }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), let png = UIImage(cgImage: thumbnail).pngData() else { throw NativeClientError.invalidResponse }
                onSelected(NativeServerSelectedImage(data: png, contentType: "image/png", animated: false))
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct NativeServerEmojiEditor: View {
    let model: NativeServerDetailModel
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image: NativeServerSelectedImage?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Emoji-Name", text: $name).autocorrectionDisabled().textInputAutocapitalization(.never)
                NativeServerPhotoInput(title: image == nil ? "Bild auswählen" : "Bild ändern", maxPixels: 128, preserveAnimation: true) { image = $0 }
                if let image, let uiImage = UIImage(data: image.data) { Image(uiImage: uiImage).resizable().scaledToFit().frame(maxHeight: 100) }
                Text("2–32 Buchstaben, Ziffern oder Unterstriche. Bilder werden vor der Freigabe von Yapper geprüft.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                if let error { NativeErrorBanner(message: error) }
                if busy { ProgressView("Emoji wird hochgeladen und geprüft …") }
            }
            .navigationTitle("Emoji hinzufügen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Hinzufügen") { Task { await save() } }.disabled(busy || image == nil || name.range(of: "^[A-Za-z0-9_]{2,32}$", options: .regularExpression) == nil) }
            }.yapperNavigation()
        }.interactiveDismissDisabled(busy)
    }
    private func save() async {
        guard let image else { return }; busy = true; error = nil; defer { busy = false }
        do { try await model.store.withAuthenticatedSession { api, session in try await api.nativeAddServerEmoji(serverID: model.serverID, name: name, data: image.data, contentType: image.contentType, animated: image.animated, session: session) }; changed(); dismiss() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerSupportView: View {
    let model: NativeServerDetailModel
    @State private var ticketsOn = false
    @State private var clipsOn = true
    @State private var applyFirst = false
    @State private var questions = ["", "", ""]
    @State private var opening = false
    @State private var destination: Conversation?
    @State private var busy = false
    @State private var error: String?
    @State private var initialized = false

    var body: some View {
        Form {
            Section("Tickets") {
                if ticketsOn { Button("Ticket öffnen") { opening = true } }
                else { Text("Tickets sind auf diesem Server ausgeschaltet.").foregroundStyle(YapperPalette.secondary) }
                if model.allows("manage_server") { Toggle("Mitglieder dürfen Tickets öffnen", isOn: $ticketsOn) }
            }
            if model.allows("manage_server") {
                Section("Beitritt") {
                    Toggle("Neue Mitglieder müssen sich bewerben", isOn: $applyFirst)
                    if applyFirst { ForEach(0..<3, id: \.self) { index in TextField("Frage \(index + 1) (optional)", text: $questions[index]) } }
                }
                Section { Toggle("Clips in Sprachkanälen erlauben", isOn: $clipsOn) }
            }
            if let error { NativeErrorBanner(message: error) }
            if busy { ProgressView("Wird gespeichert …") }
        }
        .navigationTitle("Tickets und Beitritt").navigationBarTitleDisplayMode(.inline)
        .toolbar { if model.allows("manage_server") { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy) } } }
        .onAppear {
            guard !initialized, let server = model.snapshot?.server else { return }; initialized = true
            ticketsOn = server.raw["tickets_on"].bool ?? false; clipsOn = server.raw["clips_off"].bool != true; applyFirst = server.raw["join_apply"].bool ?? false
            let rows = server.raw["join_questions"].array.compactMap(\.string)
            for index in 0..<min(3, rows.count) { questions[index] = rows[index] }
        }
        .sheet(isPresented: $opening) {
            NativeServerTextSheet(title: "Ticket öffnen", field: "Wobei brauchst du Hilfe?", submit: "Öffnen") { topic in
                let id = try await model.store.withAuthenticatedSession { api, session in try await api.nativeOpenTicket(serverID: model.serverID, topic: topic, session: session) }
                destination = Conversation(id: id, title: "Ticket", participants: [], serverID: model.serverID)
                await model.refresh()
            }
        }
        .navigationDestination(item: $destination) { NativeConversationView(store: model.store, conversation: $0) }
        .yapperNavigation()
    }

    private func save() async {
        guard let server = model.snapshot?.server else { return }; busy = true; error = nil; defer { busy = false }
        do {
            try await model.perform { api, session in
                if ticketsOn != (server.raw["tickets_on"].bool ?? false) { _ = try await api.rpc("set_tickets", arguments: ["sid": .string(model.serverID), "p_on": .bool(ticketsOn)], session: session) }
                if clipsOn == (server.raw["clips_off"].bool ?? false) { _ = try await api.rpc("set_server_clips_off", arguments: ["sid": .string(model.serverID), "p_off": .bool(!clipsOn)], session: session) }
                let values = questions.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }.filter { !$0.isEmpty }
                if applyFirst != (server.raw["join_apply"].bool ?? false) || values != server.raw["join_questions"].array.compactMap(\.string) { _ = try await api.rpc("set_join_apply", arguments: ["sid": .string(model.serverID), "p_on": .bool(applyFirst), "p_questions": .array(values.map(NativeJSON.string))], session: session) }
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerBrandingView: View {
    let model: NativeServerDetailModel
    @State private var icon: NativeServerSelectedImage?
    @State private var banner: NativeServerSelectedImage?
    @State private var removeIcon = false
    @State private var removeBanner = false
    @State private var accent = ""
    @State private var tint = ""
    @State private var vanity = ""
    @State private var bannerX = 50.0
    @State private var bannerY = 50.0
    @State private var bannerZoom = 1.0
    @State private var busy = false
    @State private var error: String?
    @State private var initialized = false

    var body: some View {
        Form {
            Section("Serverbild") {
                if let server = model.snapshot?.server { NativeAvatar(name: server.name, url: server.iconURL, size: 72) }
                NativeServerPhotoInput(title: "Serverbild auswählen", maxPixels: 512) { icon = $0; removeIcon = false }
                if model.snapshot?.server.iconPath != nil { Toggle("Serverbild entfernen", isOn: $removeIcon) }
            }
            Section("Banner") {
                NativeServerPhotoInput(title: "Banner auswählen", maxPixels: 2048) { banner = $0; removeBanner = false }
                if model.snapshot?.server.raw["banner_path"].string != nil {
                    Toggle("Banner entfernen", isOn: $removeBanner)
                    LabeledContent("Horizontal", value: "\(Int(bannerX)) %"); Slider(value: $bannerX, in: 0...100)
                    LabeledContent("Vertikal", value: "\(Int(bannerY)) %"); Slider(value: $bannerY, in: 0...100)
                    LabeledContent("Zoom", value: bannerZoom.formatted(.number.precision(.fractionLength(1))) + "×"); Slider(value: $bannerZoom, in: 1...3)
                }
            }
            Section("Serverfarben") { TextField("Akzentfarbe (#RRGGBB)", text: $accent).textInputAutocapitalization(.never).autocorrectionDisabled(); TextField("Grundton (#RRGGBB)", text: $tint).textInputAutocapitalization(.never).autocorrectionDisabled() }
            Section("Eigener Einladungslink") { TextField("Einladungscode", text: $vanity).textInputAutocapitalization(.never).autocorrectionDisabled(); Text("Eigene Links werden von Yapper ab fünf Mitgliedern freigeschaltet.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary) }
            if let error { NativeErrorBanner(message: error) }
            if busy { ProgressView("Profil wird gespeichert …") }
        }
        .navigationTitle("Serverprofil und Darstellung").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(busy) } }
        .task {
            guard !initialized, let server = model.snapshot?.server else { return }; initialized = true
            accent = server.raw["theme"]["accent"].string ?? ""; tint = server.raw["theme"]["tint"].string ?? ""
            bannerX = server.raw["banner_x"].number ?? 50; bannerY = server.raw["banner_y"].number ?? 50; bannerZoom = server.raw["banner_zoom"].number ?? 1
        }.yapperNavigation()
    }

    private func save() async {
        guard let server = model.snapshot?.server else { return }
        for value in [accent, tint] where !value.isEmpty {
            guard value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { error = "Verwende eine Farbe im Format #RRGGBB oder lasse das Feld leer."; return }
        }
        busy = true; error = nil; defer { busy = false }
        do {
            try await model.perform { api, session in
                if icon != nil || removeIcon { try await api.nativeServerBranding(server: server, image: removeIcon ? nil : icon?.data, contentType: icon?.contentType ?? "image/png", banner: false, remove: removeIcon, session: session) }
                if banner != nil || removeBanner { try await api.nativeServerBranding(server: server, image: removeBanner ? nil : banner?.data, contentType: banner?.contentType ?? "image/png", banner: true, remove: removeBanner, session: session) }
                else if let path = server.raw["banner_path"].string, bannerX != (server.raw["banner_x"].number ?? 50) || bannerY != (server.raw["banner_y"].number ?? 50) || bannerZoom != (server.raw["banner_zoom"].number ?? 1) {
                    _ = try await api.rpc("set_server_banner", arguments: ["sid": .string(model.serverID), "p": .string(path), "bx": .number(bannerX), "by": .number(bannerY), "bz": .number(bannerZoom)], session: session)
                }
                if accent != (server.raw["theme"]["accent"].string ?? "") || tint != (server.raw["theme"]["tint"].string ?? "") { _ = try await api.rpc("set_server_theme", arguments: ["sid": .string(model.serverID), "p_accent": accent.isEmpty ? .null : .string(accent), "p_tint": tint.isEmpty ? .null : .string(tint)], session: session) }
                if !vanity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { _ = try await api.rpc("set_vanity_invite", arguments: ["sid": .string(model.serverID), "p_code": .string(try NativeServerInput.inviteCode(vanity))], session: session) }
            }
            icon = nil; banner = nil; removeIcon = false; removeBanner = false; vanity = ""
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; await model.refresh() }
    }
}
