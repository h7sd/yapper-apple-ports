import SwiftUI
import Observation

@MainActor @Observable final class NativeServerLibraryModel {
    let store: NativeStore
    private(set) var servers: [NativeServer] = []
    private(set) var isLoading = false
    let organization = NativeServerOrganizationModel()
    var error: String?
    private var revision = UUID()

    init(store: NativeStore) { self.store = store }

    var isReadOnlyFixture: Bool {
        #if DEBUG
        NativeServerFixtures.isEnabled(userID: store.user?.id)
        #else
        false
        #endif
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let current = UUID(); revision = current; isLoading = true; error = nil
        defer { if revision == current { isLoading = false } }
        do {
            #if DEBUG
            if isReadOnlyFixture { servers = [try NativeServerFixtures.server()]; await organization.load(store: store, servers: servers, readOnly: true); return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.nativeServers(session: session) }
            guard current == revision else { return }; servers = result
            await organization.load(store: store, servers: result, readOnly: false)
        } catch is CancellationError { }
        catch { if current == revision { self.error = error.localizedDescription } }
    }
}

struct NativeServersView: View {
    let store: NativeStore
    var onJoinVoice: ((NativeServerChannel) -> Void)? = nil
    @State private var model: NativeServerLibraryModel
    @State private var path: [NativeServer] = []
    @State private var search = ""
    @State private var creating = false
    @State private var joining = false
    @State private var discovering = false
    @State private var organizing = false

    init(store: NativeStore, onJoinVoice: ((NativeServerChannel) -> Void)? = nil) {
        self.store = store; self.onJoinVoice = onJoinVoice
        _model = State(initialValue: NativeServerLibraryModel(store: store))
    }

    private var visible: [NativeServer] {
        let byID = Dictionary(model.servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return model.organization.value.items(serverIDs: model.servers.map(\.id)).flatMap(\.serverIDs).compactMap { byID[$0] }.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = model.error { NativeErrorBanner(message: error) { Task { await model.refresh() } } }
                if let error = model.organization.error { NativeErrorBanner(message: error) { Task { await model.refresh() } } }
                if model.isLoading && model.servers.isEmpty { ProgressView("Server werden geladen …").frame(maxWidth: .infinity) }
                organizedRows
                if !model.isLoading && model.error == nil && model.servers.isEmpty {
                    ContentUnavailableView("Deine Server", systemImage: "person.3", description: Text("Erstelle einen Server, tritt über einen Einladungslink bei oder entdecke öffentliche Communities."))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle("Server")
            .searchable(text: $search, prompt: "Server suchen")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sortieren", systemImage: "arrow.up.arrow.down") { organizing = true }.disabled(model.isReadOnlyFixture || model.servers.isEmpty || model.isLoading || !model.organization.isLoaded)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Server erstellen", systemImage: "plus") { creating = true }
                        Button("Server beitreten", systemImage: "link") { joining = true }
                        Button("Server entdecken", systemImage: "safari") { discovering = true }
                    } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Server hinzufügen")
                    .disabled(model.isReadOnlyFixture)
                }
            }
            .navigationDestination(for: NativeServer.self) { server in NativeServerDetailView(store: store, server: server, onJoinVoice: onJoinVoice) }
            .refreshable { await model.refresh() }
            .task(id: store.user?.id) { await model.refresh() }
            .sheet(isPresented: $creating) {
                NativeServerTextSheet(title: "Server erstellen", field: "Servername", submit: "Erstellen") { name in
                    let id = try await store.withAuthenticatedSession { api, session in try await api.nativeCreateServer(name: name, session: session) }
                    await model.refresh()
                    if let server = model.servers.first(where: { $0.id == id }) { path.append(server) }
                }
            }
            .sheet(isPresented: $joining) {
                NativeServerJoinView(store: store) { id in
                    await model.refresh()
                    if let server = model.servers.first(where: { $0.id == id }) { path.append(server) }
                }
            }
            .sheet(isPresented: $discovering, onDismiss: { Task { await model.refresh() } }) { NativeServerDiscoveryView(store: store) }
            .sheet(isPresented: $organizing) { NativeServerOrganizationEditor(store: store, model: model.organization, servers: model.servers, readOnly: model.isReadOnlyFixture) }
            .yapperNavigation()
        }
    }

    @ViewBuilder private var organizedRows: some View {
        if !search.isEmpty { ForEach(visible) { server in serverLink(server) } }
        else {
            ForEach(model.organization.value.items(serverIDs: model.servers.map(\.id))) { item in
                if let folder = item.folder {
                    DisclosureGroup {
                        ForEach(folder.servers, id: \.self) { id in if let server = model.servers.first(where: { $0.id == id }) { serverLink(server) } }
                    } label: { Label { Text(folder.name ?? folder.servers.compactMap { id in model.servers.first(where: { $0.id == id })?.name }.prefix(3).joined(separator: ", ")) } icon: { Image(systemName: "folder").foregroundStyle(folder.nativeColor) } }
                } else if let server = model.servers.first(where: { $0.id == item.id }) { serverLink(server) }
            }
        }
    }
    private func serverLink(_ server: NativeServer) -> some View {
        NavigationLink(value: server) { NativeServerListRow(server: server) }.accessibilityIdentifier("native.server.\(server.id)")
    }
}

private struct NativeServerListRow: View {
    let server: NativeServer
    var body: some View {
        HStack(spacing: 14) {
            NativeAvatar(name: server.name, url: server.iconURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name).font(OriginalYapper.font(16, weight: .semibold)).foregroundStyle(YapperPalette.text)
                if !server.description.isEmpty { Text(server.description).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).lineLimit(2) }
            }
        }
        .padding(.vertical, 7)
        .frame(minHeight: 60)
    }
}

struct NativeServerDiscoveryView: View {
    let store: NativeStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var servers: [NativeServer] = []
    @State private var joined: Set<String> = []
    @State private var isLoading = false
    @State private var joining: String?
    @State private var error: String?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                if let error { NativeErrorBanner(message: error) { Task { await load() } } }
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 12) {
                        NativeServerListRow(server: server)
                        Button(joined.contains(server.id) ? "Beigetreten" : "Beitreten") {
                            Task {
                                joining = server.id; error = nil
                                defer { joining = nil }
                                do { try await store.withAuthenticatedSession { api, session in try await api.nativeJoinPublicServer(id: server.id, session: session) }; joined.insert(server.id) }
                                catch is CancellationError { }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(joined.contains(server.id) || joining != nil)
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 8)
                }
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                else if hasMore { Button("Weitere Server laden") { Task { await load(more: true) } }.frame(minHeight: 44) }
                else if servers.isEmpty && error == nil { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Server entdecken")
            .searchable(text: $query, prompt: "Communities suchen")
            .task(id: query) {
                do { if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }; try Task.checkCancellation(); await load() } catch { }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() }.frame(minHeight: 44) } }
            .scrollContentBackground(.hidden).background(YapperPalette.background.ignoresSafeArea()).yapperNavigation()
        }
    }

    private func load(more: Bool = false) async {
        guard !Task.isCancelled else { return }
        let current = UUID(); generation = current; isLoading = true; error = nil
        let requestedOffset = more ? offset : 0
        defer { if generation == current { isLoading = false } }
        do {
            let q = query
            let result = try await store.withAuthenticatedSession { api, session in try await api.nativeDiscoverServers(query: q, offset: requestedOffset, session: session) }
            guard generation == current else { return }
            let existing = more ? servers : []
            var seen = Set(existing.map(\.id)); servers = existing + result.filter { seen.insert($0.id).inserted }
            offset = requestedOffset + result.count; hasMore = result.count == 48
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }
}

@MainActor @Observable final class NativeServerDetailModel {
    let store: NativeStore
    let serverID: String
    private(set) var snapshot: NativeServerSnapshot?
    private(set) var isLoading = false
    private(set) var isBusy = false
    var error: String?
    private var revision = UUID()

    init(store: NativeStore, id: String) { self.store = store; serverID = id }

    var isReadOnlyFixture: Bool {
        #if DEBUG
        NativeServerFixtures.isEnabled(userID: store.user?.id) && serverID == NativeServerFixtures.serverID
        #else
        false
        #endif
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        let current = UUID(); revision = current; isLoading = true; error = nil
        defer { if revision == current { isLoading = false } }
        do {
            #if DEBUG
            if isReadOnlyFixture { snapshot = try NativeServerFixtures.snapshot(); return }
            #endif
            let id = serverID
            let value = try await store.withAuthenticatedSession { api, session in try await api.nativeServerSnapshot(id: id, session: session) }
            guard revision == current else { return }; snapshot = value
        } catch is CancellationError { }
        catch { if revision == current { self.error = error.localizedDescription } }
    }

    func perform(reload: Bool = true, _ operation: @MainActor (NativeAPI, NativeSession) async throws -> Void) async throws {
        guard !isBusy else { throw CancellationError() }
        guard !isReadOnlyFixture else { throw NativeClientError.api(status: 400, message: "Die synthetische UI-Vorschau ist schreibgeschützt.") }
        isBusy = true; error = nil
        defer { isBusy = false }
        try await store.withAuthenticatedSession(operation)
        if reload { await refresh() }
    }

    func allows(_ permission: String) -> Bool { snapshot?.hasPermission(permission, userID: store.user?.id) == true }
}

private enum NativeServerSheet: Identifiable {
    case channel(NativeServerChannel?), category(NativeServerCategory?), permissions(channelID: String?, categoryID: String?), notifications(NativeServerNotificationTarget, String), report, settings, members, invite, roles, tools
    var id: String {
        switch self {
        case let .channel(channel): "channel:" + (channel?.id ?? "new")
        case let .category(category): "category:" + (category?.id ?? "new")
        case let .permissions(channelID, categoryID): "permissions:" + (channelID ?? categoryID ?? "")
        case let .notifications(target, _): "notifications:" + target.key
        case .report: "report"
        case .settings: "settings"
        case .members: "members"
        case .invite: "invite"
        case .roles: "roles"
        case .tools: "tools"
        }
    }
}

struct NativeServerDetailView: View {
    let store: NativeStore
    let server: NativeServer
    var onJoinVoice: ((NativeServerChannel) -> Void)?
    var onOpenConversation: ((Conversation) -> Void)?
    var originalSidebar = false
    var reserveFloatingAccount = false
    var onServerLeft: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeServerDetailModel
    @State private var sheet: NativeServerSheet?
    @State private var deletingChannel: NativeServerChannel?
    @State private var deletingCategory: NativeServerCategory?
    @State private var closingTicket: NativeServerChannel?

    init(store: NativeStore, server: NativeServer, onJoinVoice: ((NativeServerChannel) -> Void)?, onOpenConversation: ((Conversation) -> Void)? = nil, originalSidebar: Bool = false, reserveFloatingAccount: Bool = false, onServerLeft: (() -> Void)? = nil) {
        self.store = store; self.server = server; self.onJoinVoice = onJoinVoice; self.onOpenConversation = onOpenConversation; self.originalSidebar = originalSidebar; self.reserveFloatingAccount = reserveFloatingAccount; self.onServerLeft = onServerLeft
        _model = State(initialValue: NativeServerDetailModel(store: store, id: server.id))
    }

    var body: some View {
        VStack(spacing: 0) {
        if originalSidebar {
            if let banner = NativeConfiguration.publicAsset(bucket: "banners", path: model.snapshot?.server.raw["banner_path"].string ?? server.raw["banner_path"].string) {
                NativeRemoteImage(url: banner, maximumPixelSize: 900, mode: .fill).aspectRatio(3, contentMode: .fit).clipped()
            }
            serverMenu
                .frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
        }
        ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
            if model.isReadOnlyFixture { Text("Testansicht · Beispieldaten").font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.faint).padding(.horizontal, 8).padding(.bottom, 6) }
            if let error = model.error { NativeErrorBanner(message: error) { Task { await model.refresh() } } }
            if model.isLoading && model.snapshot == nil { ProgressView("Kanäle werden geladen …").frame(maxWidth: .infinity) }
            if let snapshot = model.snapshot {
                if !originalSidebar && !snapshot.server.description.isEmpty { Text(snapshot.server.description).foregroundStyle(YapperPalette.secondary).listRowSeparator(.hidden) }
                ForEach(snapshot.uncategorized) { channel in channelRow(channel, snapshot: snapshot) }
                ForEach(snapshot.categories) { category in
                    VStack(spacing: 0) {
                        HStack {
                            Text(originalSidebar ? category.name.uppercased() : category.name).font(OriginalYapper.font(12, weight: .bold)).foregroundStyle(YapperPalette.secondary)
                            Spacer()
                            if !model.isReadOnlyFixture && notificationSettingsAvailable {
                                Button { sheet = .notifications(.category(serverID: server.id, categoryID: category.id), category.name) } label: { Image(systemName: "bell").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Benachrichtigungen für \(category.name)")
                            }
                            if !model.isReadOnlyFixture && model.allows("manage_channels") {
                                Menu {
                                    Button("Kategorie umbenennen") { sheet = .category(category) }
                                    Button("Berechtigungen") { sheet = .permissions(channelID: nil, categoryID: category.id) }
                                    Button("Kategorie löschen", role: .destructive) { deletingCategory = category }
                                } label: { OriginalYapperIcon("plus", size: 16).frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Kategorie \(category.name) bearbeiten")
                            }
                        }
                        .padding(.leading, 8).padding(.top, 8)
                        ForEach(snapshot.channels(in: category)) { channel in channelRow(channel, snapshot: snapshot) }
                    }
                }
                if snapshot.channels.isEmpty { Text(model.allows("manage_channels") ? "Noch keine Kanäle. Erstelle den ersten über das Servermenü." : "Noch keine Kanäle.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.faint).padding(12) }
            }
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, reserveFloatingAccount ? 90 : 12)
        }
        .scrollIndicators(.hidden)
        .background(YapperPalette.sidebar)
        }
        .navigationTitle(originalSidebar ? "" : model.snapshot?.server.name ?? server.name)
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(YapperPalette.background.ignoresSafeArea())
        .toolbar {
            if !originalSidebar {
            ToolbarItem(placement: .topBarTrailing) {
                serverMenu
            }
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .sheet(item: $sheet) { destination in sheetContent(destination) }
        .confirmationDialog("Kanal dauerhaft löschen?", isPresented: Binding(get: { deletingChannel != nil }, set: { if !$0 { deletingChannel = nil } }), titleVisibility: .visible) {
            if let channel = deletingChannel { Button("Kanal löschen", role: .destructive) { action { api, session in try await api.nativeDeleteChannel(id: channel.id, session: session) } } }
        } message: { Text("Die Nachrichten dieses Kanals werden dabei ebenfalls entfernt.") }
        .confirmationDialog("Kategorie löschen?", isPresented: Binding(get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } }), titleVisibility: .visible) {
            if let category = deletingCategory { Button("Kategorie löschen", role: .destructive) { action { api, session in try await api.nativeDeleteCategory(id: category.id, session: session) } } }
        } message: { Text("Die Kanäle bleiben erhalten und werden ohne Kategorie angezeigt.") }
        .confirmationDialog("Ticket schließen?", isPresented: Binding(get: { closingTicket != nil }, set: { if !$0 { closingTicket = nil } }), titleVisibility: .visible) {
            if let channel = closingTicket { Button("Ticket schließen", role: .destructive) { action { api, session in try await api.nativeCloseServerTicket(channel: channel, session: session) } } }
        } message: { Text("Der Ticketkanal wird geschlossen und aus der Kanalliste entfernt.") }
        .yapperNavigation()
    }

    private var serverMenu: some View {
        Menu {
            Button("Mitglieder", systemImage: "person.2") { sheet = .members }
            if !model.isReadOnlyFixture {
                if notificationSettingsAvailable { Button("Benachrichtigungen", systemImage: "bell") { sheet = .notifications(.server(server.id), server.name) } }
                if model.allows("create_invite") { Button("Einladen", systemImage: "person.badge.plus") { sheet = .invite } }
                if model.allows("manage_channels") {
                    Button("Kanal erstellen", systemImage: "number") { sheet = .channel(nil) }
                    Button("Kategorie erstellen", systemImage: "folder.badge.plus") { sheet = .category(nil) }
                }
                if model.allows("manage_roles") { Button("Rollen", systemImage: "person.crop.square.badge.key") { sheet = .roles } }
                Button("Weitere Serverfunktionen", systemImage: "square.grid.2x2") { sheet = .tools }
                Button("Servereinstellungen", systemImage: "gearshape") { sheet = .settings }
                Button("Server melden", systemImage: "flag") { sheet = .report }
            }
        } label: {
            if originalSidebar {
                HStack(spacing: 8) {
                    Text(model.snapshot?.server.name ?? server.name).font(OriginalYapper.font(16, weight: .bold)).lineLimit(1)
                    Spacer(minLength: 0)
                    OriginalYapperIcon("chevronDown", size: 20)
                }.padding(.leading, 16).padding(.trailing, 12).frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            } else { OriginalYapperIcon("more", size: 20).frame(minWidth: 44, minHeight: 44) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(YapperPalette.text)
        .accessibilityLabel("Servermenü")
    }

    @ViewBuilder private func channelRow(_ channel: NativeServerChannel, snapshot: NativeServerSnapshot) -> some View {
        Group {
            if channel.kind == "voice" {
                HStack(spacing: 12) {
                    channelLabel(channel)
                    Spacer()
                    if model.isReadOnlyFixture {
                        OriginalYapperIcon("phone", size: 18).frame(minWidth: 44, minHeight: 44).foregroundStyle(YapperPalette.secondary).accessibilityLabel("Demo: Anrufe deaktiviert")
                    } else if let onJoinVoice { Button { onJoinVoice(channel) } label: { OriginalYapperIcon("phone", size: 18).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("\(channel.name) beitreten") }
                    else { NativeCallButton(store: store, channelID: channel.id, title: channel.name, serverID: channel.serverID) }
                }
            } else if channel.kind == "forum" {
                NavigationLink { NativeServerForumView(store: store, channel: channel, snapshot: snapshot) } label: { channelLabel(channel) }
                    .disabled(model.isReadOnlyFixture)
            } else {
                if let onOpenConversation { Button { onOpenConversation(channel.conversation) } label: { channelLabel(channel) }.buttonStyle(.plain) }
                else { NavigationLink { NativeConversationView(store: store, conversation: channel.conversation) } label: { channelLabel(channel) } }
            }
        }
        .frame(minHeight: 44)
        .background(store.selectedConversation?.id == channel.id ? YapperPalette.active : .clear, in: .rect(cornerRadius: 6))
        .padding(.vertical, 1)
        .accessibilityIdentifier("native.server.channel.\(channel.id)")
        .contextMenu {
            if !model.isReadOnlyFixture, channel.ticketBy != nil, channel.ticketBy == store.user?.id || snapshot.server.ownerID == store.user?.id {
                Button("Ticket schließen", systemImage: "ticket", role: .destructive) { closingTicket = channel }
            }
            if !model.isReadOnlyFixture && notificationSettingsAvailable { Button("Benachrichtigungen", systemImage: "bell") { sheet = .notifications(.channel(serverID: server.id, channelID: channel.id), channel.name) } }
            if !model.isReadOnlyFixture && model.allows("manage_channels") {
                Button("Kanal bearbeiten", systemImage: "pencil") { sheet = .channel(channel) }
                Button("Kanal löschen", systemImage: "trash", role: .destructive) { deletingChannel = channel }
            }
            if !model.isReadOnlyFixture && (model.allows("manage_channels") || model.allows("manage_roles")) { Button("Berechtigungen", systemImage: "lock.shield") { sheet = .permissions(channelID: channel.id, categoryID: nil) } }
        }
    }

    private func channelLabel(_ channel: NativeServerChannel) -> some View {
        HStack(spacing: 6) {
            if channel.kind == "voice" { OriginalYapperIcon("volume", size: 20).frame(width: 20) }
            else if channel.kind == "forum" { OriginalYapperIcon("servers", size: 20).frame(width: 20) }
            else { Text("#").font(OriginalYapper.font(23, weight: .medium)).frame(width: 20).foregroundStyle(YapperPalette.faint) }
            Text(channel.name).font(OriginalYapper.font(15, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(YapperPalette.secondary)
        .padding(.horizontal, 8).frame(minHeight: 44).contentShape(.rect)
    }

    @ViewBuilder private func sheetContent(_ destination: NativeServerSheet) -> some View {
        switch destination {
        case let .channel(channel): NativeServerChannelEditor(model: model, channel: channel)
        case let .category(category):
            NativeServerTextSheet(title: category == nil ? "Kategorie erstellen" : "Kategorie umbenennen", field: "Name", initial: category?.name ?? "", submit: "Speichern") { name in
                try await model.perform { api, session in
                    if let category { try await api.nativeRenameCategory(id: category.id, name: name, session: session) }
                    else { try await api.nativeCreateCategory(serverID: server.id, name: name, session: session) }
                }
            }
        case .settings: NativeServerSettingsView(model: model) { if let onServerLeft { onServerLeft() } else { dismiss() } }
        case .members: NativeServerMembersView(model: model)
        case .invite: NativeServerInviteView(model: model)
        case .roles: NativeServerRolesView(model: model)
        case .tools: NativeServerToolsView(model: model)
        case let .permissions(channelID, categoryID): NativeChannelPermissionView(model: model, channelID: channelID, categoryID: categoryID)
        case let .notifications(target, title): NativeServerNotificationsView(model: model, target: target, title: title)
        case .report: NavigationStack { NativeReportComposer(store: store, target: .server(server.id)) }
        }
    }

    private func action(_ operation: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) {
        Task { do { try await model.perform(operation) } catch is CancellationError { } catch { model.error = error.localizedDescription } }
    }
    private var notificationSettingsAvailable: Bool {
        store.capabilities.flagOn("channel_notify", userID: store.user?.id, serverID: server.id) || store.capabilities.flagOn("quick_notify", userID: store.user?.id, serverID: server.id)
    }
}

struct NativeServerTextSheet: View {
    let title: String
    let field: String
    let submit: String
    var autocorrection = true
    var allowsEmpty = false
    let action: @MainActor (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(title: String, field: String, initial: String = "", submit: String, autocorrection: Bool = true, allowsEmpty: Bool = false, action: @escaping @MainActor (String) async throws -> Void) {
        self.title = title; self.field = field; self.submit = submit; self.autocorrection = autocorrection; self.allowsEmpty = allowsEmpty; self.action = action
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(field, text: $text).autocorrectionDisabled(!autocorrection).textInputAutocapitalization(autocorrection ? .sentences : .never)
                if let error { NativeErrorBanner(message: error) }
                if saving { ProgressView("Wird gespeichert …") }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submit) {
                        Task {
                            saving = true; error = nil
                            defer { saving = false }
                            do { try await action(text); dismiss() }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(saving || (!allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.yapperNavigation()
        }
        .interactiveDismissDisabled(saving)
    }
}

private struct NativeServerInviteView: View {
    let model: NativeServerDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var invite: URL?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Einladung wird geladen …") }
                if let invite {
                    Text(invite.absoluteString).textSelection(.enabled)
                    ShareLink("Einladung teilen", item: invite).frame(minHeight: 44)
                }
                if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            }
            .navigationTitle("Freunde einladen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await load() }.yapperNavigation()
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { let id = model.serverID; invite = try await model.store.withAuthenticatedSession { api, session in try await api.nativeInvite(serverID: id, session: session) } }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerChannelEditor: View {
    let model: NativeServerDetailModel
    let channel: NativeServerChannel?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = "text"
    @State private var categoryID = ""
    @State private var readOnly = false
    @State private var isPrivate = false
    @State private var slowmode = 0
    @State private var allowed: Set<String> = []
    @State private var posting: Set<String> = []
    @State private var error: String?
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Kanalname", text: $name)
                    if channel == nil { Picker("Kanaltyp", selection: $kind) { Text("Text").tag("text"); Text("Sprache").tag("voice"); Text("Forum").tag("forum") } }
                    Picker("Kategorie", selection: $categoryID) {
                        Text("Keine Kategorie").tag("")
                        ForEach(model.snapshot?.categories ?? []) { Text($0.name).tag($0.id) }
                    }
                }
                if channel != nil {
                    Section("Zugriff") {
                        Toggle("Privater Kanal", isOn: $isPrivate)
                        if isPrivate { roleToggles(selection: $allowed) }
                    }
                    if kind != "voice" {
                        Section("Nachrichten") {
                            Toggle("Nur ausgewählte Rollen dürfen schreiben", isOn: $readOnly)
                            if readOnly { roleToggles(selection: $posting) }
                            Picker("Slowmode", selection: $slowmode) { ForEach([0, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600], id: \.self) { Text($0 == 0 ? "Aus" : "\($0) Sekunden").tag($0) } }
                        }
                    }
                }
                if let error { NativeErrorBanner(message: error) }
                if model.isBusy { ProgressView("Wird gespeichert …") }
            }
            .navigationTitle(channel == nil ? "Kanal erstellen" : "Kanal bearbeiten").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(model.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                guard let channel else { return }
                name = channel.name; kind = channel.kind; categoryID = channel.categoryID ?? ""; readOnly = channel.readOnly; isPrivate = channel.isPrivate; slowmode = channel.slowmode; allowed = channel.allowedRoles; posting = channel.postRoles
            }.yapperNavigation()
        }
        .interactiveDismissDisabled(model.isBusy)
    }

    @ViewBuilder private func roleToggles(selection: Binding<Set<String>>) -> some View {
        ForEach(model.snapshot?.roles ?? []) { role in
            Toggle(role.name, isOn: Binding(get: { selection.wrappedValue.contains(role.id) }, set: { if $0 { selection.wrappedValue.insert(role.id) } else { selection.wrappedValue.remove(role.id) } }))
        }
    }

    private func save() async {
        error = nil
        let values = (name, categoryID.isEmpty ? nil : categoryID, readOnly, isPrivate, slowmode, Array(allowed).sorted(), Array(posting).sorted())
        do {
            try await model.perform { api, session in
                if let channel {
                    if values.0 != channel.name { try await api.nativeRenameChannel(id: channel.id, name: values.0, session: session) }
                    if values.1 != channel.categoryID { try await api.nativeSetChannelCategory(id: channel.id, categoryID: values.1, session: session) }
                    if values.3 != channel.isPrivate || Set(values.5) != channel.allowedRoles { try await api.nativeSetChannelAccess(id: channel.id, isPrivate: values.3, roles: values.5, session: session) }
                    if kind != "voice", values.2 != channel.readOnly || values.4 != channel.slowmode || Set(values.6) != channel.postRoles { try await api.nativeSetChannelPosting(id: channel.id, readOnly: values.2, roles: values.6, slowmode: values.4, session: session) }
                } else { _ = try await api.nativeCreateChannel(serverID: model.serverID, name: values.0, kind: kind, categoryID: values.1, session: session) }
            }
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; await model.refresh() }
    }
}

private struct NativeServerSettingsView: View {
    let model: NativeServerDetailModel
    let onLeft: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var tags = ""
    @State private var discoverable = false
    @State private var nickname = ""
    @State private var error: String?
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    private var isOwner: Bool { model.snapshot?.server.ownerID == model.store.user?.id }

    var body: some View {
        NavigationStack {
            Form {
                if model.allows("manage_server") {
                    Section("Server") { TextField("Name", text: $name); TextField("Beschreibung", text: $description, axis: .vertical).lineLimit(3...8) }
                    Section("Entdeckung") { Toggle("Öffentlich auffindbar", isOn: $discoverable); TextField("Tags, durch Kommas getrennt", text: $tags) }
                }
                Section("Dein Profil auf diesem Server") { TextField("Nickname", text: $nickname) }
                if let error { NativeErrorBanner(message: error) }
                if model.isBusy { ProgressView("Wird gespeichert …") }
                Section {
                    if isOwner { Button("Server löschen", role: .destructive) { confirmDelete = true } }
                    else { Button("Server verlassen", role: .destructive) { confirmLeave = true } }
                }
            }
            .navigationTitle("Servereinstellungen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(model.isBusy) }
                ToolbarItem(placement: .confirmationAction) { Button("Speichern") { Task { await save() } }.disabled(model.isBusy) }
            }
            .task {
                guard let snapshot = model.snapshot else { return }
                name = snapshot.server.name; description = snapshot.server.description; tags = snapshot.server.tags.joined(separator: ", "); discoverable = snapshot.server.discoverable
                nickname = snapshot.members.first(where: { $0.id == model.store.user?.id })?.nickname ?? ""
            }
            .confirmationDialog("Server verlassen?", isPresented: $confirmLeave, titleVisibility: .visible) { Button("Verlassen", role: .destructive) { Task { await leave(delete: false) } } }
            .confirmationDialog("Server dauerhaft löschen?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Server löschen", role: .destructive) { Task { await leave(delete: true) } } } message: { Text("Alle Kanäle und Nachrichten dieses Servers werden entfernt.") }
            .yapperNavigation()
        }.interactiveDismissDisabled(model.isBusy)
    }

    private func save() async {
        guard let snapshot = model.snapshot, let userID = model.store.user?.id else { return }
        error = nil
        do {
            try await model.perform { api, session in
                if model.allows("manage_server") { try await api.nativeUpdateServer(snapshot.server, name: name, description: description, discoverable: discoverable, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, session: session) }
                let previous = snapshot.members.first(where: { $0.id == userID })?.nickname ?? ""
                if previous != nickname { try await api.nativeSetNickname(serverID: model.serverID, userID: userID, nickname: nickname, session: session) }
            }
            dismiss()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; await model.refresh() }
    }

    private func leave(delete: Bool) async {
        do { try await model.perform(reload: false) { api, session in try await api.nativeLeaveServer(id: model.serverID, delete: delete, session: session) }; dismiss(); onLeft() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerMembersView: View {
    let model: NativeServerDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var results: [NativeServerMember]?
    @State private var finding = false
    @State private var searchGeneration = UUID()
    @State private var nicknameMember: NativeServerMember?
    @State private var moderation: NativeServerModeration?
    @State private var error: String?

    private var members: [NativeServerMember] { results ?? (model.snapshot?.members ?? []) }

    var body: some View {
        NavigationStack {
            List {
                if let error { NativeErrorBanner(message: error) }
                if finding { ProgressView("Mitglieder werden gesucht …") }
                if model.isReadOnlyFixture { Label("Synthetische Vorschau · nur Lesen", systemImage: "flask").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary) }
                ForEach(members) { member in
                    HStack(spacing: 12) {
                        NativeAvatar(name: member.displayName, url: member.user.avatarURL)
                        VStack(alignment: .leading, spacing: 4) { Text(member.displayName).font(OriginalYapper.font(16, weight: .semibold)); Text("@" + member.user.username).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) }
                        Spacer()
                        if member.id == model.snapshot?.server.ownerID { Image(systemName: "crown.fill").foregroundStyle(YapperPalette.accent).accessibilityLabel("Serverinhaber") }
                    }
                    .frame(minHeight: 52)
                    .accessibilityIdentifier("native.server.member.\(member.id)")
                    .contextMenu { memberActions(member) }
                }
                if search.isEmpty { Text("Suche nach weiteren Mitgliedern mit mindestens zwei Zeichen.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary) }
                if members.isEmpty && !finding { ContentUnavailableView.search(text: search) }
            }
            .navigationTitle("Mitglieder").searchable(text: $search, prompt: "Name oder Benutzername")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task(id: search) { await findMembers() }
            .sheet(item: $nicknameMember) { member in
                NativeServerTextSheet(title: "Nickname ändern", field: "Nickname", initial: member.nickname ?? "", submit: "Speichern", allowsEmpty: true) { text in
                    try await model.perform { api, session in try await api.nativeSetNickname(serverID: model.serverID, userID: member.id, nickname: text, session: session) }
                }
            }
            .confirmationDialog(moderation?.title ?? "Mitglied verwalten", isPresented: Binding(get: { moderation != nil }, set: { if !$0 { moderation = nil } }), titleVisibility: .visible) {
                if let moderation { Button(moderation.title, role: .destructive) { Task { await apply(moderation) } } }
            }
            .scrollContentBackground(.hidden).background(YapperPalette.background.ignoresSafeArea()).yapperNavigation()
        }
    }

    @ViewBuilder private func memberActions(_ member: NativeServerMember) -> some View {
        if !model.isReadOnlyFixture {
        if member.id == model.store.user?.id || model.allows("manage_nicknames") { Button("Nickname ändern") { nicknameMember = member } }
        if model.allows("manage_roles"), let snapshot = model.snapshot {
            Menu("Rollen") {
                ForEach(snapshot.roles.filter { $0.auto == "none" && (snapshot.server.ownerID == model.store.user?.id || $0.position < snapshot.topPosition(model.store.user?.id ?? "")) }) { role in
                    let assigned = snapshot.memberRoles[member.id]?.contains(role.id) == true
                    Button((assigned ? "Entfernen: " : "Hinzufügen: ") + role.name) {
                        Task {
                            do { try await model.perform { api, session in try await api.nativeAssignRole(serverID: model.serverID, userID: member.id, roleID: role.id, enabled: !assigned, session: session) } }
                            catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
        }
        if model.snapshot?.outranks(member.id, userID: model.store.user?.id) == true {
            if model.allows("timeout_members") { Button("10 Minuten stummschalten") { moderation = NativeServerModeration(member: member, action: "server_timeout", title: "10 Minuten stummschalten", minutes: 10) } }
            if model.allows("kick_members") { Button("Vom Server entfernen", role: .destructive) { moderation = NativeServerModeration(member: member, action: "kick_member", title: "Mitglied entfernen") } }
            if model.allows("ban_members") { Button("Mitglied sperren", role: .destructive) { moderation = NativeServerModeration(member: member, action: "ban_member", title: "Mitglied sperren") } }
        }
        }
    }

    private func findMembers() async {
        let current = UUID(); searchGeneration = current
        guard search.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { results = nil; finding = false; return }
        finding = true; error = nil
        defer { if current == searchGeneration { finding = false } }
        if model.isReadOnlyFixture {
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            results = model.snapshot?.members.filter { $0.displayName.localizedCaseInsensitiveContains(query) || $0.user.username.localizedCaseInsensitiveContains(query) }
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation()
            let q = search; let id = model.serverID
            let value = try await model.store.withAuthenticatedSession { api, session in try await api.nativeFindServerMembers(serverID: id, query: q, session: session) }
            guard current == searchGeneration else { return }; results = value
        } catch is CancellationError { }
        catch { if current == searchGeneration { self.error = error.localizedDescription } }
    }

    private func apply(_ moderation: NativeServerModeration) async {
        do { try await model.perform { api, session in try await api.nativeModerateMember(serverID: model.serverID, userID: moderation.member.id, action: moderation.action, minutes: moderation.minutes, session: session) }; results = nil }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct NativeServerModeration {
    let member: NativeServerMember
    let action: String
    let title: String
    var minutes = 0
}

private struct NativeServerRolesView: View {
    let model: NativeServerDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(model.snapshot?.roles ?? []) { role in
                    NavigationLink(role.name) { NativeServerRoleEditor(model: model, role: role) }
                        .disabled(!canEdit(role))
                }
            }
            .navigationTitle("Rollen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { creating = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Rolle erstellen") }
            }
            .sheet(isPresented: $creating) {
                NativeServerTextSheet(title: "Rolle erstellen", field: "Rollenname", submit: "Erstellen") { name in
                    guard let snapshot = model.snapshot else { throw NativeClientError.invalidResponse }
                    try await model.perform { api, session in try await api.nativeCreateRole(snapshot: snapshot, name: name, session: session) }
                }
            }.yapperNavigation()
        }
    }
    private func canEdit(_ role: NativeServerRole) -> Bool { model.snapshot?.server.ownerID == model.store.user?.id || role.position < (model.snapshot?.topPosition(model.store.user?.id ?? "") ?? -1) }
}

private struct NativeServerRoleEditor: View {
    let model: NativeServerDetailModel
    let role: NativeServerRole
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var permissions: [String: Bool] = [:]
    @State private var error: String?
    @State private var deleting = false

    private static let choices: [(String, String)] = [
        ("administrator", "Administrator"), ("manage_server", "Server verwalten"), ("manage_channels", "Kanäle verwalten"), ("manage_roles", "Rollen verwalten"), ("manage_emojis", "Emojis verwalten"), ("manage_webhooks", "Webhooks verwalten"), ("manage_events", "Ereignisse verwalten"), ("view_audit_log", "Audit-Protokoll ansehen"),
        ("create_invite", "Einladungen erstellen"), ("change_nickname", "Eigenen Nickname ändern"), ("manage_nicknames", "Nicknames verwalten"), ("kick_members", "Mitglieder entfernen"), ("ban_members", "Mitglieder sperren"), ("timeout_members", "Mitglieder stummschalten"),
        ("send_messages", "Nachrichten senden"), ("add_reactions", "Reaktionen hinzufügen"), ("attach_files", "Dateien anhängen"), ("embed_links", "Linkvorschauen anzeigen"), ("use_external_emojis", "Externe Emojis verwenden"), ("mention_everyone", "Alle erwähnen"), ("manage_messages", "Nachrichten verwalten"), ("create_polls", "Umfragen erstellen"), ("read_history", "Nachrichtenverlauf lesen"), ("send_voice_messages", "Sprachnachrichten senden"), ("use_headings", "Überschriften verwenden"), ("create_threads", "Threads erstellen"), ("send_in_threads", "In Threads schreiben"), ("manage_threads", "Threads verwalten"),
        ("connect", "Sprachkanälen beitreten"), ("speak", "Sprechen"), ("mute_members", "Mitglieder im Anruf stummschalten"), ("move_members", "Mitglieder verschieben")
    ]

    var body: some View {
        Form {
            Section("Rolle") { TextField("Name", text: $name) }
            Section("Berechtigungen") {
                ForEach(Self.choices, id: \.0) { key, title in Toggle(title, isOn: Binding(get: { permissions[key] == true }, set: { permissions[key] = $0 })) }
            }
            if let error { NativeErrorBanner(message: error) }
            if model.isBusy { ProgressView("Wird gespeichert …") }
            Section { Button("Rolle löschen", role: .destructive) { deleting = true } }
        }
        .navigationTitle(role.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Speichern") {
                    Task {
                        do { try await model.perform { api, session in try await api.nativeUpdateRole(role, name: name, permissions: permissions, session: session) }; dismiss() }
                        catch is CancellationError { }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(model.isBusy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { name = role.name; permissions = role.permissions; for (key, _) in Self.choices where role.grants(key) { permissions[key] = true } }
        .confirmationDialog("Rolle löschen?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Rolle löschen", role: .destructive) {
                Task {
                    do { try await model.perform { api, session in try await api.nativeDeleteRole(id: role.id, session: session) }; dismiss() }
                    catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                }
            }
        }.yapperNavigation()
    }
}

private struct NativeServerForumView: View {
    let store: NativeStore
    let channel: NativeServerChannel
    let snapshot: NativeServerSnapshot
    @State private var posts: [NativeForumPost] = []
    @State private var query = ""
    @State private var sort = "activity"
    @State private var following = false
    @State private var selectedTags: Set<String> = []
    @State private var loading = false
    @State private var hasMore = false
    @State private var generation = UUID()
    @State private var error: String?
    @State private var composing = false
    @State private var destination: Conversation?
    @State private var deleting: NativeForumPost?
    @State private var renaming: NativeForumPost?

    private var postList: some View {
        List {
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if !channel.guidelines.isEmpty { Text(channel.guidelines).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) }
            ForEach(posts) { post in
                NavigationLink {
                    NativeConversationView(store: store, conversation: Conversation(id: post.id, title: post.title, participants: [], serverID: channel.serverID))
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack { if post.isClosed { Image(systemName: "lock.fill").accessibilityLabel("Geschlossen") }; Text(post.title).font(OriginalYapper.font(16, weight: .semibold)) }
                        if !post.content.isEmpty { Text(post.content).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).lineLimit(3) }
                        Text("\(post.messages) Nachrichten").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                    }.padding(.vertical, 7)
                }
                .contextMenu {
                    Button("Beitrag folgen") { action { api, session in try await api.nativeThreadState(id: post.id, action: "following", enabled: true, session: session) } }
                    Button("Nicht mehr folgen") { action { api, session in try await api.nativeThreadState(id: post.id, action: "following", enabled: false, session: session) } }
                    if post.authorID == store.user?.id || snapshot.hasPermission("manage_threads", userID: store.user?.id) {
                        Button(post.isClosed ? "Beitrag öffnen" : "Beitrag schließen") { action { api, session in try await api.nativeThreadState(id: post.id, action: "closed", enabled: !post.isClosed, session: session) } }
                        Button("Titel bearbeiten") { renaming = post }
                        Button("Beitrag löschen", role: .destructive) { deleting = post }
                    }
                }
            }
            if loading { ProgressView("Beiträge werden geladen …").frame(maxWidth: .infinity) }
            else if hasMore { Button("Weitere Beiträge laden") { Task { await load(more: true) } }.frame(minHeight: 44) }
            else if posts.isEmpty && error == nil { ContentUnavailableView("Keine Beiträge", systemImage: "text.bubble", description: Text("Erstelle einen Beitrag oder passe deine Suche an.")) }
        }
    }

    var body: some View {
        postList
        .navigationTitle(channel.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Beiträge suchen")
        .toolbar { forumToolbar }
        .task(id: filterIdentity) { await scheduledReload() }
        .refreshable { await load() }
        .sheet(isPresented: $composing) {
            NativeForumComposeView(store: store, channel: channel, isModerator: snapshot.hasPermission("manage_threads", userID: store.user?.id)) { id, title in
                destination = Conversation(id: id, title: title, participants: [], serverID: channel.serverID)
                Task { await load() }
            }
        }
        .sheet(item: $renaming) { post in
            NativeServerTextSheet(title: "Beitrag bearbeiten", field: "Titel", initial: post.title, submit: "Speichern") { title in
                try await store.withAuthenticatedSession { api, session in _ = try await api.rpc("edit_thread", arguments: ["p_thread": .string(post.id), "p_title": .string(try NativeServerInput.name(title)), "p_tags": .array(post.tags.map(NativeJSON.string))], session: session) }
                await load()
            }
        }
        .confirmationDialog("Beitrag dauerhaft löschen?", isPresented: deleteConfirmation, titleVisibility: .visible) { deletionAction }
        .navigationDestination(item: $destination) { conversation in NativeConversationView(store: store, conversation: conversation) }
        .scrollContentBackground(.hidden).background(YapperPalette.background.ignoresSafeArea()).yapperNavigation()
    }

    private var filterIdentity: String { [query, sort, String(following), selectedTags.sorted().joined(separator: ",")].joined(separator: "|") }

    private func scheduledReload() async {
        do {
            if !query.isEmpty { try await Task.sleep(for: .milliseconds(300)) }
            try Task.checkCancellation()
            await load()
        } catch { }
    }

    @ToolbarContentBuilder private var forumToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sortieren", selection: $sort) { Text("Letzte Aktivität").tag("activity"); Text("Neueste Beiträge").tag("new") }
                Toggle("Nur gefolgte Beiträge", isOn: $following)
                ForEach(channel.forumTags) { tag in
                    Toggle(tag.name, isOn: Binding(get: { selectedTags.contains(tag.id) }, set: { if $0 { selectedTags.insert(tag.id) } else { selectedTags.remove(tag.id) } }))
                }
            } label: { Image(systemName: "line.3.horizontal.decrease").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("Beiträge filtern")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { composing = true } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Beitrag erstellen")
        }
    }

    private var deleteConfirmation: Binding<Bool> { Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }) }

    @ViewBuilder private var deletionAction: some View {
        if let post = deleting {
            Button("Beitrag löschen", role: .destructive) {
                action { api, session in _ = try await api.rpc("delete_thread", arguments: ["p_thread": .string(post.id)], session: session) }
            }
        }
    }

    private func load(more: Bool = false) async {
        let current = UUID(); generation = current; loading = true; error = nil
        defer { if generation == current { loading = false } }
        let before = more ? posts.last : nil
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.nativeForumPosts(channelID: channel.id, sort: sort, query: query, tags: selectedTags.sorted(), following: following, before: before, session: session) }
            guard generation == current else { return }
            let existing = more ? posts : []; var seen = Set(existing.map(\.id))
            posts = existing + result.filter { seen.insert($0.id).inserted }; hasMore = result.count == 25
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }

    private func action(_ operation: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) {
        Task { do { try await store.withAuthenticatedSession(operation); await load() } catch is CancellationError { } catch { self.error = error.localizedDescription } }
    }
}

private struct NativeForumComposeView: View {
    let store: NativeStore
    let channel: NativeServerChannel
    let isModerator: Bool
    let onCreated: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var tags: Set<String> = []
    @State private var saving = false
    @State private var error: String?
    private var allowedTags: [NativeForumTag] { channel.forumTags.filter { isModerator || !$0.moderatorOnly } }
    private var canSubmit: Bool { !saving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && content.utf16.count <= 2000 && (!channel.requireTag || allowedTags.isEmpty || !tags.isEmpty) }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Titel", text: $title); TextField("Dein Beitrag", text: $content, axis: .vertical).lineLimit(6...16) }
                if !allowedTags.isEmpty {
                    Section(channel.requireTag ? "Tags · mindestens einer erforderlich" : "Tags") {
                        ForEach(allowedTags) { tag in Toggle(tag.name, isOn: Binding(get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } })) }
                    }
                }
                if let error { NativeErrorBanner(message: error) }
                if saving { ProgressView("Beitrag wird erstellt …") }
                if content.utf16.count > 2000 { Text("Maximal 2.000 Zeichen.").foregroundStyle(YapperPalette.danger) }
            }
            .navigationTitle("Neuer Beitrag").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Erstellen") {
                        Task {
                            saving = true; error = nil
                            defer { saving = false }
                            do {
                                let id = try await store.withAuthenticatedSession { api, session in try await api.nativeCreateForumPost(channelID: channel.id, title: title, content: content, tags: tags.sorted(), session: session) }
                                onCreated(id, title); dismiss()
                            } catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(!canSubmit)
                }
            }.yapperNavigation()
        }.interactiveDismissDisabled(saving)
    }
}
