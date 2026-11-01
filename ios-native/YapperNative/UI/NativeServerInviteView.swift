import SwiftUI

struct NativeServerJoinView: View {
    let store: NativeStore
    let onJoined: @MainActor (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var invite = ""
    @State private var invitation: NativeServerInvitation?
    @State private var application: NativeServerApplication?
    @State private var loadedCode: String?
    @State private var answers: [String] = []
    @State private var message = ""
    @State private var pending = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Einladungslink oder Code", text: $invite).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(busy)
                    Button("Einladung prüfen") { Task { await load() } }.disabled(busy || invite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let invitation { invitationSection(invitation) }
                if let error { NativeErrorBanner(message: error) }
                if busy { ProgressView("Einladung wird geladen …") }
            }
            .navigationTitle("Server beitreten").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() }.disabled(busy) } }
            .onChange(of: invite) { _, _ in invitation = nil; application = nil; loadedCode = nil; pending = false; error = nil }
            .refreshable { if loadedCode != nil { await load() } }
            .yapperNavigation()
        }.interactiveDismissDisabled(busy)
    }

    @ViewBuilder private func invitationSection(_ invitation: NativeServerInvitation) -> some View {
        Section {
            HStack(spacing: 14) {
                NativeAvatar(name: invitation.name, url: NativeConfiguration.publicAsset(bucket: "icons", path: invitation.iconPath), size: 60)
                VStack(alignment: .leading, spacing: 5) {
                    Text(invitation.name).font(OriginalYapper.font(16, weight: .semibold))
                    if let count = invitation.memberCount { Text("\(count) Mitglieder").font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary) }
                }
            }.padding(.vertical, 8)
            if invitation.alreadyMember {
                Button("Server öffnen") { Task { await onJoined(invitation.serverID); dismiss() } }.disabled(busy)
            } else if pending || application?.requestStatus == "pending" {
                Label("Anfrage gesendet. Die Moderation entscheidet über deinen Beitritt.", systemImage: "clock")
                Button("Anfrage zurückziehen", role: .destructive) { Task { await withdraw(invitation.serverID) } }.disabled(busy)
            } else if let application, application.apply {
                applicationFields(application)
            } else {
                Button("Einladung annehmen") { Task { await join() } }.disabled(busy)
            }
        }
    }

    @ViewBuilder private func applicationFields(_ application: NativeServerApplication) -> some View {
        if application.requestStatus == "declined" {
            Text("Deine letzte Anfrage wurde abgelehnt.").font(OriginalYapper.font(16, weight: .semibold))
            if let note = application.note, !note.isEmpty { Text(note).foregroundStyle(YapperPalette.secondary) }
        }
        if let retry = application.retryAt, retry > Date() {
            Text("Du kannst dich ab \(retry.formatted(date: .abbreviated, time: .shortened)) erneut bewerben.").foregroundStyle(YapperPalette.secondary)
        } else {
            Text("Die Moderation prüft neue Mitglieder. Stelle dich kurz vor.").foregroundStyle(YapperPalette.secondary)
            ForEach(Array(application.questions.enumerated()), id: \.offset) { index, question in
                TextField(question, text: Binding(get: { index < answers.count ? answers[index] : "" }, set: { value in
                    if index < answers.count { answers[index] = String(value.prefix(300)) }
                }), axis: .vertical).lineLimit(1...5)
            }
            TextField(application.questions.isEmpty ? "Nachricht an die Moderation" : "Möchtest du noch etwas ergänzen?", text: $message, axis: .vertical).lineLimit(3...8)
                .onChange(of: message) { _, value in if value.count > 500 { message = String(value.prefix(500)) } }
            Button("Anfrage senden") { Task { await apply() } }.disabled(busy)
        }
    }

    private func load() async {
        busy = true; error = nil; defer { busy = false }
        do {
            let code = try NativeServerInput.inviteCode(invite)
            let preview = try await store.withAuthenticatedSession { api, session in try await api.nativeServerInvitation(code: code, session: session) }
            let info = preview.alreadyMember ? nil : try await store.withAuthenticatedSession { api, session in try await api.nativeServerApplication(code: code, session: session) }
            loadedCode = code; invitation = preview; application = info; answers = Array(repeating: "", count: info?.questions.count ?? 0); pending = false
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func join() async {
        guard let code = loadedCode else { return }; busy = true; error = nil; defer { busy = false }
        do { let id = try await store.withAuthenticatedSession { api, session in try await api.nativeJoinServer(invite: code, session: session) }; await onJoined(id); dismiss() }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func apply() async {
        guard let code = loadedCode else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let joined = try await store.withAuthenticatedSession { api, session in try await api.nativeApplyToServer(code: code, message: message, answers: answers, session: session) }
            if let joined { await onJoined(joined); dismiss() } else { pending = true }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func withdraw(_ serverID: String) async {
        busy = true; error = nil
        do { try await store.withAuthenticatedSession { api, session in try await api.nativeWithdrawServerApplication(serverID: serverID, session: session) }; busy = false; await load() }
        catch is CancellationError { busy = false }
        catch { busy = false; self.error = error.localizedDescription }
    }
}
