import SwiftUI

struct NativeRootView: View {
    let store: NativeStore
    @State private var didRestoreSession = false
    @AppStorage("native.appearance") private var appearance = "dark"

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            switch store.authState {
            case .signedIn:
                NativeConversationList(store: store)
            case .restoring:
                ZStack {
                    YapperPalette.background.ignoresSafeArea()
                    VStack(spacing: 24) {
                        Image("AppMark")
                            .resizable().scaledToFit().frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                        ProgressView("Anmeldung wird wiederhergestellt …")
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
        .preferredColorScheme(colorScheme)
        .task {
            guard !didRestoreSession else { return }
            didRestoreSession = true
            await store.restoreSession()
        }
    }
}

private struct NativeLoginView: View {
    let store: NativeStore
    @State private var identifier = ""
    @State private var password = ""
    @State private var code = ""
    @State private var passwordVisible = false
    @State private var awaitingCode = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case identifier, password, code }
    private var needsCode: Bool { awaitingCode || store.authState == .requiresTwoFactor }
    private var isSigningIn: Bool { store.authState == .signingIn }
    private var normalizedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        guard !isSigningIn else { return false }
        if needsCode {
            return normalizedCode.utf8.count == 6 && normalizedCode.utf8.allSatisfy { (48...57).contains($0) }
        }
        return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        VStack(alignment: .leading, spacing: 18) {
                            Image("AppMark")
                                .resizable().scaledToFit().frame(width: 72, height: 72)
                                .accessibilityHidden(true)
                            Text("Willkommen bei Yapper")
                                .font(.largeTitle.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Deine Gespräche. Jetzt nativ auf dem iPhone.")
                                .font(.body)
                                .foregroundStyle(YapperPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("E-Mail oder Benutzername").font(.subheadline.weight(.semibold))
                                TextField("Dein Yapper-Konto", text: $identifier)
                                    .textContentType(.username)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .identifier)
                                    .submitLabel(.next)
                                    .onSubmit { focusedField = .password }
                                    .accessibilityIdentifier("native.login.identifier")
                                    .loginField()
                            }
                            .disabled(needsCode)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Passwort").font(.subheadline.weight(.semibold))
                                HStack(spacing: 4) {
                                    Group {
                                        if passwordVisible {
                                            TextField("Dein Passwort", text: $password)
                                        } else {
                                            SecureField("Dein Passwort", text: $password)
                                        }
                                    }
                                    .textContentType(.password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .password)
                                    .submitLabel(needsCode ? .next : .go)
                                    .onSubmit {
                                        if needsCode { focusedField = .code } else { submit() }
                                    }
                                    .accessibilityIdentifier("native.login.password")
                                    Button {
                                        passwordVisible.toggle()
                                    } label: {
                                        Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                            .frame(width: 44, height: 44)
                                    }
                                    .foregroundStyle(YapperPalette.secondary)
                                    .accessibilityLabel(passwordVisible ? "Passwort verbergen" : "Passwort anzeigen")
                                }
                                .loginField()
                            }
                            .disabled(needsCode)
                            if needsCode {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Bestätigungscode").font(.subheadline.weight(.semibold))
                                    TextField("6-stelliger Authenticator-Code", text: $code)
                                        .textContentType(.oneTimeCode)
                                        .keyboardType(.numberPad)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .focused($focusedField, equals: .code)
                                        .submitLabel(.go)
                                        .onSubmit(submit)
                                        .accessibilityIdentifier("native.login.code")
                                        .loginField()
                                }
                            }
                            if let message = store.errorMessage {
                                NativeErrorBanner(message: message)
                            }
                            Button(action: submit) {
                                HStack(spacing: 10) {
                                    if isSigningIn { ProgressView().tint(YapperPalette.accentLabel) }
                                    Text(needsCode ? "Code bestätigen" : "Anmelden")
                                }
                            }
                            .buttonStyle(YapperPrimaryButtonStyle())
                            .disabled(!canSubmit)
                            .accessibilityIdentifier("native.login.submit")
                        }
                        .disabled(isSigningIn)

                        if needsCode {
                            Button("Anmeldung abbrechen") {
                                focusedField = nil
                                code = ""
                                password = ""
                                awaitingCode = false
                                store.cancelSignIn()
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityIdentifier("native.login.cancel")
                        }

                        Text("Mit deinem bestehenden Yapper-Konto anmelden. Diese native Vorschau unterstützt Nachrichten; Anrufe und Plugins folgen separat.")
                            .font(.footnote)
                            .foregroundStyle(YapperPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 32)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(YapperPalette.background.ignoresSafeArea())
            }
            .navigationBarHidden(true)
            .onChange(of: store.authState) { _, state in
                if state == .requiresTwoFactor {
                    awaitingCode = true
                    focusedField = .code
                }
                if state == .signedOut {
                    awaitingCode = false
                    code = ""
                }
                if state == .signedIn {
                    identifier = ""
                    password = ""
                    code = ""
                    awaitingCode = false
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        let factorCode = needsCode ? normalizedCode : nil
        let account = identifier
        let secret = password
        if needsCode { awaitingCode = true }
        Task {
            await store.signIn(identifier: account, password: secret, code: factorCode)
        }
    }
}

private extension View {
    func loginField() -> some View {
        self
            .font(.body)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(YapperPalette.input, in: .rect(cornerRadius: 12))
    }
}

struct NativeConversationList: View {
    let store: NativeStore
    @State private var search = ""
    @State private var showingAccount = false

    private var filteredConversations: [Conversation] {
        guard !search.isEmpty else { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || ($0.lastMessage?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    fixtureNotice
                    if let message = store.errorMessage {
                        NativeErrorBanner(message: message) {
                            Task { await store.loadConversations() }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if store.isLoading && store.conversations.isEmpty {
                        ProgressView("Gespräche werden geladen …")
                            .padding(.vertical, 64)
                    } else if filteredConversations.isEmpty {
                        ContentUnavailableView(
                            search.isEmpty ? "Noch keine Gespräche" : "Keine Treffer",
                            systemImage: search.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                            description: Text(search.isEmpty
                                ? "Deine bestehenden Direktnachrichten erscheinen hier. Ziehe nach unten, um sie zu aktualisieren."
                                : "Versuche einen anderen Namen oder Suchbegriff.")
                        )
                        .padding(.top, 44)
                    } else {
                        ForEach(filteredConversations) { conversation in
                            NavigationLink {
                                NativeConversationView(store: store, conversation: conversation)
                            } label: {
                                NativeConversationRow(conversation: conversation)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("native.conversation.\(conversation.id)")
                        }
                    }
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
            }
            .accessibilityIdentifier("native.conversations.list")
            .background(YapperPalette.background.ignoresSafeArea())
            .refreshable { await store.loadConversations() }
            .searchable(text: $search, prompt: "Gespräche durchsuchen")
            .navigationTitle("Nachrichten")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAccount = true
                    } label: {
                        Image(systemName: "gearshape").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Konto und Einstellungen")
                    .accessibilityIdentifier("native.settings")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let user = store.user {
                    NativeAccountBar(user: user) { showingAccount = true }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background(YapperPalette.background)
                }
            }
            .sheet(isPresented: $showingAccount) {
                NativeAccountView(store: store)
            }
            .task { await store.loadConversations() }
            .yapperNavigation()
        }
    }

    @ViewBuilder private var fixtureNotice: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") {
            Label("Testansicht · Beispieldaten", systemImage: "testtube.2")
                .font(.footnote.weight(.medium))
                .foregroundStyle(YapperPalette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .accessibilityIdentifier("native.fixture.notice")
        }
        #endif
    }
}

private struct NativeConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            NativeAvatar(name: conversation.title, url: conversation.avatarURL, size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(conversation.title)
                    .font(.body.weight(conversation.unreadCount > 0 ? .bold : .semibold))
                    .foregroundStyle(YapperPalette.text)
                    .lineLimit(2)
                Text(conversation.lastMessage ?? (conversation.isGroup ? "Gruppengespräch" : "Direktnachricht"))
                    .font(.subheadline)
                    .foregroundStyle(YapperPalette.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if conversation.unreadCount > 0 {
                Text(conversation.unreadCount > 99 ? "99+" : "\(conversation.unreadCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(YapperPalette.accentLabel)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(YapperPalette.accent, in: .capsule)
                    .accessibilityLabel("\(conversation.unreadCount) ungelesene Nachrichten")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(YapperPalette.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 78)
        .contentShape(.rect)
    }
}

private struct NativeAccountBar: View {
    let user: YapperUser
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NativeAvatar(name: user.displayName, url: user.avatarURL, presence: user.presence, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(user.displayName)
                        .font(.headline)
                        .foregroundStyle(YapperPalette.text)
                        .lineLimit(dynamicType.isAccessibilitySize ? 3 : 1)
                    Text(user.presence.nativePresenceLabel)
                        .font(.subheadline)
                        .foregroundStyle(YapperPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YapperPalette.secondary)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: 380, minHeight: 72)
            .background(YapperPalette.sidebar, in: .rect(cornerRadius: 22))
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(user.displayName), \(user.presence.nativePresenceLabel). Konto öffnen")
        .accessibilityIdentifier("native.account")
        .frame(maxWidth: .infinity, alignment: .center)
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("native.appearance") private var appearance = "dark"
    @AppStorage("native.showAvatars") private var showAvatars = true
    @AppStorage("native.showImages") private var showImages = true
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = store.user {
                    Section {
                        HStack(spacing: 16) {
                            NativeAvatar(name: user.displayName, url: user.avatarURL, presence: user.presence, size: 64)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(user.displayName).font(.title2.bold())
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("@\(user.username)").font(.subheadline)
                                    .foregroundStyle(YapperPalette.secondary)
                                Text(user.presence.nativePresenceLabel).font(.subheadline)
                                    .foregroundStyle(YapperPalette.secondary)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .listRowBackground(YapperPalette.sidebar)
                }
                Section("Darstellung") {
                    Picker("Design", selection: $appearance) {
                        Text("Dunkel").tag("dark")
                        Text("Hell").tag("light")
                        Text("Wie das System").tag("system")
                    }
                    Toggle("Profilbilder laden", isOn: $showAvatars)
                    Toggle("Bildvorschauen laden", isOn: $showImages)
                }
                .listRowBackground(YapperPalette.sidebar)
                Section {
                    LabeledContent("Oberfläche", value: "SwiftUI")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text("Native Vorschau für Anmeldung und Direktnachrichten. Anrufe, Push-Mitteilungen und die JavaScript-Plugins sind in dieser Version noch nicht enthalten.")
                        .font(.footnote)
                        .foregroundStyle(YapperPalette.secondary)
                } header: {
                    Text("Yapper Native")
                }
                .listRowBackground(YapperPalette.sidebar)
                Section {
                    Button("Abmelden", role: .destructive) {
                        confirmingSignOut = true
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("native.settings.signOut")
                }
                .listRowBackground(YapperPalette.sidebar)
            }
            .scrollContentBackground(.hidden)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle("Konto & Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.frame(minHeight: 44)
                }
            }
            .confirmationDialog("Von Yapper abmelden?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) {
                    dismiss()
                    store.signOut()
                }
            } message: {
                Text("Die Anmeldung und ungesendete Entwürfe werden auf diesem Gerät entfernt.")
            }
            .yapperNavigation()
        }
    }
}
