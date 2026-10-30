import SwiftUI

struct NativeConversationView: View {
    let store: NativeStore
    let conversation: Conversation
    @FocusState private var composerFocused: Bool
    @State private var showingDetails = false
    @State private var sendFailed = false

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

    private var canSend: Bool {
        !(store.drafts[conversation.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftLength <= 2000
            && !store.isSending
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if store.hasMoreMessages && !visibleMessages.isEmpty {
                        Button {
                            Task { await store.loadOlderMessages(in: conversation) }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoading { ProgressView() }
                                Text("Ältere Nachrichten laden")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(store.isLoading)
                        .accessibilityIdentifier("native.messages.loadOlder")
                    }
                    if store.isLoading && visibleMessages.isEmpty {
                        ProgressView("Nachrichten werden geladen …")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 64)
                    } else if visibleMessages.isEmpty {
                        ContentUnavailableView("Hier beginnt euer Gespräch", systemImage: "bubble.left.and.bubble.right", description: Text("Schreibe eine Nachricht an \(conversation.title)."))
                            .padding(.top, 44)
                    }
                    ForEach(visibleMessages) { message in
                        NativeMessageRow(message: message, isOwn: message.author.id == store.user?.id)
                            .id(message.id)
                            .accessibilityIdentifier("native.message.\(message.id)")
                    }
                    Color.clear.frame(height: 1).id("native.messages.bottom")
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background(YapperPalette.background.ignoresSafeArea())
            .refreshable { await store.loadMessages(for: conversation) }
            .onChange(of: visibleMessages.last?.id) { _, _ in
                proxy.scrollTo("native.messages.bottom", anchor: .bottom)
            }
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
                    composer
                    if draftLength >= 1700 {
                        Text(draftLength > 2000
                            ? "\(draftLength - 2000) Zeichen zu viel · maximal 2.000"
                            : "Noch \(2000 - draftLength) Zeichen")
                            .font(.caption)
                            .foregroundStyle(draftLength > 2000 ? YapperPalette.danger : YapperPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 8)
                            .accessibilityIdentifier("native.composer.remaining")
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(YapperPalette.sidebar)
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDetails = true
                    } label: {
                        Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Gesprächsinformationen")
                }
            }
            .sheet(isPresented: $showingDetails) {
                NativeConversationDetails(conversation: conversation)
            }
            .task(id: conversation.id) { await store.loadMessages(for: conversation) }
            .onDisappear { store.closeConversation(id: conversation.id) }
            .yapperNavigation()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Nachricht an \(conversation.title)", text: draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(minHeight: 48)
                .background(YapperPalette.input, in: .rect(cornerRadius: 18))
                .focused($composerFocused)
                .accessibilityLabel("Nachricht schreiben")
                .accessibilityIdentifier("native.composer")
            Button {
                sendDraft()
            } label: {
                Group {
                    if store.isSending {
                        ProgressView().tint(YapperPalette.accentLabel)
                    } else {
                        Image(systemName: sendFailed ? "arrow.clockwise" : "arrow.up").font(.body.weight(.bold))
                    }
                }
                .frame(width: 48, height: 48)
                .foregroundStyle(YapperPalette.accentLabel)
                .background(YapperPalette.accent.opacity(canSend ? 1 : 0.4), in: .circle)
            }
            .disabled(!canSend)
            .accessibilityLabel(store.isSending ? "Nachricht wird gesendet" : sendFailed ? "Nachricht erneut senden" : "Nachricht senden")
            .accessibilityIdentifier("native.send")
        }
    }

    private func sendDraft() {
        guard canSend else { return }
        let text = store.drafts[conversation.id] ?? ""
        Task {
            sendFailed = !(await store.sendMessage(text, in: conversation))
        }
    }
}

private struct NativeMessageRow: View {
    let message: ChatMessage
    let isOwn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NativeAvatar(name: message.author.displayName, url: message.author.avatarURL, size: 34)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message.author.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOwn ? YapperPalette.accent : YapperPalette.text)
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(YapperPalette.secondary)
                        .accessibilityLabel(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !message.content.isEmpty {
                    Text(verbatim: message.content)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(message.attachments) { attachment in
                    NativeAttachmentView(attachment: attachment)
                }
                if message.isEdited {
                    Text("Bearbeitet").font(.caption).foregroundStyle(YapperPalette.secondary)
                }
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct NativeAttachmentView: View {
    let attachment: MessageAttachment
    @AppStorage("native.showImages") private var showImages = true

    private var isImage: Bool {
        attachment.contentType?.hasPrefix("image/") == true
    }

    var body: some View {
        if let url = attachment.url {
            Link(destination: url) {
                VStack(alignment: .leading, spacing: 8) {
                    if isImage && showImages {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            Image(systemName: "photo")
                                .foregroundStyle(YapperPalette.secondary)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        }
                        .frame(maxWidth: 280, maxHeight: 260)
                        .clipShape(.rect(cornerRadius: 12))
                    }
                    Label(attachment.filename, systemImage: isImage ? "photo" : "doc")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
            .accessibilityHint("Öffnet den Anhang")
        } else {
            Label("\(attachment.filename) · Anhang nicht verfügbar", systemImage: "doc")
                .font(.subheadline)
                .foregroundStyle(YapperPalette.secondary)
        }
    }
}

private struct NativeConversationDetails: View {
    let conversation: Conversation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        NativeAvatar(name: conversation.title, url: conversation.avatarURL, size: 72)
                        Text(conversation.title).font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(conversation.isGroup ? "Gruppengespräch" : "Direktnachricht")
                            .font(.subheadline)
                            .foregroundStyle(YapperPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
                .listRowBackground(YapperPalette.sidebar)
                Section("Teilnehmende") {
                    ForEach(conversation.participants) { user in
                        HStack(spacing: 12) {
                            NativeAvatar(name: user.displayName, url: user.avatarURL, presence: user.presence, size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(user.displayName).font(.body.weight(.semibold))
                                Text("@\(user.username)").font(.subheadline)
                                    .foregroundStyle(YapperPalette.secondary)
                            }
                        }
                        .padding(.vertical, 5)
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
