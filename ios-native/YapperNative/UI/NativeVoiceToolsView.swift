import SwiftUI
import AVKit
import LiveKit

struct NativeVoiceToolsView: View {
    let store: NativeStore
    @Environment(NativeCallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: NativeServerSnapshot?
    @State private var selected: NativeVoicePerson?
    @State private var bans: [NativeJSON] = []
    @State private var errorMessage: String?
    @State private var busy = false

    private var people: [NativeVoicePerson] {
        var seen = Set<String>()
        return call.participants.compactMap { participant in
            guard let raw = participant.identity?.stringValue else { return nil }
            let id = NativeCallLifecyclePolicy.isScreenCompanion(raw) ? String(raw.dropLast(7)) : raw
            guard UUID(uuidString: id) != nil, id != store.user?.id, seen.insert(id).inserted else { return nil }
            return NativeVoicePerson(id: id, name: participant.name ?? id)
        }
    }

    var body: some View {
        Form {
            Section("Audio") {
                VStack(alignment: .leading) {
                    Text("Ausgabelautstärke: \(Int(call.outputVolume * 100)) %")
                    Slider(value: Binding(get: { call.outputVolume }, set: { call.setOutputVolume($0) }), in: 0...1)
                }
                Toggle("Lautsprecher bevorzugen", isOn: Binding(get: { call.speakerPreferred }, set: { call.preferSpeaker($0) }))
                HStack { Text("Audiogerät wählen"); Spacer(); NativeAudioRoutePicker().frame(width: 44, height: 44) }
            }
            Section("Kamera") {
                Button("Zwischen Front- und Rückkamera wechseln", systemImage: "arrow.triangle.2.circlepath.camera") { Task { await call.flipCamera() } }
                    .disabled(!call.cameraOn)
            }
            if store.capabilities.flagOn("clips", userID: store.user?.id, serverID: call.serverID) {
                Section {
                    Toggle("Meine Stimme nicht für Clips freigeben", isOn: Binding(get: { call.noClip }, set: { value in Task { await call.setNoClip(value) } }))
                } footer: { Text("Übermittelt die offizielle Clip-Präferenz an die anderen Clients im Anruf.") }
            }
            Section("Teilnehmer") {
                if people.isEmpty { Text("Keine weiteren Teilnehmer.").foregroundStyle(.secondary) }
                ForEach(people) { person in
                    Button { selected = person } label: { Label(person.name, systemImage: "person.crop.circle") }
                        .frame(minHeight: 44)
                }
            }
            if let snapshot, snapshot.hasPermission("ban_members", userID: store.user?.id) {
                Section("Aktive Sprachsperren") {
                    if bans.isEmpty { Text("Keine aktiven Sprachsperren.").foregroundStyle(.secondary) }
                    ForEach(Array(bans.enumerated()), id: \.offset) { _, ban in
                        if let id = ban["user_id"].string {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: id).font(OriginalYapper.font(12))
                                if let reason = ban["reason"].string { Text(verbatim: reason) }
                                Button("Sprachsperre aufheben") { unban(id, snapshot: snapshot) }.disabled(busy)
                            }
                        }
                    }
                }
            }
            if let errorMessage { Section { NativeErrorBanner(message: errorMessage) } }
            if busy { Section { ProgressView() } }
        }
        .navigationTitle("Anrufoptionen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        .sheet(item: $selected) { person in
            NavigationStack { NativeVoicePersonView(store: store, person: person, snapshot: snapshot) }
        }
        .task(id: call.serverID) { await load() }
    }

    private func load() async {
        guard let serverID = call.serverID else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await store.withAuthenticatedSession { api, session in
                try await api.nativeServerSnapshot(id: serverID, session: session)
            }
            guard call.serverID == serverID else { return }
            snapshot = result
            if result.hasPermission("ban_members", userID: store.user?.id) {
                bans = try await store.withAuthenticatedSession { api, session in try await NativeVoiceService(api: api).bans(serverID: serverID, session: session) }
            }
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }

    private func unban(_ id: String, snapshot: NativeServerSnapshot) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.withAuthenticatedSession { api, session in try await NativeVoiceService(api: api).unban(userID: id, snapshot: snapshot, session: session) }
                bans.removeAll { $0["user_id"].string == id }
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NativeVoicePerson: Identifiable { let id: String; let name: String }

private struct NativeVoicePersonView: View {
    let store: NativeStore
    let person: NativeVoicePerson
    let snapshot: NativeServerSnapshot?
    @Environment(NativeCallController.self) private var call
    @Environment(\.dismiss) private var dismiss
    @State private var action = NativeVoiceAction.mute
    @State private var minutes = 10
    @State private var destination = ""
    @State private var reason = ""
    @State private var reportReason = NativeReportReason.other
    @State private var reportDetails = ""
    @State private var confirmation = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var reportSent = false
    @State private var openedConversation: Conversation?

    private var permittedActions: [NativeVoiceAction] {
        guard snapshot?.outranks(person.id, userID: store.user?.id) == true else { return [] }
        return NativeVoiceAction.allCases.filter { snapshot?.hasPermission($0.permission, userID: store.user?.id) == true }
    }

    var body: some View {
        Form {
            Section(person.name) {
                NavigationLink("Profil ansehen") {
                    NativeProfileView(store: store, userID: person.id, onOpenConversation: { openedConversation = $0 })
                }
            }
            if !permittedActions.isEmpty {
                Section("Sprachmoderation") {
                    Picker("Aktion", selection: $action) { ForEach(permittedActions) { Text($0.label).tag($0) } }
                    if action == .mute || action == .voiceban { Stepper("Dauer: \(minutes) Minuten", value: $minutes, in: 1...1440) }
                    if action == .voiceban { TextField("Grund", text: $reason, axis: .vertical).lineLimit(2...5) }
                    if action == .move, let snapshot {
                        Picker("Zielkanal", selection: $destination) {
                            Text("Kanal auswählen").tag("")
                            ForEach(snapshot.channels.filter { $0.kind == "voice" && $0.id != call.channelID }) { Text($0.name).tag($0.id) }
                        }
                    }
                    Button("Moderationsaktion ausführen", role: .destructive) { confirmation = true }
                        .disabled(busy || !permittedActions.contains(action) || (action == .move && destination.isEmpty))
                }
            }
            Section {
                if reportSent { Label("Meldung gesendet", systemImage: "checkmark.circle") }
                else {
                    Picker("Grund der Meldung", selection: $reportReason) { ForEach(NativeReportReason.allCases) { Text($0.label).tag($0) } }
                    TextField("Was ist passiert?", text: $reportDetails, axis: .vertical).lineLimit(3...8)
                    Button("Teilnehmer in diesem Anruf melden") { report() }.disabled(busy || reportDetails.utf16.count > 2000)
                }
            } header: { Text("Melden") } footer: { Text("Sendet eine Sprachmeldung an Yapper. Es wird kein Audioclip aufgenommen oder angehängt.") }
            if let errorMessage { Section { NativeErrorBanner(message: errorMessage) } }
            if busy { Section { ProgressView() } }
        }
        .navigationTitle("Teilnehmer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedConversation) { conversation in NativeConversationView(store: store, conversation: conversation) }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        .onAppear { if let first = permittedActions.first { action = first } }
        .confirmationDialog(action.label + "?", isPresented: $confirmation, titleVisibility: .visible) {
            Button("Für " + person.name + " ausführen", role: .destructive) { moderate() }
            Button("Abbrechen", role: .cancel) { }
        }
    }

    private func moderate() {
        guard !busy, let snapshot, let channelID = call.channelID else { return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await store.withAuthenticatedSession { api, session in
                    try await NativeVoiceService(api: api).moderate(action, channelID: channelID, userID: person.id, snapshot: snapshot, minutes: minutes, destination: destination, reason: reason, session: session)
                }
                dismiss()
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }

    private func report() {
        guard !busy, let channelID = call.channelID else { return }
        busy = true; errorMessage = nil
        Task {
            defer { busy = false }
            do {
                try await store.withAuthenticatedSession { api, session in
                    try await NativeVoiceService(api: api).report(channelID: channelID, userID: person.id, reason: reportReason.rawValue, details: reportDetails, session: session)
                }
                reportSent = true
            } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct NativeAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = UIColor(YapperPalette.accent)
        view.accessibilityLabel = "Audiogerät wählen"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
}
