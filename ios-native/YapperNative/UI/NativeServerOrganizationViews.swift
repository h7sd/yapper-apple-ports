import SwiftUI

extension NativeServerFolder {
    @MainActor var nativeColor: Color {
        guard let color, let rgb = UInt32(color.dropFirst(), radix: 16) else { return YapperPalette.accent }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct NativeServerOrganizationEditor: View {
    let store: NativeStore
    let model: NativeServerOrganizationModel
    let servers: [NativeServer]
    let readOnly: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NativeServerOrganizationItem] = []
    @State private var editing: NativeServerFolder?
    @State private var creating = false
    private var foldersEnabled: Bool { store.capabilities.flagOn("server_folders", userID: store.user?.id) }

    var body: some View {
        NavigationStack {
            List {
                if let error = model.error { NativeErrorBanner(message: error) }
                Section {
                    ForEach(items) { item in
                        if let folder = item.folder {
                            Button { editing = folder } label: { Label { Text(folder.name ?? "Ordner (\(folder.servers.count) Server)") } icon: { Image(systemName: "folder").foregroundStyle(folder.nativeColor) } }
                                .contextMenu { Button("Ordner auflösen") { dissolve(item) } }
                        } else { Label(name(item.id), systemImage: "bubble.left.and.bubble.right") }
                    }.onMove { items.move(fromOffsets: $0, toOffset: $1) }
                } footer: { Text("Die Reihenfolge und Ordner werden mit deinem Yapper-Konto synchronisiert. Ordner benötigen mindestens zwei Server.") }
                if foldersEnabled { Button("Ordner erstellen", systemImage: "folder.badge.plus") { creating = true }.disabled(items.compactMap(\.folder).count >= 50 || servers.count < 2) }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(model.isBusy || readOnly)
            .navigationTitle("Server organisieren")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { if await model.save(items, store: store, servers: servers, readOnly: readOnly) { dismiss() } } }.disabled(model.isBusy || readOnly) }
            }
            .onAppear { items = model.value.items(serverIDs: servers.map(\.id)) }
            .sheet(item: $editing) { folder in folderSheet(folder) }
            .sheet(isPresented: $creating) { folderSheet(NativeServerFolder(id: "f" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased(), name: nil, color: nil, servers: [])) }
            .yapperNavigation()
        }
    }
    private func name(_ id: String) -> String { servers.first(where: { $0.id == id })?.name ?? id }
    private func dissolve(_ item: NativeServerOrganizationItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.replaceSubrange(index...index, with: item.serverIDs.map(NativeServerOrganizationItem.server))
    }
    private func folderSheet(_ folder: NativeServerFolder) -> some View {
        NativeServerFolderEditor(folder: folder, servers: servers, custom: store.capabilities.flagOn("folder_custom", userID: store.user?.id)) { updated in
            let selected = Set(updated.servers)
            var next: [NativeServerOrganizationItem] = []
            var insertAt: Int?
            for item in items {
                if item.id == "f:" + updated.id { insertAt = next.count; continue }
                if !Set(item.serverIDs).isDisjoint(with: selected) { insertAt = insertAt ?? next.count }
                let remaining = item.serverIDs.filter { !selected.contains($0) }
                if var old = item.folder, remaining.count >= 2 { old.servers = remaining; next.append(.group(old)) }
                else { next.append(contentsOf: remaining.map(NativeServerOrganizationItem.server)) }
            }
            // Deselected servers from the edited folder remain as standalone entries.
            let missing = servers.map(\.id).filter { !selected.contains($0) && !next.flatMap(\.serverIDs).contains($0) }
            next.append(contentsOf: missing.map(NativeServerOrganizationItem.server))
            next.insert(.group(updated), at: min(insertAt ?? next.count, next.count)); items = next
        }
    }
}

private struct NativeServerFolderEditor: View {
    @State var folder: NativeServerFolder
    let servers: [NativeServer]
    let custom: Bool
    let onSave: (NativeServerFolder) -> Void
    @Environment(\.dismiss) private var dismiss
    private let colors = ["#5865f2", "#3ba55d", "#faa61a", "#ed4245", "#eb459e", "#9b59b6", "#1abc9c", "#e67e22", "#607d8b", "#99aab5"]
    private let colorNames = ["#5865f2": "Blau", "#3ba55d": "Grün", "#faa61a": "Bernstein", "#ed4245": "Koralle", "#eb459e": "Rosa", "#9b59b6": "Violett", "#1abc9c": "Türkis", "#e67e22": "Orange", "#607d8b": "Schiefer", "#99aab5": "Silber"]
    var body: some View {
        NavigationStack {
            Form {
                if custom {
                    TextField("Ordnername (optional)", text: Binding(get: { folder.name ?? "" }, set: { folder.name = $0.isEmpty ? nil : String(String.UnicodeScalarView($0.unicodeScalars.prefix(32))) }))
                    Picker("Farbe", selection: Binding(get: { folder.color ?? "" }, set: { folder.color = $0.isEmpty ? nil : $0 })) { Text("Standard").tag(""); ForEach(colors, id: \.self) { Text(colorNames[$0] ?? "Standard").tag($0) } }
                }
                Section("Server auswählen") {
                    ForEach(servers) { server in
                        Toggle(server.name, isOn: Binding(get: { folder.servers.contains(server.id) }, set: { selected in
                            if selected && folder.servers.count < 100 { folder.servers.append(server.id) } else { folder.servers.removeAll { $0 == server.id } }
                        }))
                    }
                }
                Section("Reihenfolge im Ordner") {
                    ForEach(folder.servers, id: \.self) { id in Text(servers.first(where: { $0.id == id })?.name ?? id) }
                        .onMove { folder.servers.move(fromOffsets: $0, toOffset: $1) }
                }
                .environment(\.editMode, .constant(.active))
            }
            .navigationTitle("Ordner bearbeiten")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Übernehmen") { onSave(folder); dismiss() }.disabled(!(2...100).contains(folder.servers.count)) }
            }
            .yapperNavigation()
        }
    }
}

struct NativeServerNotificationsView: View {
    let model: NativeServerDetailModel
    let target: NativeServerNotificationTarget
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var state: NativeServerNotificationState?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?
    private var quick: Bool { model.store.capabilities.flagOn("quick_notify", userID: model.store.user?.id, serverID: target.serverID) }
    private var levels: Bool { model.store.capabilities.flagOn("channel_notify", userID: model.store.user?.id, serverID: target.serverID) }
    private var ids: [String] {
        if case let .category(_, id) = target { return model.snapshot?.channels.filter { $0.categoryID == id && $0.kind != "thread" }.map(\.id) ?? [] }
        return [target.key]
    }
    private var inherited: String { state?.levels[target.serverID]?.label ?? NativeServerNotificationLevel.mentions.label }

    var body: some View {
        NavigationStack {
            Form {
                if let error { NativeErrorBanner(message: error) }
                if loading { ProgressView("Benachrichtigungen werden geladen …") }
                if let state {
                    if levels {
                        Section("Benachrichtigungen") {
                            if case .server = target { } else {
                                levelButton(nil, label: "Serverstandard: " + inherited)
                            }
                            ForEach(NativeServerNotificationLevel.allCases) { level in levelButton(level, label: level.label) }
                        }
                    }
                    if quick {
                        Section("Stummschaltung") {
                            if ids.contains(where: { state.isMuted($0) }) {
                                Text("Mindestens ein ausgewählter Kanal ist stummgeschaltet.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                                Button("Stummschaltung aufheben") { changeMute(.off) }
                            }
                            ForEach(NativeConversationMuteDuration.allCases.filter { $0 != .off }) { duration in Button(duration.label) { changeMute(duration) } }
                        }
                    }
                    if !quick && !levels { Text("Diese Benachrichtigungsfunktionen sind für dein Konto noch nicht freigeschaltet.").foregroundStyle(YapperPalette.secondary) }
                    if case .category = target { Text("Gilt für alle vorhandenen Kanäle in dieser Kategorie. Neue Kanäle verwenden den Serverstandard.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary) }
                }
            }
            .disabled(busy || model.isReadOnlyFixture)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await load() }
            .yapperNavigation()
        }
    }
    private func levelButton(_ level: NativeServerNotificationLevel?, label: String) -> some View {
        Button { Task { await perform { api, session in try await api.nativeSetServerNotificationLevel(level, target: target, session: session) } } } label: {
            HStack { Text(label); Spacer(); if let state, !ids.isEmpty, ids.allSatisfy({ state.levels[$0] == level || (level == .mentions && target.key == target.serverID && state.levels[$0] == nil) }) { Image(systemName: "checkmark") } }
        }
    }
    private func changeMute(_ duration: NativeConversationMuteDuration) { Task { await perform { api, session in try await api.nativeMuteServerNotifications(duration, target: target, session: session) } } }
    private func load() async {
        guard !model.isReadOnlyFixture else { state = NativeServerNotificationState(); return }
        loading = true; error = nil; defer { loading = false }
        let ownerID = model.store.user?.id
        do {
            let loaded = try await model.store.withAuthenticatedSession { api, session in try await api.nativeServerNotificationState(session: session) }
            guard model.store.user?.id == ownerID, model.store.authState == .signedIn else { throw CancellationError() }
            state = loaded
            model.store.updateServerNotificationContext(loaded)
        }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func perform(_ action: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) async {
        guard !busy, !model.isReadOnlyFixture else { return }; busy = true; error = nil
        defer { busy = false }
        let ownerID = model.store.user?.id
        do {
            try await model.store.withAuthenticatedSession(action)
            guard model.store.user?.id == ownerID, model.store.authState == .signedIn else { throw CancellationError() }
            model.store.updateServerNotificationContext(nil)
            await load()
        }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}
