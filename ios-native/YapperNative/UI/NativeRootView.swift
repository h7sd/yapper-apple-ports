import SwiftUI

struct NativeRootView: View {
    let store: NativeStore
    @State private var didRestoreSession = false
    @State private var call = NativeCallController()
    @AppStorage("native.appearance") private var appearance = "dark"
    @Environment(\.scenePhase) private var scenePhase
    private let accountAppearance = NativeAppearanceState.shared
    private var appearanceOwnerID: String? { store.authState == .signedIn ? store.user?.id : nil }

    private var colorScheme: ColorScheme? {
        switch accountAppearance.preferredTheme ?? appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            switch store.authState {
            case .signedIn:
                NativeAppShell(store: store)
            case .restoring:
                ZStack {
                    YapperPalette.background.ignoresSafeArea()
                    VStack(spacing: 24) {
                        Image("AppMark")
                            .resizable().scaledToFit().frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        ProgressView("login.restoring")
                            .tint(YapperPalette.accent)
                    }
                    .padding(24)
                }
            case .signedOut, .signingIn, .requiresTwoFactor:
                NativeLoginView(store: store)
            }
        }
        .foregroundStyle(YapperPalette.text)
        .tint(YapperPalette.accent)
        .environment(call)
        .preferredColorScheme(colorScheme)
        .onChange(of: store.authState) { _, state in
            if state != .signedIn {
                accountAppearance.prepare(ownerID: nil)
                NativeMediaPlayback.stopAll()
                NativeRemoteImage.clearCache()
                Task { await call.leave() }
            }
        }
        .task {
            guard !didRestoreSession else { return }
            didRestoreSession = true
            await store.restoreSession()
        }
        .task(id: appearanceOwnerID) { await refreshAccountAppearance() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, appearanceOwnerID != nil { Task { await refreshAccountAppearance() } }
        }
    }

    private func refreshAccountAppearance() async {
        #if DEBUG
        let newFixtureOwner = accountAppearance.ownerID != appearanceOwnerID
        #endif
        accountAppearance.prepare(ownerID: appearanceOwnerID)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") {
            if newFixtureOwner { accountAppearance.useAccountTheme() }
            if let ownerID = appearanceOwnerID,
               let key = UserDefaults.standard.string(forKey: "native.fixtureColorTheme"),
               NativeChatTint.presets.contains(where: { $0.key == key }) {
                await accountAppearance.refresh(ownerID: ownerID) {
                    try NativeAccountAppearance(ownerID: ownerID, prefs: .object(["theme": .string(appearance == "light" ? "light" : "dark"), "color": .object(["key": .string(key)])]))
                }
            }
            return
        }
        #endif
        await accountAppearance.refresh(ownerID: appearanceOwnerID) {
            try await store.withAuthenticatedSession { api, session in try await api.nativeAccountAppearance(session: session) }
        }
    }
}

private struct NativeLoginView: View {
    let store: NativeStore
    @State private var showingWebLogin = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 32) {
                    Image("AppMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text("welcome.title")
                        .font(OriginalYapper.font(32, weight: .bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("native.welcome.title")
                    if let message = store.errorMessage {
                        NativeErrorBanner(message: message)
                    }
                    Button {
                        showingWebLogin = true
                    } label: {
                        Text("welcome.signIn")
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(YapperPrimaryButtonStyle())
                    .disabled(store.authState == .signingIn)
                    .accessibilityIdentifier("native.login.web")
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NativeLegalFooter()
        }
        .background(YapperPalette.background.ignoresSafeArea())
        .sheet(isPresented: $showingWebLogin) {
            WebLoginSheet(store: store)
        }
    }
}

private struct NativeLegalFooter: View {
    // Fixed HTTPS destinations match Yapper's published authentication footer.
    private let termsURL = URL(string: "https://www.yapin.gg/terms")!
    private let privacyURL = URL(string: "https://www.yapin.gg/privacy")!

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) {
                terms.fixedSize(horizontal: true, vertical: false)
                privacy.fixedSize(horizontal: true, vertical: false)
            }
            VStack(spacing: 0) {
                terms
                privacy
            }
        }
        .font(OriginalYapper.font(13))
        .multilineTextAlignment(.center)
        .foregroundStyle(YapperPalette.secondary)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(YapperPalette.background)
    }

    private var terms: some View {
        Link(destination: termsURL) {
            Text("welcome.terms")
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("native.terms")
    }

    private var privacy: some View {
        Link(destination: privacyURL) {
            Text("welcome.privacy")
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("native.privacy")
    }
}

private extension String {
    var nativePresenceLabel: String {
        switch self {
        case "online": "Online"
        case "idle", "away": "Abwesend"
        case "dnd", "busy": "Bitte nicht stören"
        case "invisible", "offline": "Offline"
        default: "Angemeldet"
        }
    }
}

struct NativeAccountView: View {
    let store: NativeStore
    var isSheet = true
    var onOpenConversation: @MainActor (Conversation) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.appearance") private var appearance = "dark"
    @AppStorage("native.showAvatars") private var showAvatars = true
    @AppStorage("native.showImages") private var showImages = true
    @State private var confirmingSignOut = false
    @State private var tab: Tab = .account
    @State private var ownProfile: NativeProfileDetail?
    @State private var showingEditor = false
    @State private var flags = Set<String>()
    @State private var privacy: NativeDMPrivacy = .servers
    @State private var email: String?
    @State private var savingPrivacy = false
    @State private var settingsError: String?
    private enum Tab: String, CaseIterable, Identifiable {
        case account, profile, appearance, security, plugins, community, developer, data, about
        var id: Self { self }
        var title: String {
            switch self { case .account: "Mein Konto"; case .profile: "Mein Profil"; case .appearance: "Darstellung"; case .security: "Sicherheit & Datenschutz"; case .plugins: "Yapinplugger"; case .community: "Community, Shards & Hilfe"; case .developer: "Apps & Bots"; case .data: "Meine Daten & Konto"; case .about: "Über Yapper" }
        }
        var icon: String {
            switch self { case .account: "H"; case .profile: "friends"; case .appearance: "settings"; case .security: "settings"; case .plugins: "plus"; case .community: "compass"; case .developer: "createGroup"; case .data: "folder"; case .about: "inbox" }
        }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Tab.allCases) { item in
                                Button { if item == .profile { showingEditor = true } else { tab = item } } label: {
                                    HStack(spacing: 8) { OriginalYapperIcon(item.icon, size: 16); Text(item.title) }
                                        .font(OriginalYapper.font(15, weight: .semibold)).lineLimit(1)
                                        .frame(minHeight: 40).padding(.horizontal, 14).contentShape(.interaction, Rectangle().inset(by: -2))
                                        .foregroundStyle(tab == item ? YapperPalette.onAccent : YapperPalette.secondary)
                                        .background(tab == item ? YapperPalette.accentFill : YapperPalette.elevated, in: .capsule)
                                }.buttonStyle(.plain).accessibilityIdentifier("native.settings.tab.\(item.rawValue)")
                            }
                        }.padding(.leading, 12).padding(.trailing, isSheet ? 0 : 12)
                    }.accessibilityIdentifier("native.settings.tabs")
                    if isSheet {
                        Button { dismiss() } label: { OriginalYapperIcon("close", size: 20).frame(width: 44, height: 40).contentShape(.interaction, Rectangle().inset(by: -2)) }.buttonStyle(.plain).accessibilityLabel("Fertig").padding(.trailing, 8)
                    }
                }.padding(.top, 12).padding(.bottom, 8).background(YapperPalette.sidebar)
                Group {
                    switch tab {
                    case .account, .profile: accountPage
                    case .appearance: appearancePage
                    case .security: NativeSecurityView(store: store)
                    case .plugins: NativePluginsView()
                    case .community: NativeCommunityView(store: store)
                    case .developer: NativeDeveloperView(store: store)
                    case .data: NativeAccountDataView(store: store)
                    case .about: aboutPage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
            .background(YapperPalette.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog("Von Yapper abmelden?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { dismiss(); store.signOut() }.accessibilityIdentifier("native.settings.signOut.confirm")
            } message: { Text("Die Anmeldung und ungesendete Entwürfe werden auf diesem Gerät entfernt.") }
            .sheet(isPresented: $showingEditor) {
                if let ownProfile { NavigationStack { NativeProfileEditor(store: store, profile: ownProfile, featureFlags: flags) { self.ownProfile = $0 } } }
            }
            .task { await loadProfile(); await loadAccountSettings() }
        }
        .nativeServerAppearance(ownerID: store.user?.id, serverID: nil, theme: .null)
    }
    private var accountPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Mein Konto").font(OriginalYapper.font(20, weight: .bold))
                if let user = store.user {
                    VStack(spacing: 0) {
                        if let profile = ownProfile, let banner = profile.bannerURL {
                            NativeCroppedImage(url: banner, crop: NativeImageCrop(x: profile.bannerX, y: profile.bannerY, zoom: profile.bannerZoom))
                                .aspectRatio(3, contentMode: .fit).frame(maxWidth: .infinity).clipped()
                        } else { YapperPalette.accent.frame(height: 90).frame(maxWidth: .infinity) }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .bottom, spacing: 14) {
                                NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: 80, decorationURL: user.avatarDecorationURL, crop: user.avatarCrop).padding(6).background(YapperPalette.sidebar, in: .circle).padding(.top, -34)
                                VStack(alignment: .leading, spacing: 3) {
                                    NativeDisplayName(name: user.displayName, bannerURL: user.nameBannerURL).font(OriginalYapper.font(20, weight: .heavy)).fixedSize(horizontal: false, vertical: true)
                                    Text("@\(user.username)").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                                }.padding(.bottom, 4)
                                Spacer(minLength: 0)
                            }
                            Button { showingEditor = true } label: { Text("Profil bearbeiten").font(OriginalYapper.font(14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 36).foregroundStyle(.white).background(YapperPalette.accentFill, in: .rect(cornerRadius: 8)).padding(.vertical, 4).contentShape(.rect) }.buttonStyle(.plain).padding(.top, 10).disabled(ownProfile == nil).accessibilityIdentifier("native.profile.edit")
                            VStack(spacing: 0) {
                                editableAccountRow("Anzeigename", value: user.displayName)
                                Rectangle().fill(YapperPalette.border).frame(height: 1)
                                editableAccountRow("Benutzername", value: user.username)
                                Rectangle().fill(YapperPalette.border).frame(height: 1)
                                accountRow("E-Mail", value: email ?? "…")
                            }.padding(.horizontal, 14).padding(.vertical, 6).background(YapperPalette.background, in: .rect(cornerRadius: 10)).padding(.top, 8)
                        }.padding(.horizontal, 16).padding(.bottom, 16)
                    }.background(YapperPalette.sidebar).clipShape(.rect(cornerRadius: 14))
                }
                OriginalSettingsSection("Datenschutz") {
                    OriginalSettingsField("Wer kann dir schreiben?") {
                        Menu {
                            ForEach(NativeDMPrivacy.allCases) { option in Button(option.label) { Task { await setPrivacy(option) } } }
                        } label: { HStack { Text(privacy.label); Spacer(); OriginalYapperIcon("chevronDown", size: 14) }.font(OriginalYapper.font(16)).padding(.horizontal, 12).frame(minHeight: 42).background(YapperPalette.rail, in: .rect(cornerRadius: 8)) }.buttonStyle(.plain).disabled(savingPrivacy).accessibilityIdentifier("native.security.dmPrivacy")
                    }
                    Text("Freunde können dir immer schreiben. Blockierte Personen können dir keine Nachrichten senden.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                }
                OriginalSettingsSection("Bug Hunting") {
                    Text("Etwas funktioniert nicht richtig? Melde es und erhalte das Bug-Hunter-Abzeichen.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                    NavigationLink { NativeBugReportsView(store: store, canEdit: flags.contains("bug_edit")) } label: { Text("Fehler melden") }.buttonStyle(OriginalYapperButtonStyle(primary: true))
                }
                if let settingsError { NativeErrorBanner(message: settingsError) }
            }.padding(16).padding(.bottom, 28)
        }
    }
    private func accountRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(OriginalYapper.font(11, weight: .heavy)).tracking(0.55).foregroundStyle(YapperPalette.secondary).frame(minHeight: 15.4, alignment: .leading)
            Text(value).font(OriginalYapper.font(15)).frame(minHeight: 21, alignment: .leading).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }
    private func editableAccountRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
            accountRow(label, value: value)
            Button("Ändern") { showingEditor = true }.font(OriginalYapper.font(14, weight: .semibold)).padding(.horizontal, 12).frame(height: 36).background(YapperPalette.active, in: .rect(cornerRadius: 8)).contentShape(.interaction, Rectangle().inset(by: -4)).buttonStyle(.plain)
        }
    }
    private var appearancePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Darstellung").font(OriginalYapper.font(20, weight: .bold))
                OriginalSettingsSection("Design") {
                    HStack(spacing: 8) {
                        appearanceChoice("Dunkel", value: "dark", color: Color(red: 34/255, green: 35/255, blue: 41/255))
                        appearanceChoice("Hell", value: "light", color: .white)
                        appearanceChoice("System", value: "system", color: YapperPalette.sidebar)
                    }
                }
                NativeChatAppearanceSettings(store: store)
                OriginalSettingsSection("Bilder") {
                    Toggle("Profilbilder laden", isOn: $showAvatars).toggleStyle(OriginalYapperToggleStyle())
                    Rectangle().fill(YapperPalette.border).frame(height: 1)
                    Toggle("Bildvorschauen laden", isOn: $showImages).toggleStyle(OriginalYapperToggleStyle())
                }
            }.padding(16).padding(.bottom, 28)
        }
    }
    private func appearanceChoice(_ title: String, value: String, color: Color) -> some View {
        Button { appearance = value; NativeAppearanceState.shared.setLocalTheme(value) } label: {
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(color).frame(height: 64).overlay(alignment: .topTrailing) { if (NativeAppearanceState.shared.preferredTheme ?? appearance) == value { Image(systemName: "checkmark.circle.fill").foregroundStyle(YapperPalette.accent).padding(6) } }
                Text(title).font(OriginalYapper.font(13, weight: .semibold))
            }.padding(8).frame(maxWidth: .infinity).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((NativeAppearanceState.shared.preferredTheme ?? appearance) == value ? YapperPalette.accent : YapperPalette.border, lineWidth: (NativeAppearanceState.shared.preferredTheme ?? appearance) == value ? 2 : 1))
        }.buttonStyle(.plain)
    }
    private var aboutPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Über Yapper").font(OriginalYapper.font(20, weight: .bold))
                OriginalSettingsSection("Yapper Native") {
                    accountRow("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Eigenständiger nativer Yapper-Client. Funktionsumfang und geprüfte Grenzen sind im öffentlichen Quellcode dokumentiert.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                    NavigationLink { NativeLicensesView() } label: { OriginalSettingsRow(title: "Open-Source-Lizenzen", icon: "folder") }.buttonStyle(.plain)
                    Button { confirmingSignOut = true } label: { OriginalSettingsRow(title: "Abmelden", icon: "logout", destructive: true, disclosure: false) }.buttonStyle(.plain).accessibilityIdentifier("native.settings.signOut")
                }
            }.padding(16).padding(.bottom, 28)
        }
    }
    private func loadAccountSettings() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { email = "demo@example.invalid"; return }
        #endif
        do {
            let result = try await store.withAuthenticatedSession { api, session in
                let account = try await api.securityAccount(session: session)
                let privacy = try await api.securityDMPrivacy(session: session)
                return (account.email, privacy)
            }
            email = result.0; privacy = result.1
        } catch is CancellationError {} catch { settingsError = error.localizedDescription }
    }
    private func setPrivacy(_ value: NativeDMPrivacy) async {
        guard !savingPrivacy else { return }; savingPrivacy = true; defer { savingPrivacy = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { privacy = value; return }
        #endif
        do { try await store.withAuthenticatedSession { api, session in try await api.saveSecurityDMPrivacy(value, session: session) }; privacy = value }
        catch is CancellationError {} catch { settingsError = error.localizedDescription }
    }
    private func loadProfile() async {
        guard let id = store.user?.id else { return }
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { ownProfile = try NativeSocialModel(store: store).fixtureProfile(userID: id); flags = ["server_tags", "tag_icons", "temp_avatar"]; return }
            #endif
            ownProfile = try await store.withAuthenticatedSession { api, session in try await api.socialProfiles(ids: [id], session: session).first }
            flags = try await store.withAuthenticatedSession { api, session in try await api.communityFlags(session: session) }
        } catch is CancellationError {} catch { /* The account remains usable if optional profile artwork fails. */ }
    }
}
