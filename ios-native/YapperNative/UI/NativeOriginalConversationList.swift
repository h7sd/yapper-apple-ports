import SwiftUI

struct NativeConversationList: View {
    let store: NativeStore
    @Binding var requestedConversation: Conversation?
    var onOpenConversation: ((Conversation) -> Void)? = nil
    var onOpenSurface: ((NativeHomeSheet) -> Void)? = nil
    var preferenceModel = NativeConversationPreferenceModel()
    var reserveFloatingAccount = false
    var floatingAccountInset: CGFloat = 100
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var friendsLabelWidth: CGFloat = 78
    @FocusState private var searchFocused: Bool
    @State private var search = ""
    @State private var searching = false
    @State private var homeSheet: NativeHomeSheet?
    @State private var conversationPreferences: Conversation?

    private var ordered: [Conversation] { preferenceModel.ordered(store.conversations) }
    private var filtered: [Conversation] { search.isEmpty ? ordered : ordered.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.lastMessage?.localizedCaseInsensitiveContains(search) ?? false) } }
    private var showInbox: Bool { store.capabilities.flagOn("mentions_inbox", userID: store.user?.id) || store.capabilities.flagOn("notif_inbox", userID: store.user?.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching {
                HStack(spacing: 8) {
                    OriginalYapperIcon("search", size: 16).foregroundStyle(YapperPalette.secondary)
                    TextField("Gespräche durchsuchen", text: $search).font(OriginalYapper.font(14)).textInputAutocapitalization(.never).autocorrectionDisabled().focused($searchFocused).submitLabel(.search).accessibilityIdentifier("native.home.search.field")
                    Button { search = ""; searching = false; searchFocused = false } label: { OriginalYapperIcon("close", size: 16).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Suche schließen")
                }.padding(.leading, 12).background(YapperPalette.input, in: .rect(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 10)
                    .onAppear { searchFocused = true }
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    fixtureNotice
                    if let error = store.errorMessage { NativeErrorBanner(message: error) { Task { await store.loadConversations() } }.padding(.vertical, 8) }
                    if store.isLoadingConversations && ordered.isEmpty { ProgressView().frame(maxWidth: .infinity, minHeight: 44) }
                    else if filtered.isEmpty { Text(search.isEmpty ? "Noch keine Gespräche." : "Keine Treffer.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 12) }
                    ForEach(filtered) { conversation in
                        Button { open(conversation) } label: {
                            NativeConversationRow(conversation: liveConversation(conversation), selected: requestedConversation?.id == conversation.id, pinned: preferenceModel.snapshot?.pins.contains(conversation.id) == true, muted: preferenceModel.isMuted(conversation.id), callMembers: store.voiceMembers[conversation.id] ?? [])
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
                }.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, reserveFloatingAccount ? floatingAccountInset : 12)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("native.conversations.list")
            .refreshable { await store.loadConversations(); await store.refreshLiveState(); await preferenceModel.load(store: store) }
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
                    case .addFriend: NativeHomeAddFriendView(store: store, onShowFriends: { homeSheet = .people })
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { homeSheet = nil } } }
            }
        }
        .task(id: store.user?.id) { await store.loadConversations(); await preferenceModel.load(store: store) }
    }

    private func surface(_ value: NativeHomeSheet) { if let onOpenSurface { onOpenSurface(value) } else { homeSheet = value } }
    private func liveConversation(_ value: Conversation) -> Conversation {
        var live = value
        live.participants = value.participants.map(store.userWithLivePresence)
        return live
    }
    private func open(_ conversation: Conversation) {
        homeSheet = nil
        if let onOpenConversation { onOpenConversation(conversation) } else { requestedConversation = conversation }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nachrichten").font(OriginalYapper.font(16, weight: .bold))
                .foregroundStyle(YapperPalette.text).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("native.original.sidebar.title")
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 0) { searchButton; inboxButton; Spacer(minLength: 0); groupButton }
                friendsButton
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { searchButton; inboxButton; friendsButton; groupButton }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 0) { searchButton; inboxButton; Spacer(minLength: 0); groupButton }
                        friendsButton
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.home.toolbar")
    }

    private var searchButton: some View {
        toolbarButton("Gespräche durchsuchen", icon: "search", identifier: "native.home.search") { searching.toggle(); if !searching { search = ""; searchFocused = false } }
    }

    @ViewBuilder private var inboxButton: some View {
        if showInbox { toolbarButton("Mitteilungen & Erwähnungen", icon: "inbox", identifier: "native.home.toolbar.inbox") { surface(.inbox) } }
    }

    private var groupButton: some View {
        toolbarButton("Neue Gruppe", icon: "plus", identifier: "native.home.group", accent: true) { surface(.group) }
    }

    private var friendsButton: some View {
        Button { surface(.addFriend) } label: {
            HStack(spacing: 6) {
                OriginalYapperIcon("friends", size: 18)
                    .overlay(alignment: .bottomTrailing) { OriginalYapperIcon("plus", size: 10).offset(x: 3, y: 2) }
                Text("Freunde hinzufügen").font(OriginalYapper.font(13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : friendsLabelWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8).frame(minWidth: 118, maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(YapperPalette.text)
            .background(YapperPalette.elevated, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YapperPalette.border, lineWidth: 1))
            .padding(6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel("Freunde hinzufügen").accessibilityIdentifier("native.home.people")
        .contextMenu {
            Button("Freunde") { surface(.people) }
            if store.capabilities.flagOn("user_search", userID: store.user?.id) {
                Button("Leute finden") { surface(.people) }.accessibilityIdentifier("native.home.find")
            }
        }
    }

    private func toolbarButton(_ title: String, icon: String, identifier: String, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            OriginalYapperIcon(icon, size: 18).frame(width: 32, height: 32)
                .foregroundStyle(accent ? YapperPalette.onAccent : YapperPalette.secondary)
                .background(accent ? YapperPalette.accentFill : YapperPalette.elevated, in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(YapperPalette.border, lineWidth: 1))
                .padding(6)
                .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityIdentifier(identifier)
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
    var callMembers: [NativeVoiceMember] = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var preview: String? {
        if let message = conversation.lastMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
        return conversation.isGroup ? "\(conversation.participants.count + 1) Mitglieder" : nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if conversation.isGroup && conversation.avatarURL == nil {
                OriginalYapperIcon("friends", size: 18).foregroundStyle(.white).frame(width: 32, height: 32).background(YapperPalette.accentFill, in: .circle)
            } else {
                NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id ?? conversation.id, username: conversation.participants.first?.username ?? conversation.title, url: conversation.avatarURL, presence: conversation.participants.first?.presence ?? "unknown", size: 32,
                             decorationURL: conversation.participants.first?.avatarDecorationURL, crop: conversation.participants.first?.avatarCrop ?? .centered)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeDisplayName(name: conversation.title, bannerURL: conversation.isGroup ? nil : conversation.participants.first?.nameBannerURL)
                        .font(OriginalYapper.font(15, weight: conversation.unreadCount > 0 && !muted ? .semibold : .medium))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !dynamicTypeSize.isAccessibilitySize { metadata }
                }
                if let preview {
                    Text(verbatim: preview).font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.faint)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
                if dynamicTypeSize.isAccessibilitySize { metadata }
                if !callMembers.isEmpty {
                    Label("\(callMembers.count) im Anruf", systemImage: "phone.fill")
                        .font(OriginalYapper.font(12, weight: .medium)).foregroundStyle(YapperPalette.success)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(selected || conversation.unreadCount > 0 && !muted ? YapperPalette.text : YapperPalette.secondary)
        .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 52)
        .background(selected ? YapperPalette.active : .clear, in: .rect(cornerRadius: 8)).contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue([pinned ? "Angeheftet" : "", muted ? "Stummgeschaltet" : "",
                             conversation.isGroup ? "" : NativePresenceLabel.text(conversation.participants.first?.presence ?? "unknown")].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            if pinned { OriginalYapperIcon("pin", size: 12).accessibilityLabel("Angeheftet") }
            if muted { OriginalYapperIcon("bell", size: 12).overlay { Rectangle().frame(width: 15, height: 1).rotationEffect(.degrees(-45)) }.accessibilityLabel("Stummgeschaltet") }
            if let date = conversation.lastMessageAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.timeLabel(date, now: context.date)).font(OriginalYapper.font(11))
                        .accessibilityLabel(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if conversation.unreadCount > 0 && !muted { NativeOriginalBadge(count: conversation.unreadCount) }
        }
        .foregroundStyle(YapperPalette.faint)
        .fixedSize(horizontal: true, vertical: false)
    }

    private static func timeLabel(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Jetzt" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 2_592_000 { return "\(Int(seconds / 86_400))d" }
        if seconds < 31_536_000 { return "\(Int(seconds / 2_592_000))mo" }
        return "\(Int(seconds / 31_536_000))y"
    }
}

/// The existing username-and-note friend action, directly reachable from home.
struct NativeHomeAddFriendView: View {
    let store: NativeStore
    let onShowFriends: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: NativeSocialModel
    @State private var username = ""
    @State private var note = ""
    @State private var sent = false

    init(store: NativeStore, onShowFriends: @escaping @MainActor () -> Void) {
        self.store = store
        self.onShowFriends = onShowFriends
        _model = State(initialValue: NativeSocialModel(store: store))
    }

    var body: some View {
        OriginalModalPage("Freund hinzufügen", subtitle: "Du kannst Freunde über ihren Yapper-Benutzernamen hinzufügen.", onClose: { dismiss() }) {
            Button("Freunde anzeigen", action: onShowFriends)
                .buttonStyle(OriginalYapperButtonStyle())
                .accessibilityIdentifier("native.home.addFriend.showFriends")
            OriginalSettingsField("Benutzername") {
                TextField("username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(OriginalYapperTextFieldStyle()).accessibilityIdentifier("native.home.addFriend.username")
            }
            OriginalSettingsField("Notiz (optional)") {
                TextField("Woher kennt ihr euch?", text: $note, axis: .vertical).lineLimit(1...4)
                    .textFieldStyle(OriginalYapperTextFieldStyle())
            }
            Text("\(note.utf16.count)/100").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            if sent { Text("Freundschaftsanfrage gesendet.").foregroundStyle(YapperPalette.success) }
            if let error = model.error { NativeErrorBanner(message: error) }
        } footer: {
            Button("Abbrechen") { dismiss() }.buttonStyle(OriginalYapperButtonStyle())
            Button(model.isBusy ? "Wird gesendet …" : "Senden") {
                Task {
                    await model.act(.request(username: username, note: note))
                    if model.error == nil { sent = true; username = ""; note = "" }
                }
            }
            .buttonStyle(OriginalYapperButtonStyle(primary: true))
            .disabled(model.isBusy || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf16.count > 100)
            .accessibilityIdentifier("native.home.addFriend.send")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.home.addFriend.sheet")
    }
}
