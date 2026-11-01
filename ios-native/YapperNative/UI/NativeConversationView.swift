import SwiftUI
import UniformTypeIdentifiers

struct NativeConversationView: View {
    let store: NativeStore
    private let seedConversation: Conversation
    private let conversationOwnerID: String?
    var initialMessageID: String? = nil
    var onBack: (() -> Void)? = nil
    var compactPresentation = true
    var serverSnapshot: NativeServerSnapshot? = nil
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var showingDetails = false
    @State private var sendFailed = false
    @State private var features = NativeMessageFeatures()
    @State private var replyTo: ChatMessage?
    @State private var editingMessage: ChatMessage?
    @State private var deletingMessage: ChatMessage?
    @State private var reactingMessage: ChatMessage?
    @State private var translatingMessage: ChatMessage?
    @State private var reportingMessage: ChatMessage?
    @State private var showingSearch = false
    @State private var showingPins = false
    @State private var showingFileImporter = false
    @State private var showingGalleryPicker = false
    @State private var showingVoiceRecorder = false
    @State private var showingPollCreator = false
    @State private var showingMentions = false
    @State private var showingEmojis = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var attachment: NativePendingAttachment?
    @State private var isSendingExtra = false
    @State private var sendAttempt: NativeMessageSendAttempt?
    @State private var pendingDetailsConversation: Conversation?
    @State private var nextConversation: Conversation?
    @State private var pendingJumpMessage: ChatMessage?
    @State private var jumpMessageID: String?
    @State private var viewingHistory = false
    @State private var loadedServerSnapshot: NativeServerSnapshot?
    @State private var serverPermissionError: String?
    @State private var serverMembersModel: NativeServerDetailModel?
    @State private var showingServerMembers = false
    @State private var isConversationVisible = false
    @AppStorage("native.plugin.characterCounter") private var showCharacterCounter = true

    init(store: NativeStore, conversation: Conversation, initialMessageID: String? = nil, onBack: (() -> Void)? = nil, compactPresentation: Bool = true, serverSnapshot: NativeServerSnapshot? = nil) {
        self.store = store; self.seedConversation = conversation; self.initialMessageID = initialMessageID
        self.conversationOwnerID = store.user?.id
        self.onBack = onBack; self.compactPresentation = compactPresentation
        self.serverSnapshot = serverSnapshot
    }

    private var conversation: Conversation { store.conversations.first(where: { $0.id == seedConversation.id }) ?? seedConversation }
    private var activeServerSnapshot: NativeServerSnapshot? {
        if let loadedServerSnapshot, loadedServerSnapshot.server.id == conversation.serverID { return loadedServerSnapshot }
        return serverSnapshot?.server.id == conversation.serverID ? serverSnapshot : nil
    }
    private var postingAccess: NativeChannelPostingAccess {
        guard conversation.serverID != nil else { return .allowed }
        if let serverPermissionError { return .denied(serverPermissionError) }
        return activeServerSnapshot?.postingAccess(channelID: conversation.id, userID: store.user?.id, capabilities: store.capabilities)
            ?? .denied(serverPermissionError ?? "Die Kanalberechtigungen werden geladen …")
    }
    private func channelPermission(_ permission: String) -> Bool {
        conversation.serverID == nil || activeServerSnapshot?.hasChannelPermission(permission, channelID: conversation.id, userID: store.user?.id, capabilities: store.capabilities) == true
    }
    private var canManagePins: Bool {
        store.capabilities.flagOn("pins", userID: store.user?.id, serverID: conversation.serverID)
            && activeServerSnapshot?.channels.first(where: { $0.id == conversation.id })?.kind != "voice"
            && channelPermission("manage_messages")
    }

    private var draft: Binding<String> {
        Binding(
            get: { store.drafts[conversation.id] ?? "" },
            set: { store.setDraft($0, for: conversation.id) }
        )
    }

    private var visibleMessages: [ChatMessage] {
        store.messages.filter { $0.channelID == conversation.id }
    }

    private var draftLength: Int {
        (store.drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
    }

    private var messageLimit: Int { store.messageCharacterLimit }

    private var canSend: Bool {
        postingAccess.canSend
            && (!(store.drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachment != nil)
            && draftLength <= messageLimit
            && !store.isSending
            && !isSendingExtra
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if viewingHistory {
                        Button {
                            Task {
                                await store.loadMessages(for: conversation)
                                if store.errorMessage == nil {
                                    viewingHistory = false; jumpMessageID = nil
                                    proxy.scrollTo("native.messages.bottom", anchor: .bottom)
                                    if scenePhase == .active { await store.markConversationRead(conversation) }
                                }
                            }
                        } label: { Label("Zu den neuesten Nachrichten", systemImage: "arrow.down.to.line").frame(maxWidth: .infinity, minHeight: 44) }
                    }
                    if store.hasMoreMessages && !visibleMessages.isEmpty {
                        Button {
                            Task { await store.loadOlderMessages(in: conversation) }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoading { ProgressView() }
                                Text("Ältere Nachrichten laden")
                            }
                            .font(OriginalYapper.font(14, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(store.isLoading)
                        .accessibilityIdentifier("native.messages.loadOlder")
                    }
                    if store.isLoading && visibleMessages.isEmpty {
                        ProgressView("Nachrichten werden geladen …")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 64)
                    } else if visibleMessages.isEmpty { conversationStart }
                    if !store.isLoading && !visibleMessages.isEmpty && !store.hasMoreMessages && !viewingHistory { conversationStart }
                    ForEach(Array(visibleMessages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(message.createdAt, inSameDayAs: visibleMessages[index - 1].createdAt) {
                            HStack(spacing: 8) {
                                Rectangle().fill(YapperPalette.border).frame(height: 1)
                                Text(message.createdAt, format: .dateTime.weekday(.wide).day().month(.wide).year())
                                    .font(OriginalYapper.font(12, weight: .semibold)).foregroundStyle(YapperPalette.faint).fixedSize()
                                Rectangle().fill(YapperPalette.border).frame(height: 1)
                            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
                        }
                        NativeMessageRow(message: message, isOwn: message.author.id == store.user?.id,
                                         detail: features.details[message.id],
                                         reply: features.details[message.id]?.replyToID.flatMap { features.replies[$0] },
                                         reactions: NativeReactionGroup.groups(features.reactions[message.id] ?? [], currentUserID: store.user?.id),
                                         react: { emoji in react(to: message, emoji: emoji) }, store: store, emojis: features.emojis, grouped: NativeMessageGrouping.groups(message, after: index > 0 ? visibleMessages[index - 1] : nil) && features.details[message.id]?.replyToID == nil,
                                         serverSnapshot: activeServerSnapshot, onMentionDismiss: restoreConversationAfterMention)
                            .id(message.id)
                            .accessibilityIdentifier("native.message.\(message.id)")
                            .contextMenu {
                                Button { replyTo = message; composerFocused = true } label: { Label("Antworten", systemImage: "arrowshape.turn.up.left") }.disabled(!postingAccess.canSend)
                                Button { reactingMessage = message } label: { Label("Reaktion hinzufügen", systemImage: "face.smiling") }.disabled(!channelPermission("add_reactions"))
                                Button { UIPasteboard.general.string = message.content } label: { Label("Text kopieren", systemImage: "doc.on.doc") }
                                if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button { translatingMessage = message } label: { Label("Übersetzen", systemImage: "translate") }
                                }
                                Button { pin(message) } label: { Label(features.details[message.id]?.pinnedAt == nil ? "Anheften" : "Lösen", systemImage: features.details[message.id]?.pinnedAt == nil ? "pin" : "pin.slash") }.disabled(!canManagePins)
                                if message.author.id == store.user?.id {
                                    Button { editingMessage = message } label: { Label("Bearbeiten", systemImage: "pencil") }
                                    Button(role: .destructive) { deletingMessage = message } label: { Label("Löschen", systemImage: "trash") }
                                } else {
                                    Button { reportingMessage = message } label: { Label("Melden", systemImage: "flag") }
                                }
                            }
                    }
                    Color.clear.frame(height: 1).id("native.messages.bottom")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(YapperPalette.background.ignoresSafeArea())
            .refreshable { await store.loadMessages(for: conversation); await loadServerContext(refresh: true) }
            .onChange(of: visibleMessages.last?.id) { _, _ in
                if pendingJumpMessage == nil && !viewingHistory { proxy.scrollTo("native.messages.bottom", anchor: .bottom) }
                if scenePhase == .active && pendingJumpMessage == nil && !viewingHistory { Task { await store.markConversationRead(conversation) } }
            }
            .onChange(of: jumpMessageID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
            .safeAreaInset(edge: .top, spacing: 0) { conversationHeader }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let error = store.errorMessage {
                        NativeErrorBanner(message: error) {
                            if sendFailed {
                                sendDraft()
                            } else {
                                Task { await store.loadMessages(for: conversation) }
                            }
                        }
                    }
                    if let error = features.errorMessage {
                        NativeErrorBanner(message: error)
                    }
                    if let typing = store.typingUsers[conversation.id], !typing.isEmpty {
                        let names = typing.prefix(3).map(\.displayName).joined(separator: ", ")
                        Text(typing.count == 1 ? "\(names) schreibt …" : "\(names) schreiben …")
                            .font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("native.conversation.typing")
                    }
                    if let replyTo {
                        HStack(spacing: 10) {
                            Image(systemName: "arrowshape.turn.up.left").foregroundStyle(YapperPalette.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Antwort an \(replyTo.author.displayName)").font(OriginalYapper.font(12, weight: .semibold))
                                Text(replyTo.content.isEmpty ? "Anhang" : replyTo.content).font(OriginalYapper.font(12)).lineLimit(1).foregroundStyle(YapperPalette.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { self.replyTo = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Antwort abbrechen")
                        }
                        .accessibilityIdentifier("native.composer.reply")
                    }
                    if let attachment {
                        HStack(spacing: 10) {
                            Image(systemName: "paperclip").foregroundStyle(YapperPalette.accent)
                            Text(attachment.filename).font(OriginalYapper.font(12)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                            Button { self.attachment = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(.rect) }
                                .accessibilityLabel("Anhang entfernen").accessibilityIdentifier("native.composer.attachment.remove")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("native.composer.attachment")
                    }
                    if postingAccess.canSend { composer }
                    else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(postingAccess.reason ?? "Dieser Kanal ist schreibgeschützt.", systemImage: "lock.fill")
                                .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if serverPermissionError != nil {
                                Button("Berechtigungen erneut laden") { Task { await loadServerContext(refresh: true) } }.frame(minHeight: 44)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .accessibilityIdentifier("native.composer.readOnly")
                    }
                    if showCharacterCounter && draftLength >= messageLimit - 300 {
                        Text(draftLength > messageLimit
                            ? "\(draftLength - messageLimit) Zeichen zu viel · maximal \(messageLimit.formatted())"
                            : "Noch \(messageLimit - draftLength) Zeichen")
                            .font(OriginalYapper.font(12))
                            .foregroundStyle(draftLength > messageLimit ? YapperPalette.danger : YapperPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 8)
                            .accessibilityIdentifier("native.composer.remaining")
                    }
                }
                .padding(.horizontal, compactPresentation ? 8 : 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(YapperPalette.background)
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingDetails, onDismiss: {
                if let target = pendingDetailsConversation, target.id != conversation.id { nextConversation = target }
                else { Task { await store.loadMessages(for: conversation) } }
                pendingDetailsConversation = nil
            }) {
                NativeConversationDetails(store: store, conversation: conversation) { target in
                    pendingDetailsConversation = target; showingDetails = false
                }
            }
            .sheet(isPresented: $showingServerMembers) {
                if let serverMembersModel { NativeServerMembersView(model: serverMembersModel) }
            }
            .navigationDestination(item: $nextConversation) { target in NativeConversationView(store: store, conversation: target) }
            .sheet(isPresented: $showingSearch, onDismiss: jumpToPendingMessage) {
                NativeMessageBrowser(store: store, conversation: conversation, mode: .search, canManagePins: { canManagePins }, openMessage: { pendingJumpMessage = $0; showingSearch = false })
            }
            .sheet(isPresented: $showingPins, onDismiss: jumpToPendingMessage) {
                NativeMessageBrowser(store: store, conversation: conversation, mode: .pins, canManagePins: { canManagePins }, openMessage: { pendingJumpMessage = $0; showingPins = false })
            }
            .sheet(isPresented: $showingPollCreator) { NativePollCreator(store: store, conversation: conversation, canCreate: { postingAccess.canSend && channelPermission("create_polls") }) { await store.loadMessages(for: conversation) } }
            .sheet(isPresented: $showingMentions) {
                NativeMentionPicker(users: activeServerSnapshot?.members.map(\.user) ?? conversation.participants) { user in
                    let current = store.drafts[conversation.id] ?? ""
                    store.setDraft(current + (current.isEmpty || current.hasSuffix(" ") ? "" : " ") + "<@\(user.id)> ", for: conversation.id)
                    composerFocused = true
                }
            }
            .sheet(isPresented: $showingEmojis) {
                NativeMessageEmojiPicker(store: store) { token in
                    let current = store.drafts[conversation.id] ?? ""
                    store.setDraft(current + (current.isEmpty || current.hasSuffix(" ") ? "" : " ") + token + " ", for: conversation.id)
                    composerFocused = true
                }
            }
            .sheet(isPresented: $showingVoiceRecorder) {
                NativeVoiceRecorderSheet { voice in
                    attachment = NativePendingAttachment(id: UUID(), data: voice.data, filename: voice.filename, contentType: "audio/mp4", voiceSeconds: voice.duration, waveform: voice.waveform)
                }
            }
            .sheet(item: $editingMessage) { message in NativeMessageEditSheet(store: store, message: message) { await store.loadMessages(for: conversation); await reloadFeatures() } }
            .sheet(item: $reactingMessage) { message in NativeReactionPicker(select: { emoji in react(to: message, emoji: emoji) }, store: store) }
            .sheet(item: $translatingMessage) { message in NavigationStack { NativeMessageTranslationView(store: store, text: message.content) } }
            .sheet(item: $reportingMessage) { message in NavigationStack { NativeReportComposer(store: store, target: .message(message.id)) } }
            .alert("Nachricht löschen?", isPresented: Binding(get: { deletingMessage != nil }, set: { if !$0 { deletingMessage = nil } })) {
                Button("Abbrechen", role: .cancel) { deletingMessage = nil }
                Button("Löschen", role: .destructive) { if let message = deletingMessage { delete(message) }; deletingMessage = nil }
            } message: { Text("Diese Nachricht wird für alle Teilnehmenden entfernt.") }
            .sheet(isPresented: $showingGalleryPicker) {
                NativeGalleryPicker(onImport: { selected in
                    features.errorMessage = nil
                    attachment = NativePendingAttachment(id: UUID(), data: selected.data, filename: selected.filename, contentType: selected.contentType)
                }, onFailure: { error in
                    features.errorMessage = error.localizedDescription
                })
            }
            .fileImporter(isPresented: $showingFileImporter,
                          allowedContentTypes: [.png, .jpeg, .gif, .webP, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio, .pdf, .zip, .plainText],
                          allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let resource = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    guard let size = resource.fileSize, size > 0, size <= 10 * 1024 * 1024 else { throw NativeClientError.api(status: 413, message: "Anhänge dürfen in dieser Vorschau höchstens 10 MB groß sein.") }
                    let type = resource.contentType?.preferredMIMEType ?? NativeMessageMedia.contentType(path: url.path) ?? "application/octet-stream"
                    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                    try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: bytes.count, contentType: type)
                    attachment = NativePendingAttachment(id: UUID(), data: bytes, filename: url.lastPathComponent, contentType: type)
                } catch let error as CocoaError where error.code == .userCancelled {} catch { features.errorMessage = error.localizedDescription }
            }
            .task(id: conversation.id) {
                if initialMessageID != nil { viewingHistory = true }
                await store.loadMessages(for: conversation)
                if let initialMessageID, await store.focusMessage(id: initialMessageID, in: conversation) { jumpMessageID = initialMessageID }
                else if initialMessageID == nil && scenePhase == .active && store.errorMessage == nil { await store.markConversationRead(conversation) }
            }
            .task(id: conversation.serverID) { await loadServerContext() }
            .onChange(of: postingAccess.canSend) { _, allowed in if !allowed { composerFocused = false } }
            .task(id: visibleMessages) { await reloadFeatures() }
            .onAppear { isConversationVisible = true }
            .onDisappear { isConversationVisible = false; features.cancel(); store.closeConversation(id: conversation.id) }
            .yapperNavigation()
            .nativeServerAppearance(ownerID: store.user?.id, serverID: conversation.serverID,
                                    theme: store.capabilities.flagOn("server_theme", userID: store.user?.id, serverID: conversation.serverID) ? activeServerSnapshot?.server.theme ?? .null : .null)
            .background { NativeChatBackground().ignoresSafeArea() }
        }
    }

    private var conversationStart: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id, username: conversation.participants.first?.username, url: conversation.avatarURL, size: 72).padding(.bottom, 10)
            Text(conversation.title).font(OriginalYapper.font(22, weight: .bold)).padding(.bottom, 4)
            Text(conversation.serverID != nil ? "Hier beginnt der Kanal \(conversation.title)." : "Hier beginnt euer Gespräch mit \(conversation.title).")
                .font(OriginalYapper.font(15)).foregroundStyle(YapperPalette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    private var conversationHeader: some View {
        HStack(spacing: compactPresentation ? 2 : 10) {
            if compactPresentation {
                Button {
                    isConversationVisible = false
                    composerFocused = false
                    features.cancel()
                    store.closeConversation(id: conversation.id)
                    if let onBack { onBack() } else { dismiss() }
                } label: {
                    OriginalYapperIcon("chevronLeft", size: 22)
                        .frame(width: 48, height: 48)
                        .contentShape(.rect)
                }
                    .accessibilityLabel("Zurück").accessibilityIdentifier("native.conversation.back")
            }
            if conversation.serverID != nil {
                Image(systemName: activeServerSnapshot?.channels.first(where: { $0.id == conversation.id })?.symbol ?? "number")
                    .font(.system(size: 20)).foregroundStyle(YapperPalette.secondary)
            }
            else { NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id, username: conversation.participants.first?.username, url: conversation.avatarURL, presence: conversation.isGroup ? nil : conversation.participants.first.map { store.peerPresence(userID: $0.id) }, size: compactPresentation ? 26 : 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(OriginalYapper.font(compactPresentation ? 16 : 15, weight: compactPresentation ? .bold : .semibold)).lineLimit(1)
                if conversation.serverID == nil, !conversation.isGroup, let peer = conversation.participants.first {
                    let label = NativePresenceLabel.text(store.peerPresence(userID: peer.id))
                    if !label.isEmpty { Text(label).font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.secondary).accessibilityIdentifier("native.conversation.presence") }
                }
                if let members = store.voiceMembers[conversation.id], !members.isEmpty {
                    Text("\(members.count) im Anruf").font(OriginalYapper.font(11)).foregroundStyle(YapperPalette.success)
                        .accessibilityIdentifier("native.conversation.callMembers")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if store.capabilities.flagOn("calls", userID: store.user?.id, serverID: conversation.serverID) {
                NativeCallButton(store: store, channelID: conversation.id, title: conversation.title, serverID: conversation.serverID)
            }
            Button { showingSearch = true } label: { OriginalYapperIcon("search").frame(width: 44, height: 44) }.accessibilityLabel("Nachrichten suchen")
            Menu {
                Button { showingSearch = true } label: { Label("Nachrichten suchen", systemImage: "magnifyingglass") }
                Button { showingPins = true } label: { Label("Angeheftete Nachrichten", systemImage: "pin") }
                Button { showingDetails = true } label: { Label("Gesprächsinformationen", systemImage: "info.circle") }
                if let snapshot = activeServerSnapshot {
                    Button {
                        serverMembersModel = NativeServerDetailModel(store: store, id: snapshot.server.id, snapshot: snapshot)
                        showingServerMembers = true
                    } label: { Label("Servermitglieder", systemImage: "person.3") }
                    .accessibilityIdentifier("native.conversation.serverMembers")
                }
            } label: { OriginalYapperIcon("more").frame(width: 44, height: 44) }
                .accessibilityLabel("Gesprächsaktionen").accessibilityIdentifier("native.conversation.actions")
        }
        .foregroundStyle(YapperPalette.text).buttonStyle(.plain)
        .padding(.leading, compactPresentation ? 2 : 16).padding(.trailing, compactPresentation ? 4 : 12)
        .frame(height: compactPresentation ? 48 : 52)
        .background(YapperPalette.background)
        .overlay(alignment: .bottom) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.conversation.header")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: compactPresentation ? 0 : 4) {
            Menu {
                Button { showingGalleryPicker = true } label: { Label("Foto oder Video auswählen", systemImage: "photo.on.rectangle") }
                    .disabled(!channelPermission("attach_files"))
                    .accessibilityIdentifier("native.composer.gallery")
                Button { showingFileImporter = true } label: { Label("Datei anhängen", systemImage: "paperclip") }
                    .disabled(!channelPermission("attach_files"))
                    .accessibilityIdentifier("native.composer.file")
                if store.capabilities.flagOn("voice_messages", userID: store.user?.id, serverID: conversation.serverID) {
                    Button { showingVoiceRecorder = true } label: { Label("Sprachnachricht aufnehmen", systemImage: "mic") }.disabled(!channelPermission("send_voice_messages"))
                }
                Button { showingPollCreator = true } label: { Label("Umfrage oder Quiz", systemImage: "chart.bar.xaxis") }.disabled(!channelPermission("create_polls"))
                Button { showingEmojis = true } label: { Label("Eigene Emojis", systemImage: "face.smiling") }
                if !(activeServerSnapshot?.members ?? []).isEmpty || !conversation.participants.isEmpty { Button { showingMentions = true } label: { Label("Person erwähnen", systemImage: "at") } }
            } label: { OriginalYapperIcon("plus", size: compactPresentation ? 24 : 20).frame(width: compactPresentation ? 44 : 40, height: compactPresentation ? 44 : 40) }
                .disabled(isSendingExtra).accessibilityLabel("Nachrichtenoptionen").accessibilityIdentifier("native.composer.attach")
            TextField("Nachricht an \(conversation.isGroup || conversation.serverID != nil ? conversation.title : "@" + conversation.title)", text: draft, axis: .vertical)
                .font(OriginalYapper.font(compactPresentation ? 16 : 15)).foregroundStyle(YapperPalette.text)
                .lineLimit(1...6).padding(.vertical, compactPresentation ? 11 : 9).padding(.trailing, compactPresentation ? 6 : 0).frame(minHeight: compactPresentation ? 44 : 40)
                .focused($composerFocused)
                .accessibilityLabel("Nachricht schreiben").accessibilityIdentifier("native.composer")
                .onChange(of: store.drafts[conversation.id] ?? "") { _, text in if !text.isEmpty { store.noteTyping(in: conversation) } }
            Button { showingEmojis = true } label: { OriginalYapperIcon("emoji").frame(width: compactPresentation ? 40 : 32, height: compactPresentation ? 44 : 40) }
                .accessibilityLabel("Emojis").accessibilityIdentifier("native.composer.emoji")
            if !compactPresentation && draftLength == 0 && attachment == nil && store.capabilities.flagOn("voice_messages", userID: store.user?.id, serverID: conversation.serverID) {
                Button { showingVoiceRecorder = true } label: { OriginalYapperIcon("microphone").frame(width: compactPresentation ? 40 : 32, height: compactPresentation ? 44 : 40) }
                    .disabled(isSendingExtra || !channelPermission("send_voice_messages")).accessibilityLabel("Sprachnachricht aufnehmen").accessibilityIdentifier("native.composer.voice")
            }
            if !compactPresentation || draftLength > 0 || attachment != nil || store.isSending || isSendingExtra {
            Button { sendDraft() } label: {
                Group {
                    if store.isSending || isSendingExtra { ProgressView().tint(YapperPalette.onAccent) }
                    else { OriginalYapperIcon("send", size: 20) }
                }.frame(width: compactPresentation ? 36 : 44, height: compactPresentation ? 36 : 40)
                    .foregroundStyle(YapperPalette.onAccent)
                    .background(YapperPalette.accentFill, in: .rect(cornerRadius: compactPresentation ? 18 : 8))
                    .opacity(canSend ? 1 : 0.45)
                    .padding(.vertical, compactPresentation ? 4 : 0).padding(.leading, compactPresentation ? 2 : 0)
            }
            .disabled(!canSend)
            .accessibilityLabel(store.isSending ? "Nachricht wird gesendet" : sendFailed ? "Nachricht erneut senden" : "Nachricht senden")
            .accessibilityIdentifier("native.send")
            }
        }
        .buttonStyle(.plain).foregroundStyle(YapperPalette.secondary)
        .padding(.vertical, compactPresentation ? 0 : 6).padding(.leading, compactPresentation ? 0 : 8).padding(.trailing, compactPresentation ? 4 : 6)
        .background(YapperPalette.input, in: .rect(cornerRadius: compactPresentation ? 22 : 10))
    }

    private func sendDraft() {
        guard canSend else { return }
        if let attachment, !channelPermission(attachment.voiceSeconds == nil ? "attach_files" : "send_voice_messages") {
            features.errorMessage = "Du darfst in diesem Kanal keine solchen Anhänge senden."
            return
        }
        let rawText = store.drafts[conversation.id] ?? ""
        let transformed = NativePluginPreferences.transform(text: rawText)
        if replyTo != nil || attachment != nil {
            let attempt: NativeMessageSendAttempt
            if let previous = sendAttempt, previous.rawText == rawText, previous.replyToID == replyTo?.id, previous.attachmentID == attachment?.id { attempt = previous }
            else { attempt = NativeMessageSendAttempt(id: UUID().uuidString.lowercased(), rawText: rawText, text: transformed, replyToID: replyTo?.id, attachmentID: attachment?.id); sendAttempt = attempt }
            let text = attempt.text
            let attached = attachment
            isSendingExtra = true
            Task {
                let accepted = await features.perform(store: store, key: "send:" + attempt.id) { api, session in
                    if let attached {
                        try await api.sendAttachment(id: attempt.id, text: text, data: attached.data, filename: attached.filename, contentType: attached.contentType, channelID: conversation.id, replyToID: attempt.replyToID, session: session, voiceSeconds: attached.voiceSeconds, waveform: attached.waveform, messagePolicy: store.messagePolicy)
                    } else if let reply = attempt.replyToID {
                        try await api.sendReply(id: attempt.id, text: text, replyToID: reply, channelID: conversation.id, session: session, messagePolicy: store.messagePolicy)
                    }
                }
                if accepted {
                    if store.drafts[conversation.id] == rawText { store.setDraft("", for: conversation.id) }
                    if attachment?.id == attempt.attachmentID { attachment = nil }
                    if replyTo?.id == attempt.replyToID { replyTo = nil }
                    sendAttempt = nil
                    await store.loadMessages(for: conversation)
                }
                sendFailed = !accepted; isSendingExtra = false
            }
            return
        }
        let attempt: NativeMessageSendAttempt
        if let previous = sendAttempt, previous.rawText == rawText, previous.replyToID == nil, previous.attachmentID == nil { attempt = previous }
        else { attempt = NativeMessageSendAttempt(id: UUID().uuidString.lowercased(), rawText: rawText, text: transformed, replyToID: nil, attachmentID: nil); sendAttempt = attempt }
        Task {
            let accepted = await store.sendMessage(attempt.text, in: conversation)
            sendFailed = !accepted
            if accepted {
                if store.drafts[conversation.id] == rawText { store.setDraft("", for: conversation.id) }
                sendAttempt = nil
            }
        }
    }

    private func reloadFeatures() async {
        #if DEBUG
        if NativeServerFixtures.isEnabled(userID: store.user?.id) { return }
        #endif
        await features.load(store: store, messages: visibleMessages, channelID: conversation.id)
    }

    private func restoreConversationAfterMention() {
        guard isConversationVisible, conversationOwnerID == store.user?.id, store.authState == .signedIn,
              store.selectedConversation?.id != conversation.id else { return }
        Task {
            guard isConversationVisible, conversationOwnerID == store.user?.id else { return }
            await store.loadMessages(for: conversation)
            if viewingHistory, let target = jumpMessageID { _ = await store.focusMessage(id: target, in: conversation) }
            else if scenePhase == .active { await store.markConversationRead(conversation) }
        }
    }

    private func loadServerContext(refresh: Bool = false) async {
        guard let serverID = conversation.serverID, let ownerID = store.user?.id else { return }
        serverPermissionError = nil
        do {
            var snapshot: NativeServerSnapshot
            #if DEBUG
            if NativeServerFixtures.isEnabled(userID: ownerID), serverID == NativeServerFixtures.serverID {
                snapshot = try NativeServerFixtures.snapshot()
            } else {
                snapshot = try await fetchServerContext(serverID: serverID, refresh: refresh)
            }
            #else
            snapshot = try await fetchServerContext(serverID: serverID, refresh: refresh)
            #endif
            try Task.checkCancellation()
            guard store.user?.id == ownerID else { return }
            loadedServerSnapshot = snapshot
            store.observeServer(id: serverID, channelIDs: snapshot.channels.map(\.id), members: snapshot.members.map(\.user))
            store.registerServerRoles(serverID: serverID, ownRoleIDs: snapshot.roleIDs(for: ownerID))
        } catch is CancellationError {} catch {
            guard !Task.isCancelled, store.user?.id == ownerID else { return }
            serverPermissionError = "Die Kanalberechtigungen konnten nicht geladen werden."
        }
    }

    private func fetchServerContext(serverID: String, refresh: Bool) async throws -> NativeServerSnapshot {
        let seed = refresh ? nil : serverSnapshot
        let loadOverrides = store.capabilities.flagOn("channel_perms", userID: store.user?.id, serverID: serverID)
        return try await store.withAuthenticatedSession { api, session in
            var snapshot: NativeServerSnapshot
            if let seed, seed.server.id == serverID, !loadOverrides || seed.overridesLoaded { snapshot = seed }
            else { snapshot = try await api.nativeServerSnapshot(id: serverID, session: session, includeOverrides: loadOverrides) }
            if !snapshot.channels.contains(where: { $0.id == conversation.id }) {
                let channel = try await api.nativeServerChannel(id: conversation.id, serverID: serverID, session: session)
                if let parent = channel.parentID, !snapshot.channels.contains(where: { $0.id == parent }) {
                    snapshot = snapshot.includingChannel(try await api.nativeServerChannel(id: parent, serverID: serverID, session: session))
                }
                snapshot = snapshot.includingChannel(channel)
            }
            return snapshot
        }
    }

    private func jumpToPendingMessage() {
        guard let message = pendingJumpMessage else {
            if store.selectedConversation?.id != conversation.id { Task { await store.loadMessages(for: conversation) } }
            return
        }
        Task {
            if await store.focusMessage(id: message.id, in: conversation) { viewingHistory = true; jumpMessageID = message.id }
            pendingJumpMessage = nil
        }
    }

    private func react(to message: ChatMessage, emoji: String) {
        guard channelPermission("add_reactions") else { return }
        let existing = features.reactions[message.id] ?? []
        Task {
            let accepted = await features.perform(store: store, key: "react:" + message.id) { api, session in
                try await api.toggleReaction(messageID: message.id, emoji: emoji, existing: existing, session: session)
            }
            if accepted { await reloadFeatures() }
        }
    }

    private func pin(_ message: ChatMessage) {
        guard canManagePins else { return }
        let pinned = features.details[message.id]?.pinnedAt == nil
        Task {
            let accepted = await features.perform(store: store, key: "pin:" + message.id) { api, session in
                try await api.pinMessage(id: message.id, pinned: pinned, session: session)
            }
            if accepted { await reloadFeatures() }
        }
    }

    private func delete(_ message: ChatMessage) {
        Task {
            let accepted = await features.perform(store: store, key: "delete:" + message.id) { api, session in
                try await api.deleteMessage(message, session: session)
            }
            if accepted { await store.loadMessages(for: conversation) }
        }
    }
}

private nonisolated struct NativePendingAttachment: Identifiable, Sendable {
    let id: UUID
    let data: Data
    let filename: String
    let contentType: String
    var voiceSeconds: Double? = nil
    var waveform: [Double] = []
}

private nonisolated struct NativeMessageSendAttempt {
    let id: String
    let rawText: String
    let text: String
    let replyToID: String?
    let attachmentID: UUID?
}

struct NativeMessageRow: View {
    let message: ChatMessage
    let isOwn: Bool
    let detail: NativeMessageDetail?
    let reply: ChatMessage?
    let reactions: [NativeReactionGroup]
    let react: @MainActor (String) -> Void
    var store: NativeStore? = nil
    var emojis: [String: NativeCustomEmoji] = [:]
    var grouped = false
    var serverSnapshot: NativeServerSnapshot? = nil
    var onMentionDismiss: (() -> Void)? = nil
    @State private var selectedMention: NativeMentionTarget?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if grouped { Color.clear.frame(width: 34, height: 1).accessibilityHidden(true) }
            else { NativeAvatar(name: message.author.displayName, identity: message.author.id, username: message.author.username, url: message.author.avatarURL, presence: store?.peerPresence(userID: message.author.id), size: 34, initialsFontSize: 16, decorationURL: message.author.avatarDecorationURL) }
            VStack(alignment: .leading, spacing: 6) {
                if let reply {
                    Label {
                        Text("\(reply.author.displayName): \(reply.content.isEmpty ? "Anhang" : reply.content)").lineLimit(2)
                    } icon: { Image(systemName: "arrowshape.turn.up.left") }
                        .font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        .accessibilityLabel("Antwort auf \(reply.author.displayName): \(reply.content)")
                } else if detail?.replyToID != nil {
                    Label("Antwort auf eine nicht verfügbare Nachricht", systemImage: "arrowshape.turn.up.left").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                if !grouped {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    NativeServerRoleName(name: serverSnapshot?.members.first(where: { $0.id == message.author.id })?.displayName ?? message.author.displayName,
                                         role: serverSnapshot?.colorRole(userID: message.author.id), bannerURL: message.author.nameBannerURL)
                        .font(OriginalYapper.font(15, numericWeight: 650))
                    Text(timestamp)
                        .font(OriginalYapper.font(12))
                        .foregroundStyle(YapperPalette.faint)
                        .accessibilityLabel(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.content.hasPrefix("📊 "), let store {
                    NativePollCard(store: store, message: message)
                } else if !message.content.isEmpty {
                    if NativeEmojiTokens.matches(message.content).isEmpty && renderedMentions.isEmpty {
                        Text(.init(message.content)).font(OriginalYapper.font(15)).lineSpacing(3).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        NativeMessageRichText(text: message.content, emojis: emojis, mentions: renderedMentions, selectMention: {
                            if $0.kind == .channel && $0.targetID == message.channelID { return }
                            selectedMention = $0
                        })
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let seconds = detail?.voiceSeconds, let url = message.attachments.first?.url {
                    NativeVoiceMessagePlayer(url: url, seconds: seconds, wave: detail?.voiceWave)
                } else {
                    ForEach(message.attachments) { attachment in NativeAttachmentView(attachment: attachment) }
                }
                ForEach(Array((detail?.embeds ?? []).prefix(10).enumerated()), id: \.offset) { _, embed in NativeMessageEmbed(embed: embed) }
                if let store, let components = detail?.components, !components.isEmpty {
                    NativeMessageComponentsView(store: store, message: message, components: components)
                }
                if let seconds = detail?.voiceSeconds {
                    Label("Sprachnachricht · \(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond)))", systemImage: "waveform")
                        .font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                if message.isEdited {
                    Text("Bearbeitet").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                }
                if detail?.pinnedAt != nil { Label("Angeheftet", systemImage: "pin.fill").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                if !reactions.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { reactionButtons }
                        VStack(alignment: .leading, spacing: 6) { reactionButtons }
                    }
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 3).padding(.top, grouped ? 0 : 10)
        .background(store?.messageMentionsCurrentUser(message) == true ? YapperPalette.accentSoft : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityValue(store?.messageMentionsCurrentUser(message) == true ? "Du wurdest erwähnt" : "")
        .sheet(item: $selectedMention, onDismiss: { onMentionDismiss?() }) { target in
            if let store { NativeMentionDestination(store: store, target: target, snapshot: serverSnapshot) }
        }
    }

    private var timestamp: String {
        let time = message.createdAt.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(message.createdAt) { return time }
        if Calendar.current.isDateInYesterday(message.createdAt) { return String(localized: "Gestern um") + " " + time }
        return message.createdAt.formatted(date: .numeric, time: .shortened)
    }

    private var renderedMentions: [NativeRenderedMention] { NativeMentionRendering.mentions(in: message.content, store: store, snapshot: serverSnapshot) }

    @ViewBuilder private var reactionButtons: some View {
        ForEach(reactions) { reaction in
            Button { react(reaction.emoji) } label: {
                HStack(spacing: 6) {
                    if let token = NativeEmojiTokens.matches(reaction.emoji).first, let emoji = emojis[token.id] {
                        NativeRemoteImage(url: emoji.url, maximumPixelSize: 72).frame(width: 22, height: 22)
                    } else { Text(reaction.emoji) }
                    Text("\(reaction.count)")
                }.font(OriginalYapper.font(12)).padding(.horizontal, 8).frame(minHeight: 28)
                    .background(reaction.isMine ? YapperPalette.accentSoft : YapperPalette.input, in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(reaction.emoji), \(reaction.count) Reaktionen\(reaction.isMine ? ", deine Reaktion" : "")")
        }
    }
}

private struct NativeAttachmentView: View {
    let attachment: MessageAttachment
    @AppStorage("native.showImages") private var showImages = true
    @State private var showingPreview = false

    private var isImage: Bool {
        NativeMessageMedia.isImage(attachment)
    }

    var body: some View {
        if let url = attachment.url {
            Button { showingPreview = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if isImage && showImages {
                        NativeRemoteImage(url: url, maximumPixelSize: 840)
                        .frame(maxWidth: 280, maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    Label(attachment.filename, systemImage: isImage ? "photo" : "doc")
                        .font(OriginalYapper.font(14))
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Zeigt den Anhang in der App")
            .sheet(isPresented: $showingPreview) { NativeAttachmentPreview(attachment: attachment) }
        } else {
            Label("\(attachment.filename) · Anhang nicht verfügbar", systemImage: "doc")
                .font(OriginalYapper.font(14))
                .foregroundStyle(YapperPalette.secondary)
        }
    }
}

private struct NativeConversationDetails: View {
    let store: NativeStore
    let conversation: Conversation
    let onOpenConversation: @MainActor (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id, username: conversation.participants.first?.username, url: conversation.avatarURL, size: 72)
                        Text(conversation.title).font(OriginalYapper.font(24, weight: .bold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(conversation.isGroup ? "Gruppengespräch" : "Direktnachricht")
                            .font(OriginalYapper.font(14))
                            .foregroundStyle(YapperPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                .listRowBackground(YapperPalette.sidebar)
                if conversation.isGroup {
                    Section {
                        NavigationLink {
                            NativeGroupEditor(store: store, conversation: conversation, onOpenConversation: onOpenConversation)
                        } label: { Label("Gruppe verwalten", systemImage: "person.2.badge.gearshape") }
                    }
                    .listRowBackground(YapperPalette.sidebar)
                }
                Section("Teilnehmende") {
                    ForEach(conversation.participants) { user in
                        NavigationLink {
                            NativeProfileView(store: store, userID: user.id, onOpenConversation: onOpenConversation)
                        } label: {
                        HStack(spacing: 12) {
                            NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName).font(OriginalYapper.font(15, weight: .semibold))
                                Text("@\(user.username)").font(OriginalYapper.font(14))
                                    .foregroundStyle(YapperPalette.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        }
                    }
                }
                .listRowBackground(YapperPalette.sidebar)
            }
            .scrollContentBackground(.hidden)
            .background(YapperPalette.background.ignoresSafeArea())
            .navigationTitle("Gespräch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }.frame(minHeight: 44)
                }
            }
            .yapperNavigation()
        }
    }
}
