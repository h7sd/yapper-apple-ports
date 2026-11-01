import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct NativePeopleView: View {
    let store: NativeStore
    let showBackButton: Bool
    let onOpenConversation: @MainActor (Conversation) -> Void
    @State private var model: NativeSocialModel
    @State private var query = ""
    @State private var filter = 0
    @State private var showingGroup = false
    @State private var showingRequest = false
    @State private var showingSearch = false
    @State private var requestName = ""
    @State private var requestNote = ""
    @State private var featureFlags: Set<String> = []
    @State private var selectedProfileID: String?
    @State private var pendingProfileConversation: Conversation?
    @State private var sentRequest = false
    @Environment(\.dismiss) private var dismiss

    init(store: NativeStore, showBackButton: Bool = true, onOpenConversation: @escaping @MainActor (Conversation) -> Void) {
        self.store = store; self.showBackButton = showBackButton; self.onOpenConversation = onOpenConversation
        _model = State(initialValue: NativeSocialModel(store: store))
    }
    private var filteredFriends: [NativeFriendEntry] {
        model.snapshot.friends.filter { entry in
            guard entry.relation == .accepted else { return false }
            return filter != 3 || ["online", "idle", "dnd", "away", "busy"].contains(presence(entry.id))
        }
    }
    private func presence(_ id: String) -> String { store.peerPresence(userID: id) }
    private func presenceLabel(_ id: String) -> String {
        switch presence(id) { case "online": "Online"; case "idle", "away": "Abwesend"; case "dnd", "busy": "Nicht stören"; case "offline", "invisible": "Offline"; default: "" }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if showBackButton { Button { dismiss() } label: { OriginalYapperIcon("chevronLeft", size: 20).frame(width: 36, height: 44) }.buttonStyle(.plain).accessibilityLabel("Zurück") }
                HStack(spacing: 8) { OriginalYapperIcon("friends", size: 20); Text("Freunde").font(OriginalYapper.font(16, weight: .bold)) }.padding(.trailing, 12).overlay(alignment: .trailing) { Rectangle().fill(YapperPalette.border).frame(width: 1, height: 24) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        friendsTab("Online", value: 3)
                        friendsTab("Alle", value: 0)
                        friendsTab("Anfragen", value: 1)
                        friendsTab("Blockiert", value: 2)
                        if featureFlags.contains("interest_matches") {
                            NavigationLink { NativeSuggestedPeopleView(store: store, onOpenConversation: onOpenConversation) } label: { Text("Vorschläge").font(OriginalYapper.font(14, weight: .semibold)).padding(.horizontal, 10).frame(minHeight: 36) }.buttonStyle(.plain).accessibilityIdentifier("native.people.suggested")
                        }
                        Button { sentRequest = false; showingRequest = true } label: { Text("Freund hinzufügen").font(OriginalYapper.font(14, weight: .semibold)).padding(.horizontal, 10).frame(minHeight: 32).background(Color(red: 26/255, green: 122/255, blue: 69/255), in: .rect(cornerRadius: 6)).foregroundStyle(.white) }.buttonStyle(.plain)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("native.people.filter")
                Menu {
                    Button("Freund hinzufügen") { sentRequest = false; showingRequest = true }
                    Button("Neue Gruppe") { showingGroup = true }
                    Button("Personen finden") { showingSearch = true }
                } label: { OriginalYapperIcon("plus", size: 18).frame(width: 36, height: 44) }.accessibilityLabel("Personen hinzufügen").accessibilityIdentifier("native.people.add")
            }.padding(.trailing, 8).frame(minHeight: 52).background(YapperPalette.background).overlay(alignment: .bottom) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.isFixture { NativeSocialFixtureNotice().padding(.vertical, 8) }
                    if let error = model.error { NativeErrorBanner(message: error) { Task { await model.load() } } }
                    HStack(spacing: 8) {
                        TextField("Suchen", text: $query).font(OriginalYapper.font(14)).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Personen finden")
                        OriginalYapperIcon("search", size: 18).foregroundStyle(YapperPalette.secondary)
                    }.padding(.horizontal, 12).frame(minHeight: 40).background(YapperPalette.rail, in: .rect(cornerRadius: 8)).padding(.top, 8).padding(.bottom, 12)
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sectionLabel("Suchergebnisse", count: model.searchResults.count)
                        if model.searchResults.isEmpty { emptyMessage(query.count < 2 ? "Gib mindestens zwei Zeichen ein." : "Niemanden gefunden.") }
                        ForEach(model.searchResults) { profile in personRow(profile, subtitle: "@\(profile.username)") { messageButton(profile) } }
                    } else if model.isLoading && model.snapshot.friends.isEmpty {
                        ProgressView("Personen werden geladen …").frame(maxWidth: .infinity, minHeight: 120)
                    } else if filter == 0 || filter == 3 {
                        sectionLabel(filter == 3 ? "Online" : "Alle Freunde", count: filteredFriends.count)
                        if filteredFriends.isEmpty { emptyMessage(filter == 3 ? "Gerade ist niemand online." : "Noch keine Freunde. Füge jemanden über den Benutzernamen hinzu.") }
                        ForEach(filteredFriends) { entry in
                            personRow(entry.profile, subtitle: presenceLabel(entry.id)) {
                                messageButton(entry.profile)
                                Menu {
                                    Button("Profil") { selectedProfileID = entry.id }
                                    Button("Freundschaft entfernen", role: .destructive) { Task { await model.act(.remove(entry.id)) } }
                                    Button("Blockieren", role: .destructive) { Task { await model.act(.block(entry.id)) } }
                                } label: { roundIcon("more") }.accessibilityLabel("Weitere Aktionen für \(entry.profile.displayName)")
                            }
                        }
                    } else if filter == 1 { friendRequests }
                    else {
                        sectionLabel("Blockiert", count: model.snapshot.blocked.count)
                        if model.snapshot.blocked.isEmpty { emptyMessage("Du hast niemanden blockiert.") }
                        ForEach(model.snapshot.blocked) { profile in
                            personRow(profile, subtitle: "Blockiert") {
                                Button("Freigeben") { Task { await model.act(.unblock(profile.id)) } }.buttonStyle(OriginalYapperButtonStyle())
                            }
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
            }
            .refreshable { await model.load() }
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
        .background(YapperPalette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar).disabled(model.isBusy)
        .task { await model.load(); await loadFeatureFlags() }
        .task(id: query) { await model.search(query) }
        .fullScreenCover(isPresented: Binding(get: { selectedProfileID != nil }, set: { if !$0 { selectedProfileID = nil } }), onDismiss: {
            if let conversation = pendingProfileConversation { pendingProfileConversation = nil; onOpenConversation(conversation) }
        }) {
            if let id = selectedProfileID { NavigationStack { NativeProfileView(store: store, userID: id, presentation: .overlay) { conversation in pendingProfileConversation = conversation; selectedProfileID = nil } }.presentationBackground(.clear) }
        }
        .sheet(isPresented: $showingGroup) { NavigationStack { NativeGroupEditor(store: store, onOpenConversation: onOpenConversation) } }
        .sheet(isPresented: $showingRequest) { requestSheet }
        .sheet(isPresented: $showingSearch) { searchSheet }
    }
    private func friendsTab(_ title: String, value: Int) -> some View {
        Button { filter = value; query = "" } label: { Text(title).font(OriginalYapper.font(14, weight: .semibold)).padding(.horizontal, 10).frame(minHeight: 36).foregroundStyle(filter == value ? YapperPalette.text : YapperPalette.secondary).background(filter == value ? YapperPalette.active : .clear, in: .rect(cornerRadius: 6)) }.buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : []).accessibilityIdentifier("native.people.filter.\(value)")
    }
    private func sectionLabel(_ title: String, count: Int) -> some View {
        Text("\(title.uppercased()) — \(count)").font(OriginalYapper.font(11, weight: .bold)).tracking(0.66).foregroundStyle(YapperPalette.secondary).padding(.leading, 4).padding(.vertical, 12)
    }
    private func emptyMessage(_ value: String) -> some View { Text(value).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 4) }
    private func roundIcon(_ name: String) -> some View { OriginalYapperIcon(name, size: 18).frame(width: 36, height: 36).contentShape(.interaction, Rectangle().inset(by: -4)).foregroundStyle(YapperPalette.secondary).background(YapperPalette.rail, in: .circle) }
    private func messageButton(_ profile: NativeProfileDetail) -> some View {
        Button { Task { if let conversation = await model.openDM(profile) { onOpenConversation(conversation) } } } label: { roundIcon("inbox") }.buttonStyle(.plain).accessibilityLabel("Nachricht an \(profile.displayName)")
    }
    private func personRow<Actions: View>(_ profile: NativeProfileDetail, subtitle: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 12) {
            Button {
                if showingSearch {
                    Task { if let conversation = await model.openDM(profile) { showingSearch = false; onOpenConversation(conversation) } }
                } else { selectedProfileID = profile.id }
            } label: {
                HStack(spacing: 12) {
                    NativeAvatar(name: profile.displayName, identity: profile.id, username: profile.username, url: profile.avatarURL, presence: presence(profile.id), size: 36, decorationURL: profile.user.avatarDecorationURL, crop: profile.user.avatarCrop)
                    VStack(alignment: .leading, spacing: 2) {
                        NativeDisplayName(name: profile.displayName, bannerURL: profile.user.nameBannerURL).font(OriginalYapper.font(15, weight: .semibold)).lineLimit(1)
                        Text(subtitle.isEmpty ? "@\(profile.username)" : subtitle).font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("native.people.\(profile.id)")
            HStack(spacing: 8) { actions() }
        }.padding(.vertical, 10).padding(.horizontal, 8).overlay(alignment: .top) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
    }
    @ViewBuilder private var friendRequests: some View {
        let requests = model.snapshot.friends.filter { $0.relation != .accepted }
        sectionLabel("Anfragen", count: requests.count)
        if requests.isEmpty { emptyMessage("Keine offenen Freundschaftsanfragen.") }
        ForEach(requests) { entry in
            VStack(alignment: .leading, spacing: 0) {
                personRow(entry.profile, subtitle: entry.relation.label) {
                    if entry.relation == .incoming {
                        Button { Task { await model.act(.respond(other: entry.id, accept: true)) } } label: { Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36).background(YapperPalette.rail, in: .circle) }.buttonStyle(.plain).accessibilityLabel("Annehmen")
                        Button { Task { await model.act(.respond(other: entry.id, accept: false)) } } label: { roundIcon("close") }.buttonStyle(.plain).accessibilityLabel("Ablehnen")
                    } else { Button { Task { await model.act(.remove(entry.id)) } } label: { roundIcon("close") }.buttonStyle(.plain).accessibilityLabel("Zurückziehen") }
                }
                if let note = entry.requestNote, !note.isEmpty { Text(verbatim: note).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary).padding(.leading, 56).padding(.bottom, 10) }
            }
        }
        sectionLabel("Nachrichtenanfragen", count: model.snapshot.requests.count)
        if model.snapshot.requests.isEmpty { emptyMessage("Keine offenen Nachrichtenanfragen.") }
        ForEach(model.snapshot.requests) { profile in
            personRow(profile, subtitle: "Möchte dir schreiben") {
                messageButton(profile)
                Button { Task { await ignoreMessageRequest(profile.id) } } label: { roundIcon("close") }.buttonStyle(.plain).accessibilityLabel("Ignorieren")
            }
        }
    }
    private var requestSheet: some View {
        OriginalModalPage("Freund hinzufügen", subtitle: "Du kannst Freunde über ihren Yapper-Benutzernamen hinzufügen.", onClose: { showingRequest = false }) {
            OriginalSettingsField("Benutzername") { TextField("username", text: $requestName).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(OriginalYapperTextFieldStyle()) }
            OriginalSettingsField("Notiz (optional)") { TextField("Woher kennt ihr euch?", text: $requestNote, axis: .vertical).lineLimit(1...4).textFieldStyle(OriginalYapperTextFieldStyle()) }
            Text("\(requestNote.utf16.count)/100").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            if sentRequest { Text("Freundschaftsanfrage gesendet.").foregroundStyle(YapperPalette.success) }
            if let error = model.error { NativeErrorBanner(message: error) }
        } footer: {
            Button("Abbrechen") { showingRequest = false }.buttonStyle(OriginalYapperButtonStyle())
            Button("Senden") { Task { await model.act(.request(username: requestName, note: requestNote)); if model.error == nil { sentRequest = true; requestName = ""; requestNote = "" } } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(model.isBusy || requestName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || requestNote.utf16.count > 100)
        }
    }
    private var searchSheet: some View {
        OriginalModalPage("Personen finden", subtitle: "Suche deine Freunde und Personen, die in deinen Servern online sind.", onClose: { showingSearch = false }) {
            HStack(spacing: 8) { OriginalYapperIcon("search", size: 18); TextField("Personen finden", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled() }.padding(12).background(YapperPalette.rail, in: .rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(YapperPalette.border, lineWidth: 1))
            if model.searchResults.isEmpty { emptyMessage(query.count < 2 ? "Gib mindestens zwei Zeichen ein." : "Niemanden gefunden.") }
            ForEach(model.searchResults) { profile in personRow(profile, subtitle: "@\(profile.username)") { messageButton(profile) } }
        } footer: { Button("Fertig") { showingSearch = false }.buttonStyle(OriginalYapperButtonStyle()) }
    }
    private func ignoreMessageRequest(_ id: String) async {
        do {
            #if DEBUG
            if model.isFixture { return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.ignoreSocialDMRequest(userID: id, session: session) }
            await model.load()
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
    private func loadFeatureFlags() async {
        do {
            #if DEBUG
            if model.isFixture { featureFlags = ["interest_matches"]; return }
            #endif
            featureFlags = try await store.withAuthenticatedSession { api, session in try await api.communityFlags(session: session) }
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
}

struct NativeProfileView: View {
    let store: NativeStore
    let userID: String
    enum Presentation { case page, overlay }
    let presentation: Presentation
    let onOpenConversation: @MainActor (Conversation) -> Void
    @State private var model: NativeSocialModel
    @State private var profile: NativeProfileDetail?
    @State private var note = ""
    @State private var originalNote = ""
    @State private var mutualFriendCount: Int?
    @State private var mutualServerCount: Int?
    @State private var showingEditor = false
    @State private var isLoading = false
    @State private var isSavingNote = false
    @State private var featureFlags: Set<String> = []

    init(store: NativeStore, userID: String, presentation: Presentation = .page, onOpenConversation: @escaping @MainActor (Conversation) -> Void) {
        self.store = store
        self.userID = userID
        self.presentation = presentation
        self.onOpenConversation = onOpenConversation
        _model = State(initialValue: NativeSocialModel(store: store))
    }

    private var isOwn: Bool { userID == store.user?.id }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var bannerExpanded = false
    @State private var composeText = ""
    @State private var copiedID = false

    private var profilePresence: String {
        if isOwn { return store.user?.presence ?? "unknown" }
        return store.peerPresence(userID: userID)
    }
    private var profilePresenceLabel: String {
        switch profilePresence { case "online": "Online"; case "idle", "away": "Abwesend"; case "dnd", "busy": "Nicht stören"; case "invisible", "offline": "Offline"; default: "Status unbekannt" }
    }
    private var isLightProfile: Bool { OriginalProfileContrast.isLight(profile?.accentColor, profile?.accentColor2) }
    private var profileInk: Color { isThemed ? (isLightProfile ? Color(red: 18/255, green: 19/255, blue: 22/255) : .white) : YapperPalette.text }
    private var profileMuted: Color { isThemed ? (isLightProfile ? .black.opacity(0.66) : .white.opacity(0.78)) : YapperPalette.secondary }
    private var isThemed: Bool { Color.originalProfileHex(profile?.accentColor) != nil }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(presentation == .overlay ? 0.62 : 0.35).ignoresSafeArea().onTapGesture { dismiss() }
                ViewThatFits(in: .vertical) {
                    profileCard(bottomInset: geometry.safeAreaInsets.bottom).fixedSize(horizontal: false, vertical: true)
                    ScrollView { profileCard(bottomInset: geometry.safeAreaInsets.bottom) }.frame(maxHeight: max(200, geometry.size.height - 20))
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 1)
                .padding(.bottom, 1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).ignoresSafeArea(edges: .bottom)
        }
        .background(presentation == .overlay ? Color.clear : YapperPalette.rail)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingEditor) {
            if let profile { NavigationStack { NativeProfileEditor(store: store, profile: profile, featureFlags: featureFlags) { self.profile = $0 } } }
        }
        .sheet(isPresented: $bannerExpanded) {
            if let profile, let banner = profile.bannerURL {
                ZStack(alignment: .topTrailing) {
                    Color.black.ignoresSafeArea()
                    NativeRemoteImage(url: banner, maximumPixelSize: 2048).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Button { bannerExpanded = false } label: { OriginalYapperIcon("close", size: 22).frame(width: 44, height: 44).background(.black.opacity(0.4), in: .circle) }.foregroundStyle(.white).padding(16).accessibilityLabel("Schließen")
                }
            }
        }
        .task(id: userID) { await load() }
    }

    private func profileCard(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let profile { profileHeader(profile); profileBody(profile).padding(.bottom, max(0, bottomInset - 16)) }
            else if isLoading { ProgressView("Profil wird geladen …").frame(maxWidth: .infinity, minHeight: 160) }
            if let error = model.error { NativeErrorBanner(message: error) { Task { await load() } }.padding(16) }
        }
        .foregroundStyle(profileInk)
        .background {
            if let first = Color.originalProfileHex(profile?.accentColor) { OriginalProfileGradient(first: first, second: Color.originalProfileHex(profile?.accentColor2) ?? first) }
            else { YapperPalette.sidebar }
        }
        .clipShape(.rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YapperPalette.border, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { OriginalYapperIcon("close", size: 18).frame(width: 40, height: 40).contentShape(.interaction, Rectangle().inset(by: -2)).foregroundStyle(.white).background(.black.opacity(0.35), in: .rect(cornerRadius: 8)) }.buttonStyle(.plain).padding(8).accessibilityLabel("Schließen").accessibilityIdentifier("native.profile.close")
        }
        .overlay { if let effect = profile?.user.profileEffectURL { NativeRemoteImage(url: effect, mode: .fill).allowsHitTesting(false).accessibilityHidden(true) } }
    }

    private func profileHeader(_ profile: NativeProfileDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let accent = Color.originalProfileHex(profile.accentColor) { LinearGradient(colors: [accent, Color.originalProfileHex(profile.accentColor2) ?? accent], startPoint: .topLeading, endPoint: .bottomTrailing) }
                else { OriginalAvatarFallback.color(identity: profile.id, username: profile.username) }
                if let banner = profile.bannerURL { NativeCroppedImage(url: banner, crop: NativeImageCrop(x: profile.bannerX, y: profile.bannerY, zoom: profile.bannerZoom)) }
                if profile.bannerURL != nil { LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom) }
            }
            .aspectRatio(3, contentMode: .fit)
            .clipped().contentShape(.rect)
            .onTapGesture { if profile.bannerURL != nil { bannerExpanded = true } }
            .accessibilityLabel("Profilbanner").accessibilityAddTraits(profile.bannerURL == nil ? [] : .isButton)
            HStack(alignment: .top, spacing: 8) {
                NativeAvatar(name: profile.displayName, identity: profile.id, username: profile.username, url: profile.avatarURL, presence: profilePresence, size: 96, decorationURL: profile.user.avatarDecorationURL, crop: profile.user.avatarCrop)
                    .padding(7).background(isThemed ? (Color.originalProfileHex(profile.accentColor) ?? YapperPalette.sidebar) : YapperPalette.sidebar, in: .circle).padding(.top, -52)
                if !profile.customStatus.isEmpty, isOwn || !["offline", "invisible"].contains(profilePresence), profile.customStatusUntil.map({ $0 > Date() }) ?? true {
                    Text(verbatim: profile.customStatus).font(OriginalYapper.font(14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 12).background(isLightProfile ? Color(red: 244/255, green: 244/255, blue: 246/255) : YapperPalette.rail, in: .rect(cornerRadius: 10)).padding(.top, -34)
                } else { Spacer(minLength: 0) }
                if !isOwn { profileQuickActions(profile).padding(.top, 8) }
            }.padding(.leading, 16).padding(.trailing, 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    NativeDisplayName(name: profile.displayName, bannerURL: profile.user.nameBannerURL).font(OriginalYapper.font(horizontalSizeClass == .compact ? 20 : 24, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                    if !profile.verifiedHidden, profile.verifiedAs != nil { Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(YapperPalette.accent).accessibilityLabel("Verifiziert: \(profile.verifiedAs ?? "")") }
                }
                HStack(spacing: 5) {
                    Text(verbatim: "@\(profile.username)")
                    if !profile.pronouns.isEmpty { Text("·"); Text(verbatim: profile.pronouns) }
                }.font(OriginalYapper.font(13)).foregroundStyle(profileMuted)
                profileChips(profile)
                if let mutualFriendCount, let mutualServerCount, !isOwn, mutualFriendCount + mutualServerCount > 0 {
                    Text("\(mutualFriendCount) gemeinsame Freunde · \(mutualServerCount) gemeinsame Server")
                        .font(OriginalYapper.font(12)).foregroundStyle(profileMuted).padding(.top, 7)
                }
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 2)
        }
    }

    @ViewBuilder private func profileChips(_ profile: NativeProfileDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                if let tag = profile.serverTag, profile.serverID != nil { profileChip(tag, color: YapperPalette.elevated) }
                if let until = profile.plusUntil, until > Date(), !profile.plusBadgeHidden { profileChip("PLUS", color: Color(red: 0.7, green: 0.3, blue: 0.9)) }
                ForEach(Array(profile.badges.prefix(4)), id: \.self) { profileChip($0, color: YapperPalette.elevated) }
                if let level = profile.accountLevel { profileChip("\(level)", color: YapperPalette.elevated) }
            }
            Text(([profile.serverTag].compactMap { $0 } + Array(profile.badges.prefix(4))).joined(separator: " · ")).font(OriginalYapper.font(11, weight: .bold))
        }.padding(.top, 3)
    }
    private func profileChip(_ value: String, color: Color) -> some View {
        Text(verbatim: value).font(OriginalYapper.font(10, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2).background(color.opacity(0.8), in: .rect(cornerRadius: 4))
    }
    @ViewBuilder private func profileBody(_ profile: NativeProfileDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if isOwn && profilePresence == "invisible" {
                HStack(spacing: 8) { NativeOriginalPresenceDot(presence: "offline", size: 10); Text("Unsichtbar") }.font(OriginalYapper.font(13)).foregroundStyle(profileMuted).padding(.bottom, 2)
            }
            if !profile.bio.isEmpty { OriginalProfileSection("Über mich", themed: isThemed, light: isLightProfile) { Text(verbatim: profile.bio).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
            if !profile.links.isEmpty {
                OriginalProfileSection("Links", themed: isThemed, light: isLightProfile) {
                    ForEach(profile.links, id: \.self) { link in
                        if let url = URL(string: link), url.scheme == "https", url.user == nil, url.password == nil {
                            Link(destination: url) { Text(link).font(OriginalYapper.font(13)).foregroundStyle(isThemed ? .white : YapperPalette.accent).lineLimit(2).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading) }
                        }
                    }
                }
            }
            if let date = profile.createdAt { OriginalProfileSection("Yapin’ seit", themed: isThemed, light: isLightProfile) { HStack(spacing: 6) { Image("AppMark").resizable().scaledToFit().frame(width: 16, height: 16); Text(date, format: .dateTime.day().month(.abbreviated).year()) } } }
            if !isOwn {
                OriginalProfileSection("Notiz", themed: isThemed, light: isLightProfile) {
                    TextField("Notiz hinzufügen (nur für dich sichtbar)", text: $note, axis: .vertical).lineLimit(1...8).font(OriginalYapper.font(13.5))
                    if note != originalNote {
                        HStack {
                            Text("\(note.utf16.count)/500").font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.secondary)
                            Spacer()
                            Button(isSavingNote ? "Speichert …" : "Speichern") { Task { await saveNote() } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(isSavingNote || note.utf16.count > 500)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    UIPasteboard.general.string = profile.id; copiedID = true
                } label: { HStack(spacing: 6) { Text(copiedID ? "Kopiert" : "ID \(profile.id.prefix(8))").font(OriginalYapper.font(11.5).monospaced()); Image(systemName: "doc.on.doc").font(.system(size: 9)) } }.buttonStyle(.plain).foregroundStyle(profileMuted).padding(.vertical, 2).accessibilityLabel("Benutzer-ID kopieren").accessibilityIdentifier("native.profile.copyID")
            }
            if isOwn {
                Button { showingEditor = true } label: { Text("Profil bearbeiten").font(OriginalYapper.font(14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 40).contentShape(.interaction, Rectangle().inset(by: -2)).background(YapperPalette.active, in: .rect(cornerRadius: 8)) }.buttonStyle(.plain).padding(.top, 4).accessibilityIdentifier("native.profile.edit")
                if featureFlags.contains("server_tags") { NavigationLink { NativeServerTagView(store: store, profile: profile, showIconControl: featureFlags.contains("tag_icons")) } label: { Text("Server-Tag auswählen").font(OriginalYapper.font(13)) }.buttonStyle(OriginalYapperButtonStyle()) }
            } else {
                HStack(spacing: 6) {
                    TextField("Nachricht an @\(profile.username)", text: $composeText).textFieldStyle(OriginalYapperTextFieldStyle())
                    Button { Task { await sendInlineMessage(profile) } } label: { OriginalYapperIcon("send", size: 16).frame(width: 38, height: 40).contentShape(.interaction, Rectangle().inset(by: -3)).foregroundStyle(.white).background(YapperPalette.accentFill, in: .rect(cornerRadius: 8)) }.buttonStyle(.plain).disabled(composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending || model.isBusy).accessibilityLabel("Nachricht senden")
                }.padding(.top, 2)
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }
    private func sendInlineMessage(_ profile: NativeProfileDetail) async {
        guard let conversation = await model.openDM(profile) else { return }
        if await store.sendMessage(composeText, in: conversation) { composeText = ""; onOpenConversation(conversation) }
        else { model.error = store.errorMessage }
    }
    private func profileQuickActions(_ profile: NativeProfileDetail) -> some View {
        HStack(spacing: 4) {
            Button { Task { if let conversation = await model.openDM(profile) { onOpenConversation(conversation) } } } label: { HStack(spacing: 6) { OriginalYapperIcon("servers", size: 14); Text("Nachricht").font(OriginalYapper.font(14, weight: .semibold)) }.padding(.horizontal, 12).frame(height: 34).foregroundStyle(.white).background(YapperPalette.accentFill, in: .rect(cornerRadius: 8)) }
                .accessibilityLabel("Nachricht senden").accessibilityIdentifier("native.profile.message")
            Menu {
                let relation = model.snapshot.friends.first(where: { $0.id == userID })?.relation
                if relation == .accepted { Button("Freundschaft entfernen", role: .destructive) { Task { await model.act(.remove(userID)) } } }
                else if relation == .incoming {
                    Button("Freundschaft annehmen") { Task { await model.act(.respond(other: userID, accept: true)) } }
                    Button("Anfrage ablehnen", role: .destructive) { Task { await model.act(.respond(other: userID, accept: false)) } }
                } else if relation == .outgoing { Button("Anfrage zurückziehen", role: .destructive) { Task { await model.act(.remove(userID)) } } }
                else { Button("Freund hinzufügen") { Task { await model.act(.request(username: profile.username, note: "")) } } }
                if model.snapshot.blocked.contains(where: { $0.id == userID }) { Button("Blockierung aufheben") { Task { await model.act(.unblock(userID)) } } }
                else { Button("Blockieren", role: .destructive) { Task { await model.act(.block(userID)) } } }
                NavigationLink { NativeReportComposer(store: store, target: .user(userID)) } label: { Text("Profil melden") }
            } label: { OriginalYapperIcon("more", size: 18).frame(width: 40, height: 40).contentShape(.interaction, Rectangle().inset(by: -2)).background(YapperPalette.active, in: .rect(cornerRadius: 8)) }.accessibilityLabel("Weitere Profilaktionen")
        }.foregroundStyle(profileInk).background(.black.opacity(isThemed ? 0.3 : 0), in: .rect(cornerRadius: 7)).buttonStyle(.plain).disabled(model.isBusy)
    }

    private func load() async {
        isLoading = true; model.error = nil
        defer { isLoading = false }
        do {
            #if DEBUG
            if model.isFixture { profile = try model.fixtureProfile(userID: userID); featureFlags = Set(["server_tags", "tag_icons", "temp_avatar"].filter { store.capabilities.flagOn($0, userID: store.user?.id) }); await model.load(); return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.socialProfiles(ids: [userID], session: session) }
            guard let current = result.first, current.id == userID, !Task.isCancelled else { throw NativeClientError.missingProfile }
            profile = current
            if isOwn { featureFlags = try await store.withAuthenticatedSession { api, session in try await api.communityFlags(session: session) } }
            if !isOwn {
                let details = try await store.withAuthenticatedSession { api, session in
                    let note = try await api.socialUserNote(userID: userID, session: session)
                    try Task.checkCancellation()
                    let mutuals = try await api.rpc("mutuals", arguments: ["other": .string(userID)], session: session)
                    return (note, mutuals)
                }
                note = details.0; originalNote = details.0
                mutualFriendCount = details.1["friends"].array.count
                mutualServerCount = details.1["servers"].array.count
                await model.load()
            }
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }

    private func saveNote() async {
        guard !isSavingNote else { return }
        isSavingNote = true; model.error = nil
        defer { isSavingNote = false }
        do {
            #if DEBUG
            if model.isFixture { originalNote = note; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.saveSocialUserNote(userID: userID, note: note, session: session) }
            originalNote = note
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
}

struct NativeProfileEditor: View {
    let store: NativeStore
    let profile: NativeProfileDetail
    let onSave: @MainActor (NativeProfileDetail) -> Void
    let featureFlags: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NativeProfileDraft
    @State private var avatar: PhotosPickerItem?
    @State private var banner: PhotosPickerItem?
    @State private var removeAvatar = false
    @State private var removeBanner = false
    @State private var isSaving = false
    @State private var error: String?
    @State private var presence = "online"
    @State private var originalPresence = "online"
    @State private var presenceLoaded = false
    @State private var pickedAvatar: PickedImage?
    @State private var pickedBanner: PickedImage?
    @State private var loadingAvatar = false
    @State private var loadingBanner = false
    @State private var cropping: CropTarget?
    @State private var temporaryAvatarSeconds = 0
    private enum CropTarget: String, Identifiable { case avatar, banner; var id: String { rawValue } }

    init(store: NativeStore, profile: NativeProfileDetail, featureFlags: Set<String>, onSave: @escaping @MainActor (NativeProfileDetail) -> Void) {
        self.store = store; self.profile = profile; self.featureFlags = featureFlags; self.onSave = onSave
        _draft = State(initialValue: NativeProfileDraft(profile: profile))
    }

    var body: some View {
        let avatarLabel = avatar == nil ? "Profilbild auswählen" : "Profilbild ausgewählt"
        let bannerLabel = banner == nil ? "Banner auswählen" : "Banner ausgewählt"
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Mein Profil").font(OriginalYapper.font(20, weight: .bold)).padding(.bottom, 2)
                editorPreview
                OriginalSettingsSection("Profil") {
                    OriginalSettingsField("Benutzername") { TextField("Benutzername", text: $draft.username).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(OriginalYapperTextFieldStyle()) }
                    OriginalSettingsField("Anzeigename") { TextField("Anzeigename", text: $draft.displayName).textFieldStyle(OriginalYapperTextFieldStyle()) }
                    OriginalSettingsField("Pronomen") { TextField("Pronomen", text: $draft.pronouns).textFieldStyle(OriginalYapperTextFieldStyle()) }
                    OriginalSettingsField("Über mich") {
                        TextField("Erzähl etwas über dich", text: $draft.bio, axis: .vertical).lineLimit(3...8).textFieldStyle(OriginalYapperTextFieldStyle())
                        Text("\(draft.bio.utf16.count)/300").font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                OriginalSettingsSection("Status") {
                    OriginalSettingsField("Eigener Status") { TextField("Was beschäftigt dich?", text: $draft.customStatus, axis: .vertical).lineLimit(1...3).textFieldStyle(OriginalYapperTextFieldStyle()) }
                    Toggle("Status automatisch löschen", isOn: Binding(get: { draft.customStatusUntil != nil }, set: { draft.customStatusUntil = $0 ? Date().addingTimeInterval(3_600) : nil })).toggleStyle(OriginalYapperToggleStyle())
                    if draft.customStatusUntil != nil {
                        DatePicker("Löschen am", selection: Binding(get: { draft.customStatusUntil ?? Date().addingTimeInterval(3_600) }, set: { draft.customStatusUntil = $0 }), in: Date()...).font(OriginalYapper.font(14))
                    }
                    if presenceLoaded {
                        HStack {
                            Text("Verfügbarkeit").font(OriginalYapper.font(14))
                            Spacer()
                            Picker("Verfügbarkeit", selection: $presence) { Text("Online").tag("online"); Text("Abwesend").tag("idle"); Text("Nicht stören").tag("dnd"); Text("Unsichtbar").tag("invisible") }.tint(YapperPalette.text)
                        }
                    }
                }
                OriginalSettingsSection("Profilbild") {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $avatar, matching: .images) { Text(avatarLabel) }.buttonStyle(OriginalYapperButtonStyle(primary: true))
                        Button { cropping = .avatar } label: { Text("Zuschneiden") }.buttonStyle(OriginalYapperButtonStyle()).disabled(removeAvatar || (pickedAvatar == nil && profile.avatarURL == nil)).accessibilityIdentifier("native.profile.cropAvatar")
                    }
                    if loadingAvatar { ProgressView("Profilbild wird vorbereitet …") }
                    if featureFlags.contains("temp_avatar"), pickedAvatar != nil {
                        HStack {
                            Text("Zurücksetzen").font(OriginalYapper.font(14)); Spacer()
                            Picker("Profilbild zurücksetzen", selection: $temporaryAvatarSeconds) { Text("Behalten").tag(0); Text("Nach einer Stunde").tag(3_600); Text("Nach einem Tag").tag(86_400); Text("Nach einer Woche").tag(604_800) }
                        }
                    } else if featureFlags.contains("temp_avatar"), let until = profile.avatarRevertAt, !removeAvatar {
                        Text(until > Date() ? "Das Profilbild wechselt am \(until.formatted(date: .abbreviated, time: .shortened)) zurück." : "Das Profilbild wird zurückgesetzt.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        Button("Dieses Profilbild behalten") { Task { await keepAvatar() } }.buttonStyle(OriginalYapperButtonStyle())
                    }
                    Toggle("Profilbild entfernen", isOn: $removeAvatar).toggleStyle(OriginalYapperToggleStyle())
                }
                OriginalSettingsSection("Profilbanner") {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $banner, matching: .images) { Text(bannerLabel) }.buttonStyle(OriginalYapperButtonStyle(primary: true))
                        Button("Zuschneiden") { cropping = .banner }.buttonStyle(OriginalYapperButtonStyle()).disabled(removeBanner || (pickedBanner == nil && profile.bannerURL == nil)).accessibilityIdentifier("native.profile.cropBanner")
                    }
                    if loadingBanner { ProgressView("Banner wird vorbereitet …") }
                    Toggle("Banner entfernen", isOn: $removeBanner).toggleStyle(OriginalYapperToggleStyle())
                }
                OriginalSettingsSection("Profilfarben") {
                    OriginalSettingsField("Akzentfarbe") { TextField("#RRGGBB", text: $draft.accentColor).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(OriginalYapperTextFieldStyle()) }
                    OriginalSettingsField("Zweite Akzentfarbe") { TextField("#RRGGBB", text: $draft.accentColor2).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(OriginalYapperTextFieldStyle()) }
                }
                if let error { NativeErrorBanner(message: error) }
            }.padding(16).padding(.bottom, 28)
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
        .background(YapperPalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button("Abbrechen") { dismiss() }.buttonStyle(OriginalYapperButtonStyle())
                Spacer()
                Button(isSaving ? "Speichert …" : "Speichern") { Task { await save() } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(isSaving || loadingAvatar || loadingBanner).accessibilityIdentifier("native.profile.save")
            }.padding(12).background(YapperPalette.sidebar)
        }
        .toolbar(.hidden, for: .navigationBar)
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .sheet(item: $cropping) { target in
            NavigationStack {
                NativeProfileCropEditor(url: target == .avatar ? profile.avatarURL : profile.bannerURL, data: target == .avatar ? pickedAvatar?.data : pickedBanner?.data, isAvatar: target == .avatar, initial: target == .avatar ? avatarCrop : bannerCrop) { crop in
                    if target == .avatar { draft.avatarX = crop.x; draft.avatarY = crop.y; draft.avatarZoom = crop.zoom; draft.avatarRotation = crop.rotation }
                    else { draft.bannerX = crop.x; draft.bannerY = crop.y; draft.bannerZoom = crop.zoom }
                }
            }
        }
        .task(id: avatar) { await prepareImage(isAvatar: true) }
        .task(id: banner) { await prepareImage(isAvatar: false) }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { presenceLoaded = true; return }
            #endif
            do {
                let result = try await store.withAuthenticatedSession { api, session in try await api.rpc("my_status_pref", session: session) }
                guard let value = result.string, ["online", "idle", "dnd", "invisible"].contains(value) else { return }
                presence = value; originalPresence = value; presenceLoaded = true
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .yapperNavigation()
    }

    private var editorPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color.originalProfileHex(draft.accentColor) ?? YapperPalette.accent, Color.originalProfileHex(draft.accentColor2) ?? YapperPalette.sidebar], startPoint: .topLeading, endPoint: .bottomTrailing)
                if !removeBanner, pickedBanner != nil || profile.bannerURL != nil { NativeCroppedImage(url: profile.bannerURL, data: pickedBanner?.data, crop: bannerCrop) }
            }.aspectRatio(3, contentMode: .fit).clipped()
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if !removeAvatar, pickedAvatar != nil || profile.avatarURL != nil { NativeCroppedImage(url: profile.avatarURL, data: pickedAvatar?.data, crop: avatarCrop, maximumPixelSize: 512).frame(width: 96, height: 96).clipShape(.circle) }
                    else { NativeAvatar(name: draft.displayName, identity: profile.id, username: draft.username, url: nil, size: 96) }
                }.padding(7).background(YapperPalette.sidebar, in: .circle).padding(.top, -52)
                Text(draft.displayName.isEmpty ? draft.username : draft.displayName).font(OriginalYapper.font(24, weight: .heavy))
                Text("@\(draft.username)").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }.background(YapperPalette.sidebar).clipShape(.rect(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YapperPalette.border, lineWidth: 1)).accessibilityElement(children: .ignore).accessibilityLabel("Profilvorschau")
    }

    private struct PickedImage: Sendable {
        let data: Data
        let contentType: String
    }

    private var avatarCrop: NativeImageCrop { NativeImageCrop(x: draft.avatarX, y: draft.avatarY, zoom: draft.avatarZoom, rotation: draft.avatarRotation) }
    private var bannerCrop: NativeImageCrop { NativeImageCrop(x: draft.bannerX, y: draft.bannerY, zoom: draft.bannerZoom) }

    private func prepareImage(isAvatar: Bool) async {
        let selected = isAvatar ? avatar : banner
        guard let selected else { return }
        if isAvatar { loadingAvatar = true } else { loadingBanner = true }
        defer { if isAvatar { loadingAvatar = false } else { loadingBanner = false } }
        do {
            let picked = try await imageData(selected)
            try Task.checkCancellation()
            guard selected == (isAvatar ? avatar : banner) else { return }
            if isAvatar { pickedAvatar = picked; removeAvatar = false; draft.avatarX = 50; draft.avatarY = 50; draft.avatarZoom = 1; draft.avatarRotation = 0; cropping = .avatar }
            else { pickedBanner = picked; removeBanner = false; draft.bannerX = 50; draft.bannerY = 50; draft.bannerZoom = 1; cropping = .banner }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func keepAvatar() async {
        guard !isSaving else { return }; isSaving = true; error = nil; defer { isSaving = false }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { error = "In der Testansicht werden keine Profilbilder geändert."; return }
            #endif
            let current = try await store.withAuthenticatedSession { api, session in try await api.keepSocialTemporaryAvatar(session: session) }
            onSave(current); await store.refreshOwnProfile()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func imageData(_ selection: PhotosPickerItem?) async throws -> PickedImage? {
        guard let selection else { return nil }
        guard let data = try await selection.loadTransferable(type: Data.self), data.count <= 10 * 1_024 * 1_024 else {
            throw NativeClientError.api(status: 400, message: "Dieses Bild konnte nicht gelesen werden. Wähle ein anderes Bild.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw NativeClientError.invalidResponse }
        if let type = CGImageSourceGetType(source),
           let mime = UTType(type as String)?.preferredMIMEType, NativeMediaUploadPolicy.imageTypes.contains(mime) {
            return PickedImage(data: data, contentType: mime)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4_096]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.88) else {
            throw NativeClientError.api(status: 400, message: "Dieses Bild konnte nicht gelesen werden. Wähle ein anderes Bild.")
        }
        return PickedImage(data: jpeg, contentType: "image/jpeg")
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            _ = try draft.values()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") {
                let row = try draft.values().merging(["id": .string(profile.id)]) { _, new in new }
                onSave(try NativeProfileDetail(row: .object(row))); dismiss(); return
            }
            #endif
            let avatarBytes: PickedImage?
            if removeAvatar { avatarBytes = nil }
            else if let pickedAvatar { avatarBytes = pickedAvatar }
            else { avatarBytes = try await imageData(avatar) }
            let bannerBytes: PickedImage?
            if removeBanner { bannerBytes = nil }
            else if let pickedBanner { bannerBytes = pickedBanner }
            else { bannerBytes = try await imageData(banner) }
            let result = try await store.withAuthenticatedSession { api, session in
                var avatarPath: String?
                var bannerPath: String?
                if let avatarBytes {
                    avatarPath = try await api.uploadMedia(bucket: "avatars", data: avatarBytes.data, filename: "avatar", contentType: avatarBytes.contentType, session: session)
                }
                try Task.checkCancellation()
                if let bannerBytes {
                    bannerPath = try await api.uploadMedia(bucket: "banners", data: bannerBytes.data, filename: "banner", contentType: bannerBytes.contentType, session: session)
                }
                try Task.checkCancellation()
                return try await api.saveSocialProfile(profileID: profile.id, draft: draft, avatarPath: avatarPath, bannerPath: bannerPath, removeAvatar: removeAvatar, removeBanner: removeBanner,
                                                       avatarRevertAt: avatarPath != nil && featureFlags.contains("temp_avatar") && temporaryAvatarSeconds > 0 ? Date().addingTimeInterval(Double(temporaryAvatarSeconds)) : nil,
                                                       previousProfile: profile, session: session)
            }
            onSave(result)
            if presenceLoaded && presence != originalPresence {
                try await store.withAuthenticatedSession { api, session in try await api.setSocialPresence(presence, session: session) }
            }
            await store.refreshOwnProfile()
            await store.loadConversations()
            dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeInboxView: View {
    let store: NativeStore
    let onOpenConversation: @MainActor (Conversation) -> Void
    @State private var items: [NativeInboxItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedItem: NativeInboxItem?
    @State private var mentionMessages: [ChatMessage] = []
    @State private var mentionError: String?
    @State private var selectedMentionMessage: ChatMessage?
    private var showsMentions: Bool { store.capabilities.flagOn("mentions_inbox", userID: store.user?.id) }
    private var isFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }

    var body: some View {
        List {
            if isFixture { NativeSocialFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if showsMentions {
                Section("Erwähnungen") {
                    if let mentionError { NativeErrorBanner(message: mentionError) { Task { await loadMentions() } } }
                    if !isLoading && mentionMessages.isEmpty && mentionError == nil { Text("Noch keine Erwähnungen.").foregroundStyle(YapperPalette.secondary) }
                    ForEach(mentionMessages) { message in
                        Button { selectedMentionMessage = message } label: {
                            HStack(alignment: .top, spacing: 10) {
                                NativeAvatar(name: message.author.displayName, identity: message.author.id, username: message.author.username, url: message.author.avatarURL, size: 34)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: message.author.displayName).font(OriginalYapper.font(14, weight: .semibold))
                                    Text(verbatim: NativeMentionRendering.plainText(message.content, store: store, snapshot: nil))
                                        .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary).lineLimit(3)
                                    Text(message.createdAt, style: .relative).font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.faint)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(minHeight: 44).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityIdentifier("native.inbox.mention.\(message.id)")
                    }
                }
            }
            if isLoading && items.isEmpty { ProgressView("Posteingang wird geladen …").frame(maxWidth: .infinity) }
            else if items.isEmpty && mentionMessages.isEmpty { ContentUnavailableView("Alles gelesen", systemImage: "tray", description: Text("Anfragen, verpasste Anrufe und Rückmeldungen erscheinen hier.")) }
            ForEach(items) { item in
                Button {
                    selectedItem = item
                    Task { await mark([item.id]) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.kind == "call" ? "phone.arrow.down.left" : item.kind == "friend" ? "person.badge.plus" : "tray")
                            .foregroundStyle(YapperPalette.accent).frame(width: 28)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: item.title).font(OriginalYapper.font(16, weight: .semibold))
                            if !item.content.isEmpty { Text(verbatim: item.content).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) }
                            Text(item.at, style: .relative).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        }
                        Spacer(minLength: 4)
                        if item.isUnread { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(YapperPalette.accent).accessibilityLabel("Ungelesen") }
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .swipeActions { Button("Gelesen", systemImage: "checkmark") { Task { await mark([item.id]) } } }
            }
        }
        .scrollContentBackground(.hidden)
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle("Posteingang")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Alle gelesen", systemImage: "checkmark") { Task { await mark([], all: true) } }
                    .disabled(items.allSatisfy { !$0.isUnread })
                    .frame(minHeight: 44)
            }
        }
        .task { await load(); await loadMentions() }
        .refreshable { await load(); await loadMentions() }
        .sheet(item: $selectedMentionMessage) { message in
            NavigationStack {
                NativeMessageSearchDestination(store: store, message: message)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { selectedMentionMessage = nil }.frame(minHeight: 44) } }
            }
        }
        .sheet(item: $selectedItem) { item in
            NavigationStack {
                List {
                    Section {
                        Text(verbatim: item.title).font(OriginalYapper.font(16, weight: .semibold))
                        if !item.content.isEmpty { Text(verbatim: item.content).textSelection(.enabled) }
                        Text(item.at, format: .dateTime).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                    }
                    if let id = item.userID {
                        NavigationLink("Profil ansehen") { NativeProfileView(store: store, userID: id, onOpenConversation: { conversation in selectedItem = nil; onOpenConversation(conversation) }) }
                    }
                    if let id = item.channelID, let conversation = store.conversations.first(where: { $0.id == id }) {
                        Button("Gespräch öffnen", systemImage: "bubble.left.and.bubble.right") { selectedItem = nil; onOpenConversation(conversation) }
                            .frame(minHeight: 44)
                    }
                }
                .navigationTitle("Benachrichtigung")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { selectedItem = nil } } }
            }
        }
        .yapperNavigation()
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            #if DEBUG
            if isFixture { items = []; return }
            #endif
            items = try await store.withAuthenticatedSession { api, session in try await api.socialInbox(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func mark(_ keys: [String], all: Bool = false) async {
        do {
            #if DEBUG
            if isFixture { return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.markSocialInbox(keys: keys, all: all, session: session) }
            for index in items.indices where all || keys.contains(items[index].id) { items[index].isUnread = false }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func loadMentions() async {
        guard showsMentions, let ownerID = store.user?.id else { return }
        mentionError = nil
        do {
            let messages = try await store.loadMentionMessages()
            guard !Task.isCancelled, store.user?.id == ownerID else { return }
            mentionMessages = messages
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, store.user?.id == ownerID else { return }
            mentionError = "Die Erwähnungen konnten nicht geladen werden."
        }
    }
}

struct NativeGroupEditor: View {
    let store: NativeStore
    let conversation: Conversation?
    let onOpenConversation: @MainActor (Conversation) -> Void
    @State private var model: NativeSocialModel
    @State private var name: String
    @State private var selected = Set<String>()
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    init(store: NativeStore, conversation: Conversation? = nil, onOpenConversation: @escaping @MainActor (Conversation) -> Void) {
        self.store = store; self.conversation = conversation; self.onOpenConversation = onOpenConversation
        _name = State(initialValue: conversation?.title ?? "")
        _model = State(initialValue: NativeSocialModel(store: store))
    }

    var body: some View {
        OriginalModalPage(conversation == nil ? "Neue Gruppe" : "Gruppe verwalten", subtitle: conversation == nil ? "Wähle bis zu 9 Freunde aus und gib deiner Gruppe einen Namen." : nil, onClose: { if !isSaving { dismiss() } }) {
            if model.isFixture { NativeSocialFixtureNotice() }
            OriginalSettingsField("Gruppenname") { TextField("Gruppenname", text: $name).textFieldStyle(OriginalYapperTextFieldStyle()) }
            if let conversation {
                OriginalSettingsSection("Mitglieder") {
                    ForEach(conversation.participants) { user in
                        HStack(spacing: 12) {
                            NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, size: 36, decorationURL: user.avatarDecorationURL, crop: user.avatarCrop)
                            Text(verbatim: user.displayName)
                            Spacer()
                            if user.id != store.user?.id {
                                Button("Entfernen", role: .destructive) { Task { await remove(user.id) } }
                                    .frame(minHeight: 44)
                            }
                        }
                    }
                    Button("Gruppe verlassen", role: .destructive) { if let own = store.user?.id { Task { await remove(own) } } }
                        .frame(minHeight: 44)
                }
            }
            OriginalSettingsSection(conversation == nil ? "Mitglieder auswählen (maximal 9)" : "Mitglieder hinzufügen") {
                if model.isLoading { ProgressView("Freunde werden geladen …") }
                let profiles = model.snapshot.friends.filter { entry in
                    entry.relation == .accepted && !(conversation?.participants.contains(where: { $0.id == entry.id }) ?? false)
                }
                ForEach(profiles) { entry in
                    Button {
                        if selected.contains(entry.id) { selected.remove(entry.id) }
                        else if selected.count < 9 { selected.insert(entry.id) }
                    } label: {
                        HStack(spacing: 12) {
                            NativeSocialPersonLabel(profile: entry.profile)
                            Spacer()
                            Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(entry.id) ? [.isSelected] : [])
                }
                if profiles.isEmpty && !model.isLoading { Text("Hier erscheinen deine Freunde, die noch nicht in der Gruppe sind.").foregroundStyle(YapperPalette.secondary) }
            }
            if let error = model.error { NativeErrorBanner(message: error) }
        } footer: {
            Button("Abbrechen") { dismiss() }.buttonStyle(OriginalYapperButtonStyle())
            Button(conversation == nil ? "Erstellen" : "Speichern") { Task { await save() } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation == nil && selected.isEmpty)
        }
        .disabled(isSaving)
        .task { await model.load() }
        .interactiveDismissDisabled(isSaving)
        .yapperNavigation()
    }

    private func save() async {
        isSaving = true; model.error = nil
        defer { isSaving = false }
        do {
            #if DEBUG
            if model.isFixture { dismiss(); return }
            #endif
            let id: String
            if let conversation {
                try await store.withAuthenticatedSession { api, session in try await api.updateSocialGroup(channelID: conversation.id, name: name, session: session) }
                if !selected.isEmpty {
                    try await store.withAuthenticatedSession { api, session in try await api.addSocialGroupMembers(channelID: conversation.id, members: Array(selected), session: session) }
                }
                id = conversation.id
            } else {
                id = try await store.withAuthenticatedSession { api, session in try await api.createSocialGroup(name: name, members: Array(selected), session: session) }
            }
            await store.loadConversations()
            guard !Task.isCancelled, let result = store.conversations.first(where: { $0.id == id }) else { throw NativeClientError.invalidResponse }
            onOpenConversation(result); dismiss()
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }

    private func remove(_ userID: String) async {
        guard let conversation else { return }
        isSaving = true; model.error = nil
        defer { isSaving = false }
        do {
            #if DEBUG
            if model.isFixture { dismiss(); return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.removeSocialGroupMember(channelID: conversation.id, memberID: userID, session: session) }
            await store.loadConversations()
            dismiss()
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
}

private struct NativeSocialPersonLabel: View {
    let profile: NativeProfileDetail
    var body: some View {
        HStack(spacing: 12) {
            NativeAvatar(name: profile.displayName, identity: profile.id, username: profile.username, url: profile.avatarURL, size: 42, decorationURL: profile.user.avatarDecorationURL, crop: profile.user.avatarCrop)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: profile.displayName).font(OriginalYapper.font(16, weight: .semibold))
                Text(verbatim: "@\(profile.username)").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44, alignment: .leading)
        .foregroundStyle(YapperPalette.text)
    }
}

private struct NativeSocialFixtureNotice: View {
    var body: some View {
        Label("Testansicht · Beispieldaten", systemImage: "testtube.2")
            .font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            .accessibilityIdentifier("native.social.fixture.notice")
    }
}
