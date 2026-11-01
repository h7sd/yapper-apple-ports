import SwiftUI

private enum NativeServerPermissionNames {
    static let choices: [(String, String)] = [("view_channel", "Kanal ansehen"), ("send_messages", "Nachrichten senden"), ("read_history", "Nachrichtenverlauf lesen"), ("add_reactions", "Reaktionen hinzufügen"), ("attach_files", "Dateien anhängen"), ("embed_links", "Linkvorschauen"), ("use_external_emojis", "Externe Emojis"), ("mention_everyone", "Alle erwähnen"), ("manage_messages", "Nachrichten verwalten"), ("create_threads", "Threads erstellen"), ("send_in_threads", "In Threads schreiben"), ("manage_threads", "Threads verwalten"), ("create_polls", "Umfragen erstellen"), ("send_voice_messages", "Sprachnachrichten senden"), ("use_headings", "Überschriften verwenden"), ("create_invite", "Einladungen erstellen"), ("change_nickname", "Eigenen Nickname ändern"), ("connect", "Sprachkanal beitreten"), ("speak", "Sprechen")]
}

struct NativeEveryonePermissionView: View {
    let model: NativeServerDetailModel
    @State private var values: [String: Bool] = [:]
    @State private var initialized = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text("Diese Berechtigungen gelten für alle Mitglieder. Zusätzliche Rollen und Kanalregeln können sie erweitern oder einschränken.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary)
                ForEach(NativeServerPermissionNames.choices.filter { NativeServerSnapshot.defaultPermissions.contains($0.0) }, id: \.0) { key, title in
                    Toggle(title, isOn: Binding(get: { values[key] != false }, set: { values[key] = $0 }))
                }
            }
            if let error { NativeErrorBanner(message: error) }
            if model.isBusy { ProgressView("Wird gespeichert …") }
        }
        .navigationTitle("Standardberechtigungen").navigationBarTitleDisplayMode(.inline)
        .onAppear { guard !initialized else { return }; initialized = true; values = model.snapshot?.server.everyonePermissions ?? [:] }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern") {
                    Task {
                        do { try await model.perform { api, session in _ = try await api.rpc("set_everyone_perms", arguments: ["sid": .string(model.serverID), "p": .object(values.mapValues(NativeJSON.bool))], session: session) } }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(model.isBusy)
            }
        }.yapperNavigation()
    }
}

private struct NativeChannelPermissionRule {
    var allow: Set<String> = []
    var deny: Set<String> = []
}

struct NativeChannelPermissionView: View {
    let model: NativeServerDetailModel
    let channelID: String?
    let categoryID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [String: NativeChannelPermissionRule] = [:]
    @State private var selectedRole = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Rolle", selection: $selectedRole) {
                    Text("Alle Mitglieder").tag("")
                    ForEach(model.snapshot?.roles ?? []) { Text($0.name).tag($0.id) }
                }
                Section {
                    ForEach(NativeServerPermissionNames.choices, id: \.0) { key, title in
                        Picker(title, selection: selection(for: key)) { Text("Erben").tag("inherit"); Text("Erlauben").tag("allow"); Text("Verweigern").tag("deny") }
                    }
                } footer: { Text("Geerbte Rechte folgen den Server- und Kategorieberechtigungen. Die wirksamen Rechte werden von Yapper geprüft.") }
                if loading || model.isBusy { ProgressView("Berechtigungen werden geladen …") }
                if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            }
            .navigationTitle("Kanalberechtigungen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(loading || model.isBusy) }
            }
            .task { await load() }.yapperNavigation()
        }.interactiveDismissDisabled(model.isBusy)
    }

    private func selection(for key: String) -> Binding<String> {
        Binding(get: { rules[selectedRole]?.allow.contains(key) == true ? "allow" : rules[selectedRole]?.deny.contains(key) == true ? "deny" : "inherit" }, set: { value in
            var rule = rules[selectedRole] ?? NativeChannelPermissionRule()
            rule.allow.remove(key); rule.deny.remove(key)
            if value == "allow" { rule.allow.insert(key) }
            if value == "deny" { rule.deny.insert(key) }
            rules[selectedRole] = rule
        })
    }

    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            guard channelID != nil || categoryID != nil else { throw NativeClientError.invalidResponse }
            let records = try await model.store.withAuthenticatedSession { api, session in
                var query = [URLQueryItem(name: "server_id", value: "eq.\(model.serverID)"), URLQueryItem(name: "select", value: "id,server_id,channel_id,category_id,role_id,allow,deny")]
                query.append(URLQueryItem(name: channelID == nil ? "category_id" : "channel_id", value: "eq.\(channelID ?? categoryID!)"))
                return try await api.table("channel_overrides", query: query, session: session).rows
            }
            var result: [String: NativeChannelPermissionRule] = [:]
            for row in records {
                guard row["server_id"].string == model.serverID,
                      channelID == nil ? row["category_id"].string == categoryID : row["channel_id"].string == channelID else { throw NativeClientError.invalidResponse }
                result[row["role_id"].string ?? ""] = NativeChannelPermissionRule(allow: Set(row["allow"].array.compactMap(\.string)), deny: Set(row["deny"].array.compactMap(\.string)))
            }
            rules = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        error = nil
        let rows: [NativeJSON] = rules.keys.sorted().compactMap { key in
            guard let rule = rules[key], !rule.allow.isEmpty || !rule.deny.isEmpty else { return nil }
            return .object(["role_id": key.isEmpty ? .null : .string(key), "allow": .array(rule.allow.sorted().map(NativeJSON.string)), "deny": .array(rule.deny.sorted().map(NativeJSON.string))])
        }
        do {
            try await model.perform { api, session in _ = try await api.rpc("save_channel_overrides", arguments: ["p_channel": channelID.map(NativeJSON.string) ?? .null, "p_category": categoryID.map(NativeJSON.string) ?? .null, "p_rows": .array(rows)], session: session) }
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
