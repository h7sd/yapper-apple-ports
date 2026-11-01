import SwiftUI
import AVKit

struct NativeMessageEditSheet: View {
    let store: NativeStore
    let message: ChatMessage
    let didSave: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var error: String?

    init(store: NativeStore, message: ChatMessage, didSave: @escaping @MainActor () async -> Void) {
        self.store = store; self.message = message; self.didSave = didSave
        _text = State(initialValue: message.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nachricht") {
                    TextEditor(text: $text).frame(minHeight: 160).accessibilityIdentifier("native.message.edit.text")
                    Text("\(text.utf16.count) / \(store.messageCharacterLimit.formatted())").font(OriginalYapper.font(12)).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(YapperPalette.danger) } }
            }
            .navigationTitle("Nachricht bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        isSaving = true; error = nil
                        Task {
                            do {
                                _ = try await store.withAuthenticatedSession { api, session in
                                    try await api.editMessage(message, text: NativePluginPreferences.transform(text: text), session: session, messagePolicy: store.messagePolicy)
                                    return true
                                }
                                await didSave(); dismiss()
                            } catch is CancellationError {} catch { self.error = error.localizedDescription }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || text.utf16.count > store.messageCharacterLimit || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty))
                    .accessibilityIdentifier("native.message.edit.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .yapperNavigation()
        }
    }
}

struct NativeReactionPicker: View {
    let select: @MainActor (String) -> Void
    var store: NativeStore? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""
    @State private var showingCustom = false
    private let common = ["👍", "❤️", "😂", "🎉", "😮", "😢", "🔥", "✅", "👀", "🙏", "💯", "🤔"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                    ForEach(common, id: \.self) { value in
                        Button(value) { select(value); dismiss() }.font(OriginalYapper.font(32)).frame(minWidth: 52, minHeight: 52)
                            .accessibilityLabel("Mit \(value) reagieren")
                    }
                }
                TextField("Anderes Emoji", text: $emoji).textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { chooseCustom() }
                Button("Reagieren") { chooseCustom() }.buttonStyle(.borderedProminent)
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || emoji.utf8.count > 160)
                if store != nil { Button("Eigene Emojis auswählen") { showingCustom = true }.frame(minHeight: 44) }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle("Reaktion hinzufügen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .sheet(isPresented: $showingCustom) {
                if let store { NativeMessageEmojiPicker(store: store) { token in select(token); showingCustom = false; dismiss() } }
            }
            .yapperNavigation()
        }
        .presentationDetents([.medium, .large])
    }

    private func chooseCustom() {
        let value = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 160 else { return }
        select(value); dismiss()
    }
}

struct NativeMessageBrowser: View {
    enum Mode { case search, pins }
    let store: NativeStore
    let conversation: Conversation
    let mode: Mode
    var canManagePins: @MainActor () -> Bool = { true }
    var openMessage: (@MainActor (ChatMessage) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var media = ""
    @State private var mineOnly = false
    @State private var pinnedOnly = false
    @State private var results: [NativeMessageResult] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var hasSearched = false
    @State private var requestID = UUID()
    @State private var scope = 0
    @State private var authorID = ""
    @State private var mentionID = ""
    @State private var useSince = false
    @State private var useBefore = false
    @State private var since = Date()
    @State private var before = Date()

    var body: some View {
        NavigationStack {
            List {
                if mode == .search {
                    Section {
                        TextField("In \(conversation.title) suchen", text: $query)
                            .submitLabel(.search).onSubmit { Task { await load() } }
                            .accessibilityIdentifier("native.message.search.query")
                        Picker("Suchbereich", selection: $scope) {
                            Text("Dieses Gespräch").tag(0)
                            if conversation.serverID != nil { Text("Dieser Server").tag(1) }
                            Text("Alle Unterhaltungen").tag(2)
                        }
                        Picker("Enthält", selection: $media) {
                            Text("Alles").tag(""); Text("Link").tag("link"); Text("Bild").tag("image")
                            Text("Video").tag("video"); Text("Datei").tag("file"); Text("Audio").tag("sound"); Text("Linkvorschau").tag("embed"); Text("Umfrage").tag("poll")
                        }
                        Toggle("Nur meine Nachrichten", isOn: $mineOnly)
                        Picker("Von", selection: $authorID) {
                            Text("Allen").tag("")
                            if let own = store.user { Text("Mir").tag(own.id) }
                            ForEach(conversation.participants.filter { $0.id != store.user?.id }) { Text($0.displayName).tag($0.id) }
                        }.disabled(mineOnly)
                        Picker("Erwähnt", selection: $mentionID) {
                            Text("Egal").tag("")
                            if let own = store.user { Text("Mich").tag(own.id) }
                            ForEach(conversation.participants.filter { $0.id != store.user?.id }) { Text($0.displayName).tag($0.id) }
                        }
                        Toggle("Ab Datum", isOn: $useSince)
                        if useSince { DatePicker("Ab", selection: $since, displayedComponents: .date) }
                        Toggle("Bis einschließlich", isOn: $useBefore)
                        if useBefore { DatePicker("Bis", selection: $before, displayedComponents: .date) }
                        Toggle("Nur angeheftete Nachrichten", isOn: $pinnedOnly)
                        Button("Suchen") { Task { await load() } }.disabled(isLoading)
                            .accessibilityIdentifier("native.message.search.submit")
                    }
                }
                if isLoading { ProgressView("Nachrichten werden geladen …").frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                if let error { Section { Text(error).foregroundStyle(YapperPalette.danger); Button("Erneut versuchen") { Task { await load() } } } }
                ForEach(results) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        NativeMessageRow(message: item.message, isOwn: item.message.author.id == store.user?.id,
                                         detail: item.detail, reply: nil, reactions: [], react: { _ in }, store: store)
                        if item.message.channelID == conversation.id, let openMessage {
                            Button { openMessage(item.message); dismiss() } label: { Label("Im Gespräch anzeigen", systemImage: "arrow.turn.down.right") }.frame(minHeight: 44)
                        } else if mode == .search {
                            NavigationLink { NativeMessageSearchDestination(store: store, message: item.message) } label: { Label("Gespräch öffnen", systemImage: "arrow.turn.down.right") }.frame(minHeight: 44)
                        }
                    }
                        .padding(.vertical, 8)
                        .listRowBackground(YapperPalette.sidebar)
                        .contextMenu {
                            Button { UIPasteboard.general.string = item.message.content } label: { Label("Text kopieren", systemImage: "doc.on.doc") }
                            if mode == .pins {
                                Button {
                                    Task { await unpin(item) }
                                } label: { Label("Lösen", systemImage: "pin.slash") }.disabled(!canManagePins())
                            }
                        }
                }
                if hasSearched && !isLoading && results.isEmpty && error == nil {
                    ContentUnavailableView(mode == .pins ? "Keine angehefteten Nachrichten" : "Keine Nachrichten gefunden", systemImage: mode == .pins ? "pin" : "magnifyingglass", description: Text(mode == .pins ? "Angeheftete Nachrichten erscheinen hier." : "Versuche einen anderen Suchbegriff oder Filter."))
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle(mode == .pins ? "Angeheftete Nachrichten" : "Nachrichten suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { if mode == .pins { await load() } }
            .onDisappear { requestID = UUID() }
            .yapperNavigation()
        }
    }

    private func load() async {
        guard !isLoading else { return }
        let id = UUID(); requestID = id; isLoading = true; error = nil
        defer { if requestID == id { isLoading = false } }
        let calendar = Calendar.current
        let after = useSince ? calendar.startOfDay(for: since).ISO8601Format() : nil
        let until = useBefore ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: before))?.ISO8601Format() : nil
        let search = NativeMessageSearch(query: query, author: mineOnly ? store.user?.id : authorID.isEmpty ? nil : authorID, before: until, since: after, has: media.isEmpty ? nil : media, pinned: pinnedOnly, mention: mentionID.isEmpty ? nil : mentionID)
        do {
            let rows = try await store.withAuthenticatedSession { api, session in
                if mode == .pins { return try await api.pinnedMessages(channelID: conversation.id, session: session) }
                return try await api.searchMessages(search, channelID: scope == 0 ? conversation.id : nil, serverID: scope == 1 ? conversation.serverID : nil, session: session)
            }
            guard requestID == id, !Task.isCancelled else { return }
            results = rows; hasSearched = true
        } catch is CancellationError {} catch {
            if requestID == id { self.error = error.localizedDescription; hasSearched = true }
        }
    }

    private func unpin(_ item: NativeMessageResult) async {
        guard canManagePins() else { return }
        let id = requestID
        do {
            _ = try await store.withAuthenticatedSession { api, session in
                try await api.pinMessage(id: item.id, pinned: false, session: session); return true
            }
            guard requestID == id else { return }
            results.removeAll { $0.id == item.id }
        } catch is CancellationError {} catch { if requestID == id { self.error = error.localizedDescription } }
    }
}

struct NativeMentionPicker: View {
    let users: [YapperUser]
    let select: @MainActor (YapperUser) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(users.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query) }) { user in
                    Button { select(user); dismiss() } label: {
                        HStack(spacing: 12) {
                            NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: 36)
                            VStack(alignment: .leading) { Text(user.displayName).font(OriginalYapper.font(15, weight: .semibold)); Text("@\(user.username)").font(OriginalYapper.font(12)).foregroundStyle(.secondary) }
                        }.padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $query, prompt: "Name suchen")
            .navigationTitle("Person erwähnen").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .yapperNavigation()
        }
    }
}

struct NativeAttachmentPreview: View {
    let attachment: MessageAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    @State private var player: AVPlayer?
    @AppStorage("native.plugin.imageZoom") private var enableZoom = true
    @AppStorage("native.plugin.pictureInPicture") private var enablePictureInPicture = true

    var body: some View {
        NavigationStack {
            Group {
                if let url = attachment.url {
                    if NativeMessageMedia.isImage(attachment) {
                        ScrollView([.horizontal, .vertical]) {
                            NativeRemoteImage(url: url, maximumPixelSize: 2048)
                            .scaleEffect(enableZoom ? min(5, max(1, scale * magnification)) : 1)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .gesture(MagnifyGesture().updating($magnification) { value, state, _ in state = value.magnification }.onEnded { value in scale = min(5, max(1, scale * value.magnification)) }, including: enableZoom ? .all : .none)
                        }
                    } else if NativeMessageMedia.isPlayable(attachment) {
                        NativeMediaPlayerView(player: player, allowsPictureInPicture: enablePictureInPicture).task { player = AVPlayer(url: url) }
                    } else {
                        VStack(spacing: 24) {
                            Image(systemName: "doc").font(.system(size: 56)).foregroundStyle(YapperPalette.accent)
                            Text(attachment.filename).font(OriginalYapper.font(16, weight: .semibold)).multilineTextAlignment(.center)
                            ShareLink(item: url) { Label("Datei teilen oder sichern", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
                        }.padding(24)
                    }
                } else { ContentUnavailableView("Anhang nicht verfügbar", systemImage: "doc.badge.ellipsis") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle(attachment.filename).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                if let url = attachment.url { ToolbarItem(placement: .topBarLeading) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } } }
            }
            .yapperNavigation()
        }
    }
}

private struct NativeMediaPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?
    let allowsPictureInPicture: Bool
    @Environment(NativeCallController.self) private var call

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.allowsPictureInPicturePlayback = allowsPictureInPicture
        controller.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture
        if player != nil, !context.coordinator.configuredPlayback, call.channelID == nil {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            context.coordinator.configuredPlayback = true
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detached = true
        if !coordinator.pictureInPicture {
            controller.player?.pause(); controller.player = nil
        }
    }

    @MainActor final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var pictureInPicture = false
        var detached = false
        var configuredPlayback = false
        let id = UUID()

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pictureInPicture = true
            NativePictureInPictureRetention.players[id] = (playerViewController, self)
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            pictureInPicture = false
            if detached { playerViewController.player?.pause(); playerViewController.player = nil }
            NativePictureInPictureRetention.players.removeValue(forKey: id)
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(!detached && playerViewController.view.window != nil)
        }
    }
}

@MainActor private enum NativePictureInPictureRetention {
    static var players: [UUID: (AVPlayerViewController, NativeMediaPlayerView.Coordinator)] = [:]
}

@MainActor enum NativeMediaPlayback {
    static func stopAll() {
        let controllers = NativePictureInPictureRetention.players.values.map(\.0)
        NativePictureInPictureRetention.players.removeAll()
        for controller in controllers { controller.player?.pause(); controller.player = nil }
    }
}
