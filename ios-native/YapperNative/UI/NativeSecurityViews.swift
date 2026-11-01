import SwiftUI
import CoreImage.CIFilterBuiltins

private struct NativeEmailChangeView: View {
    let store: NativeStore
    let current: String?
    let pending: String?
    let isFixture: Bool
    @State private var email = ""
    @State private var sending = false
    @State private var requested = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        OriginalModalPage("E-Mail-Adresse ändern", onClose: { if !sending { email = ""; dismiss() } }) {
            if let current { OriginalSettingsField("Aktuelle Adresse") { Text(current).privacySensitive() } }
            if let pending { OriginalSettingsField("Ausstehende Adresse") { Text(pending).privacySensitive() } }
            if requested {
                HStack(spacing: 8) { Image(systemName: "checkmark.circle"); Text("Änderung angefordert") }.foregroundStyle(YapperPalette.success)
                Text("Prüfe deine bisherige und deine neue E-Mail-Adresse und bestätige beide Links. Die Adresse wird erst nach der Bestätigung geändert. Sieh auch im Spam-Ordner nach.")
            } else {
                OriginalSettingsField("Neue Adresse") {
                    TextField("name@beispiel.de", text: $email).keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().textFieldStyle(OriginalYapperTextFieldStyle())
                }
            }
            if let error { NativeErrorBanner(message: error) }
        } footer: {
            Button(requested ? "Fertig" : "Abbrechen") { email = ""; dismiss() }.buttonStyle(OriginalYapperButtonStyle()).disabled(sending)
            if !requested { Button(sending ? "Wird angefordert …" : "Bestätigungslinks anfordern") { Task { await submit() } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(sending || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .interactiveDismissDisabled(sending)
    }
    private func submit() async {
        guard !sending else { return }; sending = true; error = nil; defer { sending = false }
        do {
            #if DEBUG
            if isFixture { error = "In der Testansicht wird keine E-Mail-Änderung angefordert."; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.requestSecurityEmailChange(email, session: session) }
            email = ""; requested = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativeSecurityView: View {
    let store: NativeStore
    @State private var model: NativeSecurityModel
    @State private var renameKey: NativePasskey?
    @State private var renameName = ""
    @State private var removeKey: NativePasskey?
    @State private var removeGrant: NativeOAuthGrant?
    @State private var removeFactor: NativeSecurityFactor?
    @State private var showingPassword = false
    @State private var showingEmail = false
    @State private var showingLogout = false

    init(store: NativeStore) {
        self.store = store
        _model = State(initialValue: NativeSecurityModel(store: store))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Sicherheit & Datenschutz").font(OriginalYapper.font(20, weight: .bold))
            if model.isFixture {
                Label("Testansicht · Keine Sicherheitsänderungen", systemImage: "testtube.2")
                    .font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            }
            if model.isLoading { ProgressView("Sicherheit wird geladen …").frame(maxWidth: .infinity) }
            if let error = model.error { NativeErrorBanner(message: error) { Task { await model.load() } } }
            accountSection
            factorSection
            passkeySection
            grantSection
            privacySection
            logoutSection
            }.padding(16).padding(.bottom, 28)
        }
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
        .buttonStyle(OriginalYapperButtonStyle())
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle("Sicherheit & Datenschutz")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(model.isBusy)
        .task { await model.load() }
        .refreshable { await model.load() }
        .alert("Passkey umbenennen", isPresented: Binding(get: { renameKey != nil }, set: { if !$0 { renameKey = nil } })) {
            TextField("Name", text: $renameName)
            Button("Abbrechen", role: .cancel) { renameKey = nil }
            Button("Speichern") {
                guard let key = renameKey else { return }
                let name = renameName
                Task { await model.rename(key, name: name) }
                renameKey = nil
            }
            .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameName.utf16.count > 40)
        } message: { Text("Der Name darf höchstens 40 Zeichen haben.") }
        .confirmationDialog("Passkey entfernen?", isPresented: Binding(get: { removeKey != nil }, set: { if !$0 { removeKey = nil } }), titleVisibility: .visible) {
            if let key = removeKey {
                Button("\(key.name) entfernen", role: .destructive) { Task { await model.remove(key) } }
            }
        } message: { Text("Damit kannst du dich mit diesem Passkey nicht mehr bei Yapper anmelden. Der Eintrag in deinem Passwortmanager wird separat verwaltet.") }
        .confirmationDialog("App-Zugriff entfernen?", isPresented: Binding(get: { removeGrant != nil }, set: { if !$0 { removeGrant = nil } }), titleVisibility: .visible) {
            if let grant = removeGrant {
                Button("Zugriff für \(grant.name) entfernen", role: .destructive) { Task { await model.revoke(grant) } }
            }
        } message: { Text("Die ausgewählte App verliert ihre von Yapper erteilte Berechtigung.") }
        .confirmationDialog("Auf allen Geräten abmelden?", isPresented: $showingLogout, titleVisibility: .visible) {
            Button("Überall abmelden", role: .destructive) { Task { await model.logoutEverywhere() } }
        }
        .sheet(item: $removeFactor) { factor in
            NavigationStack { NativeFactorRemovalView(model: model, factor: factor) }
        }
        .sheet(isPresented: Binding(get: { model.pendingEnrollment != nil }, set: { _ in })) {
            if let enrollment = model.pendingEnrollment {
                NavigationStack { NativeTOTPSetupView(model: model, enrollment: enrollment) }
            }
        }
        .sheet(isPresented: $showingPassword) {
            NavigationStack { NativePasswordChangeView(store: store, isFixture: model.isFixture) }
        }
        .sheet(isPresented: $showingEmail, onDismiss: { Task { await model.load() } }) {
            NavigationStack { NativeEmailChangeView(store: store, current: model.account?.email, pending: model.account?.pendingEmail, isFixture: model.isFixture) }
        }
        .yapperNavigation()
    }

    private var logoutSection: some View {
OriginalSettingsSection("Sitzungen") {
                Button("Überall abmelden", role: .destructive) { showingLogout = true }.buttonStyle(OriginalYapperButtonStyle())
                Text("Meldet dieses Konto auf allen Geräten ab, auch hier.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            }
    }

    private var accountSection: some View {
        OriginalSettingsSection("Dein Konto") {
            if let user = store.user { LabeledContent("Benutzername", value: "@\(user.username)") }
            if let account = model.account {
                if let email = account.email { LabeledContent("E-Mail", value: email).privacySensitive() }
                if let pending = account.pendingEmail { LabeledContent("Ausstehende E-Mail", value: pending).privacySensitive() }
                if let date = account.lastSignIn { LabeledContent("Letzte Kontoanmeldung") { Text(date, format: .dateTime).multilineTextAlignment(.trailing) } }
            }
            Button("Passwort ändern", systemImage: "key") { showingPassword = true }
                .frame(minHeight: 44)
                .accessibilityIdentifier("native.security.password")
            Button("E-Mail-Adresse ändern", systemImage: "envelope") { showingEmail = true }
                .frame(minHeight: 44).accessibilityIdentifier("native.security.email")
        }
    }

    private var factorSection: some View {
        OriginalSettingsSection("Zwei-Faktor-Authentifizierung") {
            if let account = model.account {
                if account.factors.isEmpty { Text("Kein zusätzlicher Faktor eingerichtet.").foregroundStyle(YapperPalette.secondary) }
                ForEach(account.factors) { factor in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(factor.name, systemImage: factor.type == "totp" ? "number.square" : "lock.shield")
                            .font(OriginalYapper.font(15, weight: .semibold))
                        Text(factor.isVerified ? "Aktiv" : "Einrichtung noch nicht bestätigt")
                            .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                        Button("Entfernen", role: .destructive) { removeFactor = factor }
                            .frame(minHeight: 44)
                    }
                }
                Button("Authenticator einrichten", systemImage: "plus") { Task { await model.beginEnrollment() } }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("native.security.enrollTOTP")
            }
            Text("Ein Authenticator erzeugt zusätzliche Anmeldecodes. Die Einrichtung ist erst nach dem Bestätigen eines Codes aktiv.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
        }
    }

    private var passkeySection: some View {
        OriginalSettingsSection("Passkeys") {
            if let error = model.passkeyError {
                NativeErrorBanner(message: error) { Task { await model.load() } }
            } else if let keys = model.passkeys {
                if keys.isEmpty { Text("Keine Passkeys hinterlegt.").foregroundStyle(YapperPalette.secondary) }
                ForEach(keys) { key in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(key.name, systemImage: "person.badge.key").font(OriginalYapper.font(15, weight: .semibold))
                        if let created = key.createdAt { Text("Hinzugefügt am \(created.formatted(date: .abbreviated, time: .omitted))").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                        if let used = key.lastUsedAt { Text("Zuletzt verwendet am \(used.formatted(date: .abbreviated, time: .omitted))").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                        if key.backedUp { Label("Synchronisiert", systemImage: "icloud").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                        HStack {
                            Button("Umbenennen") { renameName = key.name; renameKey = key }
                            Button("Entfernen", role: .destructive) { removeKey = key }
                        }
                        .buttonStyle(OriginalYapperButtonStyle())
                        .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var grantSection: some View {
        OriginalSettingsSection("Autorisierte Apps") {
            if let error = model.grantsError {
                NativeErrorBanner(message: error) { Task { await model.load() } }
            } else if let grants = model.grants {
                if grants.isEmpty { Text("Du hast keiner App Zugriff erteilt.").foregroundStyle(YapperPalette.secondary) }
                ForEach(grants) { grant in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            NativeAvatar(name: grant.name, url: grant.iconURL, size: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: grant.name).font(OriginalYapper.font(15, weight: .semibold))
                                if let owner = grant.owner { Text(verbatim: "von @\(owner)").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                            }
                        }
                        Text(grant.scope.map { $0 == "identify" ? "Öffentliches Profil ansehen" : $0 }.joined(separator: ", "))
                            .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                        if let date = grant.lastAt { Text("Zuletzt verwendet: \(date.formatted(date: .abbreviated, time: .shortened))").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                        Button("Zugriff entfernen", role: .destructive) { removeGrant = grant }
                            .frame(minHeight: 44)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var privacySection: some View {
        OriginalSettingsSection("Nachrichten-Datenschutz") {
            if let error = model.privacyError { NativeErrorBanner(message: error) { Task { await model.load() } } }
            else if let privacy = model.privacy {
                Picker("Wer kann dir schreiben?", selection: Binding(get: { model.privacy ?? privacy }, set: { value in Task { await model.setPrivacy(value) } })) {
                    ForEach(NativeDMPrivacy.allCases) { option in Text(option.label).tag(option) }
                }
                .accessibilityIdentifier("native.security.dmPrivacy")
            }
            Text("Freunde können dir immer schreiben. Blockierte Personen können dir keine Nachrichten senden.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
        }
    }
}

private struct NativeTOTPSetupView: View {
    let model: NativeSecurityModel
    let enrollment: NativeTOTPEnrollment
    @State private var code = ""
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OriginalModalPage("Authenticator einrichten", subtitle: "Scanne diesen QR-Code mit deiner Authenticator-App oder gib den Einrichtungsschlüssel dort ein.", onClose: {
            if !model.isBusy { Task { await model.cancelEnrollment(); code = ""; dismiss() } }
        }) {
            NativeAuthenticatorQR(uri: enrollment.uri)
            OriginalSettingsField("Einrichtungsschlüssel") {
                Text(enrollment.secret).font(OriginalYapper.font(14).monospaced()).privacySensitive().frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(12).background(YapperPalette.rail, in: .rect(cornerRadius: 8))
                Button(copied ? "Schlüssel kopiert" : "Schlüssel kopieren") {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": enrollment.secret]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)]); copied = true
                }.buttonStyle(OriginalYapperButtonStyle())
            }
            OriginalSettingsField("Code bestätigen") {
                TextField("6-stelliger Code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(OriginalYapperTextFieldStyle())
                    .onChange(of: code) { _, value in code = NativeSecurityInput.code(value) }.accessibilityIdentifier("native.security.totpCode")
            }
            if let error = model.error { NativeErrorBanner(message: error) }
        } footer: {
            Button("Abbrechen") { Task { await model.cancelEnrollment(); code = ""; dismiss() } }.buttonStyle(OriginalYapperButtonStyle()).disabled(model.isBusy)
            Button(model.isBusy ? "Wird bestätigt …" : "Aktivieren") { Task { if await model.verifyEnrollment(code: code) { code = ""; dismiss() } } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(model.isBusy || code.count != 6)
        }
        .interactiveDismissDisabled().privacySensitive()
    }
}

private struct NativeFactorRemovalView: View {
    let model: NativeSecurityModel
    let factor: NativeSecurityFactor
    @State private var code = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OriginalModalPage("Faktor entfernen", subtitle: "\(factor.name) entfernen?", onClose: { if !model.isBusy { code = ""; dismiss() } }) {
            Text(factor.isVerified ? "Mit diesem Faktor kannst du deine Anmeldung danach nicht mehr bestätigen." : "Die angefangene Einrichtung wird entfernt.")
            if factor.isVerified && factor.type == "totp" {
                OriginalSettingsField("Aktueller Authenticator-Code") {
                    TextField("6-stelliger Code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode).textFieldStyle(OriginalYapperTextFieldStyle()).onChange(of: code) { _, value in code = NativeSecurityInput.code(value) }
                }
            }
            if let error = model.error { NativeErrorBanner(message: error) }
        } footer: {
            Button("Abbrechen") { code = ""; dismiss() }.buttonStyle(OriginalYapperButtonStyle()).disabled(model.isBusy)
            Button("Faktor entfernen", role: .destructive) { Task { if await model.removeFactor(factor, code: code) { code = ""; dismiss() } } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(model.isBusy || factor.isVerified && factor.type == "totp" && code.count != 6)
        }
        .interactiveDismissDisabled(model.isBusy)
    }
}

private struct NativePasswordChangeView: View {
    let store: NativeStore
    let isFixture: Bool
    @State private var current = ""
    @State private var replacement = ""
    @State private var confirmation = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var succeeded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OriginalModalPage("Passwort ändern", onClose: { if !isSaving { clear(); dismiss() } }) {
            if succeeded { HStack(spacing: 8) { Image(systemName: "checkmark.circle"); Text("Passwort gespeichert") }.foregroundStyle(YapperPalette.success) }
            else {
                OriginalSettingsField("Aktuelles Passwort") { SecureField("Aktuelles Passwort", text: $current).textContentType(.password).textFieldStyle(OriginalYapperTextFieldStyle()) }
                OriginalSettingsField("Neues Passwort") { SecureField("Neues Passwort", text: $replacement).textContentType(.newPassword).textFieldStyle(OriginalYapperTextFieldStyle()) }
                OriginalSettingsField("Neues Passwort wiederholen") { SecureField("Neues Passwort wiederholen", text: $confirmation).textContentType(.newPassword).textFieldStyle(OriginalYapperTextFieldStyle()) }
                Text("Das neue Passwort braucht 6 bis 72 Zeichen. Hat dein Konto noch kein Passwort, lasse das aktuelle Passwort leer.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                if let error { NativeErrorBanner(message: error) }
            }
        } footer: {
            Button(succeeded ? "Fertig" : "Abbrechen") { clear(); dismiss() }.buttonStyle(OriginalYapperButtonStyle())
            if !succeeded { Button(isSaving ? "Wird gespeichert …" : "Passwort speichern") { Task { await save() } }.buttonStyle(OriginalYapperButtonStyle(primary: true)).disabled(isSaving || !(6...72).contains(replacement.utf16.count) || replacement != confirmation) }
        }
        .disabled(isSaving).interactiveDismissDisabled(isSaving).privacySensitive().onDisappear { clear() }
    }

    private func clear() { current = ""; replacement = ""; confirmation = "" }

    private func save() async {
        guard !isSaving, replacement == confirmation else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            #if DEBUG
            if isFixture { clear(); error = "In der Testansicht werden keine Passwörter geändert."; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.changeSecurityPassword(current: current, replacement: replacement, session: session) }
            clear(); succeeded = true
        } catch is CancellationError { clear() } catch { self.error = error.localizedDescription }
    }
}

private struct NativeAuthenticatorQR: View {
    let uri: String

    private var qr: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { return nil }
        return UIImage(cgImage: image)
    }

    var body: some View {
        if let qr {
            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                .frame(maxWidth: 260).padding(16).background(.white, in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Authenticator-Einrichtungscode")
                .privacySensitive()
        }
    }
}

nonisolated enum NativeSecurityInput {
    static func code(_ input: String) -> String {
        String(input.compactMap { character -> Character? in
            guard character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }),
                  let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            return Character(String(digit))
        }.prefix(6))
    }
}
