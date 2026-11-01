import SwiftUI

struct NativeSuggestedPeopleView: View {
    let store: NativeStore
    let onOpenConversation: @MainActor (Conversation) -> Void
    @State private var model: NativeSocialModel
    @State private var matches: [NativeSocialMatch] = []
    @State private var visible: Bool?
    @State private var loading = false
    @State private var changingVisibility = false
    @Environment(\.dismiss) private var dismiss

    init(store: NativeStore, onOpenConversation: @escaping @MainActor (Conversation) -> Void) {
        self.store = store; self.onOpenConversation = onOpenConversation
        _model = State(initialValue: NativeSocialModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.isFixture { Label("Testansicht · Keine echten Vorschläge", systemImage: "testtube.2").font(OriginalYapper.font(12)) }
                if let error = model.error { NativeErrorBanner(message: error) { Task { await load() } } }
                Text("Menschen, mit denen du dich verstehen könntest").font(OriginalYapper.font(15, weight: .bold))
                Text("Ausgewählt anhand gemeinsamer Spiele, Musik, Filme und Server.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                if let visible {
                    Toggle("Personen mit ähnlichen Interessen vorschlagen", isOn: Binding(get: { visible }, set: { value in Task { await setVisible(value) } })).toggleStyle(OriginalYapperToggleStyle()).disabled(changingVisibility).accessibilityIdentifier("native.people.matchVisibility")
                    Text("Andere können dich unter Vorschläge finden, wenn ihr Spiele, Musik, Filme oder Server gemeinsam habt. Verborgene Verbindungen zählen nicht.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                if loading && matches.isEmpty { ProgressView("Vorschläge werden geladen …").frame(maxWidth: .infinity, minHeight: 120) }
                else if matches.isEmpty && model.error == nil { Text("Noch keine Vorschläge. Sobald ihr Interessen oder Server gemeinsam habt, kannst du hier neue Personen entdecken.").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).frame(maxWidth: .infinity).padding(.vertical, 40) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                    ForEach(matches) { match in suggestionCard(match) }
                }
            }.padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Button { dismiss() } label: { OriginalYapperIcon("chevronLeft", size: 20).frame(width: 44, height: 44) }.accessibilityLabel("Zurück")
                Text("Vorschläge").font(OriginalYapper.font(16, weight: .bold)); Spacer()
                Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(loading).accessibilityLabel("Aktualisieren").accessibilityIdentifier("native.people.refreshMatches")
            }.buttonStyle(.plain).padding(.trailing, 8).background(YapperPalette.sidebar)
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text).background(YapperPalette.background.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar)
        .task { await load() }.refreshable { await load(refresh: true) }
    }
    private func suggestionCard(_ match: NativeSocialMatch) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink { NativeProfileView(store: store, userID: match.id, onOpenConversation: onOpenConversation) } label: {
                ZStack {
                    LinearGradient(colors: [Color.originalProfileHex(match.profile.accentColor) ?? YapperPalette.accent, Color.originalProfileHex(match.profile.accentColor2) ?? YapperPalette.sidebar], startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let banner = match.profile.bannerURL { NativeCroppedImage(url: banner, crop: NativeImageCrop(x: match.profile.bannerX, y: match.profile.bannerY, zoom: match.profile.bannerZoom)) }
                }.aspectRatio(3, contentMode: .fit).clipped()
            }.buttonStyle(.plain).overlay(alignment: .bottomLeading) {
                NativeAvatar(name: match.profile.displayName, identity: match.profile.id, username: match.profile.username, url: match.profile.avatarURL, size: 52, decorationURL: match.profile.user.avatarDecorationURL, crop: match.profile.user.avatarCrop).padding(4).background(YapperPalette.elevated, in: .circle).padding(.leading, 14).offset(y: 30)
            }
            VStack(alignment: .leading, spacing: 6) {
                NavigationLink { NativeProfileView(store: store, userID: match.id, onOpenConversation: onOpenConversation) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text(match.profile.displayName).font(OriginalYapper.font(16, weight: .bold)); Text(match.profile.username).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                }.buttonStyle(.plain)
                Text("\(match.interestCount) gemeinsame Interessen · \(match.serverCount) gemeinsame Server").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                OriginalInlineFlow(spacing: 6) {
                    ForEach(match.sharedInterests + match.sharedServers, id: \.self) { name in Text(verbatim: name).font(OriginalYapper.font(12, weight: .semibold)).lineLimit(1).padding(.vertical, 3).padding(.horizontal, 9).background(YapperPalette.accent.opacity(0.18), in: .capsule) }
                }
                HStack(spacing: 6) {
                    Button("Freund hinzufügen") { Task { await model.act(.request(username: match.profile.username, note: "")); if model.error == nil { matches.removeAll { $0.id == match.id } } } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(model.isBusy)
                    Spacer(minLength: 0)
                    Button { Task { if let conversation = await model.openDM(match.profile) { onOpenConversation(conversation) } } } label: { OriginalYapperIcon("inbox", size: 16).frame(width: 36, height: 36) }.buttonStyle(.plain).accessibilityLabel("Nachricht")
                }.padding(.top, 8)
            }.padding(.top, 34).padding(.horizontal, 14).padding(.bottom, 12)
        }.background(YapperPalette.elevated).clipShape(.rect(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(YapperPalette.border, lineWidth: 1))
    }

    private func load(refresh: Bool = false) async {
        guard !loading else { return }; loading = true; model.error = nil; defer { loading = false }
        do {
            #if DEBUG
            if model.isFixture { matches = []; visible = false; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in
                let matches = try await api.socialMatches(refresh: refresh, session: session)
                try Task.checkCancellation()
                let visible = try await api.socialMatchVisibility(session: session)
                return (matches, visible)
            }
            matches = result.0; visible = result.1
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
    private func setVisible(_ value: Bool) async {
        guard !changingVisibility else { return }; changingVisibility = true; defer { changingVisibility = false }
        do {
            #if DEBUG
            if model.isFixture { model.error = "In der Testansicht werden keine Kontoeinstellungen geändert."; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.setSocialMatchVisibility(value, session: session) }
            visible = value
        } catch is CancellationError {} catch { model.error = error.localizedDescription }
    }
}

struct NativeServerTagView: View {
    let store: NativeStore
    let showIconControl: Bool
    @State private var currentID: String?
    @State private var iconShown: Bool
    @State private var choices: [NativeServerTagChoice] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(store: NativeStore, profile: NativeProfileDetail, showIconControl: Bool) {
        self.store = store; self.showIconControl = showIconControl
        _currentID = State(initialValue: profile.serverID)
        _iconShown = State(initialValue: !profile.tagIconHidden)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if NativeCommunityFixture.enabled { Label("Testansicht · Keine Server-Tag-Änderungen", systemImage: "testtube.2").font(OriginalYapper.font(12)) }
                if let error { NativeErrorBanner(message: error) { Task { await load() } } }
                if loading { ProgressView("Server-Tags werden geladen …").frame(maxWidth: .infinity) }
                Text("Server-Tag").font(OriginalYapper.font(20, weight: .bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    tagChoice(nil, title: "Kein Tag", subtitle: "")
                    ForEach(choices) { choice in tagChoice(choice.id, title: choice.tag, subtitle: choice.name) }
                }
                if choices.isEmpty && !loading { Text("Noch keiner deiner Server hat einen Tag eingerichtet.").foregroundStyle(YapperPalette.secondary) }
                if showIconControl, let currentID, choices.first(where: { $0.id == currentID })?.icon != nil { Toggle("Tag-Symbol anzeigen", isOn: Binding(get: { iconShown }, set: { shown in Task { await setIconShown(shown) } })).toggleStyle(OriginalYapperToggleStyle()) }
            }.padding(20)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack { Button { dismiss() } label: { OriginalYapperIcon("chevronLeft", size: 20).frame(width: 44, height: 44) }.accessibilityLabel("Zurück"); Text("Server-Tag").font(OriginalYapper.font(16, weight: .bold)); Spacer() }.buttonStyle(.plain).background(YapperPalette.sidebar)
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text).background(YapperPalette.background.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar).disabled(saving).task { await load() }
    }
    private func tagChoice(_ id: String?, title: String, subtitle: String) -> some View {
        Button { Task { await wear(id) } } label: {
            VStack(spacing: 10) {
                Text(title).font(OriginalYapper.font(14, weight: .bold)).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(OriginalYapper.font(12, weight: .semibold)).lineLimit(1).foregroundStyle(YapperPalette.secondary) }
                if currentID == id { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).accessibilityLabel("Ausgewählt") }
            }.frame(maxWidth: .infinity, minHeight: 60).padding(12).background(YapperPalette.elevated, in: .rect(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(currentID == id ? YapperPalette.accent : YapperPalette.border, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(currentID == id ? .isSelected : [])
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { choices = []; return }
            #endif
            choices = try await store.withAuthenticatedSession { api, session in try await api.socialServerTags(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func wear(_ id: String?) async {
        guard !saving, id != currentID else { return }; saving = true; error = nil; defer { saving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = "In der Testansicht werden keine Server-Tags geändert."; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.wearSocialServerTag(id, session: session) }
            currentID = id; await store.refreshOwnProfile()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func setIconShown(_ shown: Bool) async {
        guard !saving else { return }; saving = true; error = nil; defer { saving = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = "In der Testansicht werden keine Server-Tags geändert."; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.setSocialTagIconShown(shown, session: session) }
            iconShown = shown; await store.refreshOwnProfile()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
