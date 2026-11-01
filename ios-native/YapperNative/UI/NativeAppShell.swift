import SwiftUI

enum NativeHomeSheet: String, Identifiable {
    case people, inbox, group
    var id: String { rawValue }
}

struct NativeAppShell: View {
    let store: NativeStore
    @Environment(NativeCallController.self) private var call
    @State private var requestedConversation: Conversation?
    @State private var mobilePath: [Conversation] = []
    @State private var selectedServer: NativeServer?
    @State private var lastServer: NativeServer?
    @State private var servers: NativeServerLibraryModel
    @State private var compact = true
    @State private var showingSettings = false
    @State private var showingProfile = false
    @State private var showingAccountMenu = false
    @State private var showingServerActions = false
    @State private var creatingServer = false
    @State private var joiningServer = false
    @State private var discoveringServers = false
    @State private var confirmingLogout = false
    @State private var homeSheet: NativeHomeSheet?
    @State private var conversationPreferences = NativeConversationPreferenceModel()
    @AppStorage("yapper-rail-dms") private var railDMPreference = ""

    init(store: NativeStore) {
        self.store = store
        _servers = State(initialValue: NativeServerLibraryModel(store: store))
    }

    private var unread: Int { conversationPreferences.ordered(store.conversations).filter { !conversationPreferences.isMuted($0.id) }.reduce(0) { $0 + $1.unreadCount } }
    private var recentUnreadConversations: [Conversation] {
        guard railDMPreference != "off", store.capabilities.flagOn("ui_refresh", userID: store.user?.id) else { return [] }
        #if DEBUG
        if !ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") && conversationPreferences.snapshot == nil { return [] }
        #else
        guard conversationPreferences.snapshot != nil else { return [] }
        #endif
        let visible = conversationPreferences.ordered(store.conversations)
        let muted = Set(visible.filter { conversationPreferences.isMuted($0.id) }.map(\.id))
        // Until an authoritative per-channel mention count is available, do not
        // guess the source's muted-with-mention exception.
        return NativeRecentUnreadRail.select(visible, activeID: requestedConversation?.id ?? store.selectedConversation?.id, mutedIDs: muted)
    }

    var body: some View {
        @Bindable var activeCall = call
        NavigationStack(path: $mobilePath) {
            GeometryReader { geometry in
                let small = geometry.size.width <= 760
                ZStack(alignment: .bottomLeading) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            NativeOriginalRail(servers: servers.servers, recentConversations: recentUnreadConversations, selectedServerID: selectedServer?.id, compact: small, unread: unread, showDiscovery: store.capabilities.flagOn("discovery", userID: store.user?.id),
                                               onHome: openHome, onServer: openServer, onConversation: openConversation, onAdd: { showingServerActions = true }, onDiscover: { discoveringServers = true })
                            VStack(spacing: 0) {
                                sidebar
                                if small, let user = store.user { accountBar(user, compact: true).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 10) }
                            }
                            .frame(width: small ? nil : 260)
                            .frame(maxWidth: small ? .infinity : nil, maxHeight: .infinity)
                            .background(YapperPalette.sidebar.ignoresSafeArea(.container, edges: .top))
                            if !small {
                                Rectangle().fill(YapperPalette.border).frame(width: 1)
                                stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        if small {
                            NativeOriginalBottomBar(unread: unread, serverSelected: selectedServer != nil, serversAvailable: !servers.servers.isEmpty,
                                                    onHome: openHome, onServers: openLastServer, onSettings: { showingSettings = true })
                        }
                    }
                    if !small, let user = store.user {
                        accountBar(user, compact: false).frame(width: 316).padding(.leading, 8).padding(.bottom, 8).zIndex(10)
                    }
                    if showingAccountMenu {
                        Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { showingAccountMenu = false }
                        fittedAccountMenu(availableHeight: max(200, geometry.size.height - (small ? 116 : 82) - 8))
                            .frame(width: min(300, geometry.size.width - 16))
                            .padding(.leading, 8)
                            .padding(.bottom, small ? 116 : 82)
                            .accessibilityElement(children: .contain)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("native.original.accountMenu")
                            .zIndex(20)
                    }
                }
                .background(YapperPalette.background.ignoresSafeArea())
                .onAppear { compact = small }
                .onChange(of: small) { _, value in
                    compact = value
                    if value, let requestedConversation { mobilePath = [requestedConversation] }
                    else if !value { mobilePath = [] }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Conversation.self) { conversation in
                NativeConversationView(store: store, conversation: conversation, onBack: { mobilePath = []; requestedConversation = nil })
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(YapperPalette.accent)
        .safeAreaInset(edge: .bottom, spacing: 0) { NativeCallBar() }
        .background(YapperPalette.background.ignoresSafeArea())
        .onChange(of: requestedConversation?.id) { _, id in
            if compact, id != nil, let requestedConversation { mobilePath = [requestedConversation] }
        }
        .onChange(of: mobilePath.count) { _, count in if compact && count == 0 { requestedConversation = nil } }
        .task(id: store.user?.id) {
            await servers.refresh(); await conversationPreferences.load(store: store)
            store.updateNotificationPreferences(conversationPreferences.snapshot)
            await store.refreshNotificationSoundContext()
        }
        .onChange(of: conversationPreferences.snapshot?.muted) { _, _ in store.updateNotificationPreferences(conversationPreferences.snapshot) }
        .onChange(of: conversationPreferences.snapshot?.hidden) { _, _ in store.updateNotificationPreferences(conversationPreferences.snapshot) }
        .fullScreenCover(isPresented: $showingSettings) {
            NativeAccountView(store: store, onOpenConversation: { conversation in showingSettings = false; openConversation(conversation) })
        }
        .fullScreenCover(isPresented: $showingProfile) {
            NavigationStack { NativeProfileView(store: store, userID: store.user?.id ?? "", presentation: .overlay, onOpenConversation: { conversation in showingProfile = false; openConversation(conversation) }) }.presentationBackground(.clear)
        }
        .sheet(item: $homeSheet) { surface in
            NavigationStack {
                Group {
                    switch surface {
                    case .people: NativePeopleView(store: store, onOpenConversation: openConversation)
                    case .inbox: NativeInboxView(store: store, onOpenConversation: openConversation)
                    case .group: NativeGroupEditor(store: store, onOpenConversation: openConversation)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { homeSheet = nil }.frame(minHeight: 44) } }
                .yapperNavigation()
            }
        }
        .confirmationDialog("Server hinzufügen", isPresented: $showingServerActions, titleVisibility: .visible) {
            Button("Server erstellen") { creatingServer = true }
            Button("Server beitreten") { joiningServer = true }
            Button("Abbrechen", role: .cancel) { }
        }
        .sheet(isPresented: $creatingServer) {
            NativeServerTextSheet(title: "Server erstellen", field: "Servername", submit: "Erstellen") { name in
                let id = try await store.withAuthenticatedSession { api, session in try await api.nativeCreateServer(name: name, session: session) }
                await servers.refresh()
                if let server = servers.servers.first(where: { $0.id == id }) { openServer(server) }
            }
        }
        .sheet(isPresented: $joiningServer) {
            NativeServerJoinView(store: store) { id in await servers.refresh(); if let server = servers.servers.first(where: { $0.id == id }) { openServer(server) } }
        }
        .sheet(isPresented: $discoveringServers, onDismiss: { Task { await servers.refresh() } }) { NativeServerDiscoveryView(store: store) }
        .confirmationDialog("Von Yapper abmelden?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("Abmelden", role: .destructive) { store.signOut() }.accessibilityIdentifier("native.settings.signOut.confirm")
            Button("Abbrechen", role: .cancel) { }
        }
        .sheet(isPresented: $activeCall.presented) { NativeCallView() }
        .confirmationDialog(store.incomingCall.map { "Anruf: \($0.title)" } ?? "Eingehender Anruf", isPresented: Binding(get: { store.incomingCall != nil }, set: { if !$0 { store.dismissIncomingCall() } }), titleVisibility: .visible) {
            if let incoming = store.incomingCall {
                Button("Annehmen") {
                    store.dismissIncomingCall()
                    Task { await call.join(store: store, channelID: incoming.channelID, title: incoming.title, startNewCall: false) }
                }
                Button("Ablehnen", role: .cancel) { store.dismissIncomingCall() }
            }
        }
        .accessibilityIdentifier("native.original.shell")
    }

    private var originalAccountMenu: some View {
        OriginalAccountMenuView(store: store, onOpenProfile: { showingAccountMenu = false; showingProfile = true }, onOpenSettings: { showingAccountMenu = false; showingSettings = true }, onClose: { showingAccountMenu = false })
    }

    private func fittedAccountMenu(availableHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            originalAccountMenu.fixedSize(horizontal: false, vertical: true)
            ScrollView { originalAccountMenu }
        }.frame(maxHeight: availableHeight, alignment: .bottom)
    }

    @ViewBuilder private var sidebar: some View {
        if let selectedServer {
            NativeServerDetailView(store: store, server: selectedServer, onJoinVoice: { channel in Task { await call.join(store: store, channelID: channel.id, title: channel.name, serverID: channel.serverID) } }, onOpenConversation: openConversation, originalSidebar: true, reserveFloatingAccount: !compact, onServerLeft: { openHome(); Task { await servers.refresh() } })
                .id(selectedServer.id)
        } else {
            NativeConversationList(store: store, requestedConversation: $requestedConversation, onOpenConversation: openConversation, onOpenSurface: openHomeSurface, preferenceModel: conversationPreferences, reserveFloatingAccount: !compact)
        }
    }

    @ViewBuilder private var stage: some View {
        if let requestedConversation {
            NativeConversationView(store: store, conversation: requestedConversation, onBack: { self.requestedConversation = nil }, compactPresentation: false)
                .id(requestedConversation.id)
        } else if selectedServer == nil {
            NativePeopleView(store: store, showBackButton: false, onOpenConversation: openConversation)
        } else {
            Color.clear.overlay { OriginalYapperIcon("servers", size: 64).foregroundStyle(YapperPalette.faint) }.background(YapperPalette.input)
        }
    }

    private func accountBar(_ user: YapperUser, compact: Bool) -> some View {
        NativeOriginalAccountBar(user: user, compact: compact, mentions: 0, showInbox: store.capabilities.flagOn("mentions_inbox", userID: user.id) || store.capabilities.flagOn("notif_inbox", userID: user.id),
                                 onIdentity: { showingAccountMenu.toggle() }, onInbox: { homeSheet = .inbox },
                                 onSettings: { showingSettings = true }, onLogout: { confirmingLogout = true })
    }

    private func openHomeSurface(_ surface: NativeHomeSheet) {
        if surface == .people && !compact {
            selectedServer = nil; requestedConversation = nil; mobilePath = []; homeSheet = nil
        } else { homeSheet = surface }
    }

    private func openHome() { selectedServer = nil; requestedConversation = nil; mobilePath = []; showingAccountMenu = false }
    private func openServer(_ server: NativeServer) { selectedServer = server; lastServer = server; requestedConversation = nil; mobilePath = []; showingAccountMenu = false }
    private func openLastServer() { if let server = servers.servers.first(where: { $0.id == lastServer?.id }) ?? servers.servers.sorted(by: { ($0.raw["created_at"].string ?? "") < ($1.raw["created_at"].string ?? "") }).first { openServer(server) } }
    private func openConversation(_ conversation: Conversation) { if conversation.serverID == nil { selectedServer = nil }; homeSheet = nil; showingAccountMenu = false; requestedConversation = conversation }
}
