import SwiftUI

struct NativeSuggestionsView: View {
    let store: NativeStore
    @State private var suggestions: [NativeSuggestion] = []
    @State private var channels: [NativeServerChannel] = []
    @State private var votes: [String: NativeSuggestionVotes] = [:]
    @State private var reactions: [NativeReaction] = []
    @State private var selectedChannel: NativeServerChannel?
    @State private var openedChannel: NativeServerChannel?
    @State private var loading = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            Section {
                if let channel = channels.first {
                    Button("Vorschlag einreichen", systemImage: "lightbulb") { selectedChannel = channel }.frame(minHeight: 44)
                    Button("Vorschlagskanal öffnen", systemImage: "number") { openedChannel = channel }.frame(minHeight: 44)
                } else if !loading {
                    Text("Vorschläge werden im offiziellen Yapper-Server eingereicht. Sobald du dort Zugriff auf den Vorschlagskanal hast, kannst du hier einen Vorschlag erstellen.").foregroundStyle(YapperPalette.secondary)
                }
            } footer: { Text("Die Stimmen sind Reaktionen auf den veröffentlichten Beitrag. Weitere Vorschläge und Gespräche findest du im Vorschlagskanal.") }
            if loading && suggestions.isEmpty { ProgressView("Deine Vorschläge werden geladen …") }
            else if suggestions.isEmpty && error == nil { ContentUnavailableView("Noch keine Vorschläge", systemImage: "lightbulb", description: Text("Hier siehst du den Status deiner letzten 20 Vorschläge.")) }
            ForEach(suggestions) { suggestion in
                Section {
                    Text(verbatim: suggestion.title).font(OriginalYapper.font(16, weight: .semibold))
                    HStack { Text(suggestion.statusLabel); Spacer(); Text(suggestion.area.label) }.font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                    Text(verbatim: suggestion.body).textSelection(.enabled)
                    if let note = suggestion.staffNote, !note.isEmpty { VStack(alignment: .leading, spacing: 4) { Text("Antwort des Teams").font(OriginalYapper.font(14, weight: .bold)); Text(verbatim: note) } }
                    if let date = suggestion.createdAt { Text(date, format: .dateTime.day().month().year()).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                    if let mid = suggestion.messageID {
                        HStack(spacing: 16) {
                            voteButton(suggestion, emoji: "👍", count: votes[mid]?.up ?? 0)
                            voteButton(suggestion, emoji: "👎", count: votes[mid]?.down ?? 0)
                        }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("Meine Vorschläge")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selectedChannel) { channel in NavigationStack { NativeSuggestionFormView(store: store, channel: channel) { Task { await load() } } } }
        .sheet(item: $openedChannel) { channel in NavigationStack { NativeConversationView(store: store, conversation: channel.conversation).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { openedChannel = nil } } } } }
        .yapperNavigation()
    }

    private func voteButton(_ suggestion: NativeSuggestion, emoji: String, count: Int) -> some View {
        let selected = reactions.contains { $0.messageID == suggestion.messageID && $0.emoji == emoji }
        return Button { Task { await vote(suggestion, emoji: emoji) } } label: { Text("\(emoji) \(count.formatted())").frame(minHeight: 36) }
            .tint(selected ? YapperPalette.accent : YapperPalette.secondary)
            .accessibilityLabel((emoji == "👍" ? "Zustimmen" : "Ablehnen") + ", \(count) Stimmen")
            .accessibilityValue(selected ? "Ausgewählt" : "Nicht ausgewählt")
            .disabled(busy)
    }

    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { suggestions = []; channels = []; votes = [:]; reactions = []; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in
                let mine = try await api.nativeMySuggestions(session: session)
                let ids = mine.compactMap(\.messageID)
                let votes = try await api.nativeSuggestionVotes(messageIDs: ids, session: session)
                let reactions = try await api.nativeSuggestionOwnReactions(messageIDs: ids, session: session)
                let channels: [NativeServerChannel]
                do { channels = try await api.nativeSuggestionChannels(session: session) }
                catch NativeClientError.api(let status, _) where status == 403 || status == 404 { channels = [] }
                return (mine, votes, reactions, channels)
            }
            suggestions = result.0; votes = result.1; reactions = result.2; channels = result.3
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func vote(_ suggestion: NativeSuggestion, emoji: String) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.nativeVoteSuggestion(suggestion, emoji: emoji, session: session) }
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeSuggestionFormView: View {
    let store: NativeStore
    let channel: NativeServerChannel
    let onSubmitted: @MainActor () -> Void
    @State private var title: String
    @State private var details: String
    @State private var area: NativeSuggestionArea?
    @State private var busy = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var draftKey: String { "suggest:\(store.user?.id ?? ""):\(channel.id):" }

    init(store: NativeStore, channel: NativeServerChannel, onSubmitted: @escaping @MainActor () -> Void) {
        self.store = store; self.channel = channel; self.onSubmitted = onSubmitted
        let key = "suggest:\(store.user?.id ?? ""):\(channel.id):"
        _title = State(initialValue: store.drafts[key + "title"] ?? "")
        _details = State(initialValue: store.drafts[key + "body"] ?? "")
    }
    var body: some View {
        Form {
            Section("Vorschlag") {
                TextField("Kurzer Titel", text: $title)
                Picker("Bereich", selection: $area) { Text("Bitte wählen").tag(Optional<NativeSuggestionArea>.none); ForEach(NativeSuggestionArea.allCases) { Text($0.label).tag(Optional($0)) } }
                TextField("Was soll sich ändern und warum würde es helfen?", text: $details, axis: .vertical).lineLimit(5...12)
                Text("Titel: \(title.utf16.count)/100 · Details: \(details.utf16.count)/1500").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
            }
            Text("Wird im offiziellen Vorschlagskanal veröffentlicht, damit andere darauf reagieren können. Bis zu drei Vorschläge pro Tag; der Server prüft das Limit.").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
            if let error { NativeErrorBanner(message: error) }
        }
        .navigationTitle("Vorschlag einreichen")
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(busy) }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Wird gesendet …" : "Veröffentlichen") { Task { await submit() } }
                    .disabled(busy || area == nil || !(5...100).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count) || !(10...1500).contains(details.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count))
            }
        }
        .onChange(of: title) { _, value in store.setDraft(value, for: draftKey + "title") }
        .onChange(of: details) { _, value in store.setDraft(value, for: draftKey + "body") }
        .interactiveDismissDisabled(busy)
        .yapperNavigation()
    }
    private func submit() async {
        guard !busy, let area else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.nativeSubmitSuggestion(channel: channel, title: title, area: area, body: details, session: session) }
            store.setDraft("", for: draftKey + "title"); store.setDraft("", for: draftKey + "body")
            onSubmitted(); dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
