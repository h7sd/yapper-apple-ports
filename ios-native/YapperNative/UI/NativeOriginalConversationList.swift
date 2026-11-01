import SwiftUI

struct NativeConversationList: View {
    let store: NativeStore
    @Binding var requestedConversation: Conversation?
    var onOpenConversation: ((Conversation) -> Void)? = nil
    var onOpenSurface: ((NativeHomeSheet) -> Void)? = nil
    var preferenceModel = NativeConversationPreferenceModel()
    var reserveFloatingAccount = false
    @State private var search = ""
    @State private var searching = false
    @State private var homeSheet: NativeHomeSheet?
    @State private var conversationPreferences: Conversation?

    private var ordered: [Conversation] { preferenceModel.ordered(store.conversations) }
    private var filtered: [Conversation] { search.isEmpty ? ordered : ordered.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.lastMessage?.localizedCaseInsensitiveContains(search) ?? false) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Direktnachrichten").font(OriginalYapper.font(15, weight: .bold)).lineLimit(1).accessibilityIdentifier("native.original.sidebar.title")
                Spacer(minLength: 0)
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(height: 52)
            .overlay(alignment: .bottom) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
            .contextMenu { Button("Gespräche durchsuchen") { searching = true } }
            .accessibilityAction(named: "Gespräche durchsuchen") { searching = true }
            if searching {
                HStack(spacing: 8) {
                    OriginalYapperIcon("search", size: 16).foregroundStyle(YapperPalette.secondary)
                    TextField("Gespräche durchsuchen", text: $search).font(OriginalYapper.font(14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { search = ""; searching = false } label: { OriginalYapperIcon("close", size: 16).frame(width: 32, height: 44) }.buttonStyle(.plain).accessibilityLabel("Suche schließen")
                }.padding(.leading, 10).background(YapperPalette.input, in: .rect(cornerRadius: 6)).padding(8)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    fixtureNotice
                    action("Freunde", icon: "friends", identifier: "native.home.people", selected: requestedConversation == nil) { surface(.people) }
                    if store.capabilities.flagOn("user_search", userID: store.user?.id) { action("Leute finden", icon: "search", identifier: "native.home.find") { surface(.people) } }
                    action("Gruppe erstellen", icon: "createGroup", identifier: "native.home.group") { surface(.group) }
                    HStack {
                        Text("DIREKTNACHRICHTEN").font(OriginalYapper.font(12, weight: .bold)).tracking(0.48).foregroundStyle(YapperPalette.secondary)
                        Spacer()
                        Button { surface(.group) } label: { OriginalYapperIcon("plus", size: 18).frame(width: 32, height: 44) }.buttonStyle(.plain).foregroundStyle(YapperPalette.secondary).accessibilityLabel("Neue Gruppe")
                    }.padding(.leading, 8).padding(.top, 6)
                    if let error = store.errorMessage { NativeErrorBanner(message: error) { Task { await store.loadConversations() } }.padding(.vertical, 8) }
                    if store.isLoadingConversations && ordered.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
                    else if filtered.isEmpty { Text(search.isEmpty ? "Noch keine Gespräche." : "Keine Treffer.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 12) }
                    ForEach(filtered) { conversation in
                        Button { open(conversation) } label: {
                            NativeConversationRow(conversation: conversation, selected: requestedConversation?.id == conversation.id, pinned: preferenceModel.snapshot?.pins.contains(conversation.id) == true, muted: preferenceModel.isMuted(conversation.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("native.conversation.\(conversation.id)")
                        .contextMenu {
                            if preferenceModel.snapshot?.capabilities.pin == true {
                                Button(preferenceModel.snapshot?.pins.contains(conversation.id) == true ? "Lösen" : "Anheften") { Task { await preferenceModel.pin(conversation, store: store) } }
                            }
                            if preferenceModel.snapshot != nil {
                                Menu("Benachrichtigungen") {
                                    ForEach(preferenceModel.snapshot?.capabilities.timedMute == true ? NativeConversationMuteDuration.allCases : [.off, .forever]) { duration in
                                        Button(duration.label) { Task { await preferenceModel.mute(conversation, duration: duration, store: store) } }
                                    }
                                }
                            }
                            if preferenceModel.snapshot?.capabilities.hide == true {
                                Button(conversation.isGroup ? "Gruppe ausblenden" : "Chat schließen") { Task { await preferenceModel.hide(conversation, store: store) } }
                            }
                            Button("Chat-Einstellungen", systemImage: "slider.horizontal.3") { conversationPreferences = conversation }
                        }
                    }
                }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, reserveFloatingAccount ? 90 : 12)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("native.conversations.list")
            .refreshable { await store.loadConversations(); await preferenceModel.load(store: store) }
        }
        .background(YapperPalette.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.original.sidebar")
        .onChange(of: requestedConversation?.id) { _, id in if let id { preferenceModel.revealOpenedConversation(id) } }
        .sheet(item: $conversationPreferences) { conversation in NativeConversationPreferencesView(store: store, conversation: conversation, model: preferenceModel) }
        .sheet(item: $homeSheet) { value in
            NavigationStack {
                Group {
                    switch value {
                    case .people: NativePeopleView(store: store, onOpenConversation: open)
                    case .inbox: NativeInboxView(store: store, onOpenConversation: open)
                    case .group: NativeGroupEditor(store: store, onOpenConversation: open)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { homeSheet = nil } } }
            }
        }
        .task(id: store.user?.id) { await store.loadConversations(); await preferenceModel.load(store: store) }
    }

    private func surface(_ value: NativeHomeSheet) { if let onOpenSurface { onOpenSurface(value) } else { homeSheet = value } }
    private func open(_ conversation: Conversation) {
        homeSheet = nil
        if let onOpenConversation { onOpenConversation(conversation) } else { requestedConversation = conversation }
    }

    private func action(_ label: String, icon: String, identifier: String, selected: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                OriginalYapperIcon(icon, size: 22).frame(width: 28)
                Text(label).font(OriginalYapper.font(15, weight: selected ? .semibold : .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(selected ? YapperPalette.text : YapperPalette.secondary)
            .padding(.horizontal, 8).frame(minHeight: 44)
            .background(selected ? YapperPalette.active : .clear, in: .rect(cornerRadius: 8)).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var fixtureNotice: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") {
            Text("Testansicht · Beispieldaten").font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).accessibilityIdentifier("native.fixture.notice")
        }
        #endif
    }
}

private struct NativeConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    let pinned: Bool
    let muted: Bool
    var body: some View {
        HStack(spacing: 10) {
            if conversation.isGroup && conversation.avatarURL == nil {
                OriginalYapperIcon("friends", size: 20).foregroundStyle(.white).frame(width: 32, height: 32).background(YapperPalette.accentFill, in: .circle)
            } else {
                NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id ?? conversation.id, username: conversation.participants.first?.username ?? conversation.title, url: conversation.avatarURL, presence: conversation.participants.first?.presence ?? "unknown", size: 32,
                             decorationURL: conversation.participants.first?.avatarDecorationURL, crop: conversation.participants.first?.avatarCrop ?? .centered)
            }
            VStack(alignment: .leading, spacing: 1) {
                NativeDisplayName(name: conversation.title, bannerURL: conversation.isGroup ? nil : conversation.participants.first?.nameBannerURL)
                    .font(OriginalYapper.font(15, weight: conversation.unreadCount > 0 && !muted ? .semibold : .medium)).lineLimit(1)
                if conversation.isGroup { Text("\(conversation.participants.count + 1) Mitglieder").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.faint).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if pinned { OriginalYapperIcon("pin", size: 14).foregroundStyle(YapperPalette.faint).accessibilityLabel("Angeheftet") }
            if conversation.unreadCount > 0 && !muted { NativeOriginalBadge(count: conversation.unreadCount) }
        }
        .foregroundStyle(selected || conversation.unreadCount > 0 && !muted ? YapperPalette.text : YapperPalette.secondary)
        .opacity(muted ? 0.5 : 1)
        .padding(.horizontal, 8).padding(.vertical, 7).frame(minHeight: 44)
        .background(selected ? YapperPalette.active : .clear, in: .rect(cornerRadius: 8)).contentShape(.rect)
    }
}
