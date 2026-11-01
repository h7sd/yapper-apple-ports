import SwiftUI

struct NativeMessageComponentsView: View {
    let store: NativeStore
    let message: ChatMessage
    let components: [NativeJSON]
    @Environment(\.openURL) private var openURL
    @AppStorage("native.showImages") private var showImages = true
    @State private var pending: Set<String> = []
    @State private var interactions: [String: String] = [:]
    @State private var replies: [NativeBotInteractionReply] = []
    @State private var error: String?
    @State private var link: URL?
    @State private var tasks: [String: Task<Void, Never>] = [:]
    @State private var revision = UUID()
    @State private var emojis: [String: NativeCustomEmoji] = [:]

    private var serverID: String? { store.selectedConversation?.id == message.channelID ? store.selectedConversation?.serverID : nil }
    private var enabled: Bool { store.capabilities.flagOn(NativeMessageComponent.isV2(components) ? "bot_components_v2" : "bot_buttons", userID: store.user?.id, serverID: serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if enabled {
                ForEach(Array(NativeMessageComponent.parse(components).enumerated()), id: \.offset) { _, component in node(component) }
                ForEach(replies) { reply in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Nur für dich", systemImage: "eye").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                            Spacer()
                            Button { replies.removeAll { $0.id == reply.id } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Private Bot-Antwort ausblenden")
                        }
                        if !reply.content.isEmpty { Text(.init(reply.content)).textSelection(.enabled) }
                        ForEach(Array(reply.embeds.enumerated()), id: \.offset) { _, embed in NativeMessageEmbed(embed: embed) }
                    }.padding(10).background(YapperPalette.input, in: .rect(cornerRadius: 10))
                }
                if let error { Text(error).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.danger) }
                if !interactions.isEmpty {
                    Button("Bot-Antworten aktualisieren") { for (button, _) in interactions { fetch(button, press: nil) } }.font(OriginalYapper.font(12)).frame(minHeight: 44).disabled(!pending.isEmpty)
                }
            } else { Text("Diese Bot-Nachricht ist für dein Konto noch nicht freigeschaltet.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
        }
        .confirmationDialog("Link öffnen?", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }), titleVisibility: .visible) {
            if let link { Button("Im Browser öffnen") { openURL(link); self.link = nil } }
            Button("Abbrechen", role: .cancel) { link = nil }
        } message: { Text(link?.absoluteString ?? "") }
        .onDisappear { revision = UUID(); tasks.values.forEach { $0.cancel() }; tasks.removeAll(); replies.removeAll() }
        .task(id: components) {
            let ids = Array(Set(NativeMessageComponent.parse(components).flatMap(\.emojiIDs)).prefix(100))
            guard enabled, !ids.isEmpty else { return }
            do { emojis = try await store.withAuthenticatedSession { api, session in try await api.messageEmojis(ids: ids, session: session) } }
            catch { /* Emoji names remain readable when their image cannot be loaded. */ }
        }
    }

    private func node(_ value: NativeMessageComponent) -> AnyView {
        switch value {
        case let .text(text):
            if !NativeEmojiTokens.matches(text).isEmpty { return AnyView(NativeMessageRichText(text: text, emojis: emojis)) }
            return AnyView(Text(.init(text)).textSelection(.enabled).environment(\.openURL, OpenURLAction { url in NativeEmbedURLs.link(.string(url.absoluteString)) == nil ? .discarded : .systemAction }))
        case let .buttons(buttons):
            return AnyView(LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button {
                        if let url = button.url { link = url }
                        else if let id = button.customID { fetch(id, press: button) }
                    } label: {
                        HStack(spacing: 6) {
                            if pending.contains(button.id) { ProgressView() }
                            if let token = NativeEmojiTokens.matches(button.emoji).first {
                                if let emoji = emojis[token.id] { NativeRemoteImage(url: emoji.url, maximumPixelSize: 72).frame(width: 22, height: 22).accessibilityLabel(":" + token.name + ":") }
                                else { Text(":" + token.name + ":") }
                            } else if !button.emoji.isEmpty { Text(button.emoji) }
                            if !button.label.isEmpty { Text(button.label) }
                            if button.url != nil { Image(systemName: "arrow.up.right") }
                        }.frame(maxWidth: .infinity, minHeight: 44).padding(.horizontal, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(button.style == "danger" ? YapperPalette.danger : button.style == "success" ? YapperPalette.success : button.style == "primary" ? YapperPalette.accent : YapperPalette.secondary)
                    .disabled(button.disabled || pending.contains(button.id))
                }
            })
        case let .group(children, spoiler, accent):
            let content = VStack(alignment: .leading, spacing: 8) { ForEach(Array(children.enumerated()), id: \.offset) { _, child in node(child) } }.padding(10).background(YapperPalette.input, in: .rect(cornerRadius: 10))
            if spoiler { return AnyView(DisclosureGroup("Ausgeblendeter Inhalt") { content }.frame(minHeight: 44)) }
            return AnyView(content.overlay(alignment: .leading) { if let accent { Rectangle().fill(Color(red: Double((accent >> 16) & 255) / 255, green: Double((accent >> 8) & 255) / 255, blue: Double(accent & 255) / 255)).frame(width: 3) } })
        case let .image(url, description, spoiler):
            let media = VStack(alignment: .leading) {
                if showImages, let safe = NativeEmbedURLs.image(.string(url.absoluteString)) { NativeRemoteImage(url: safe, maximumPixelSize: 1080).frame(maxWidth: 360, maxHeight: 280).clipShape(.rect(cornerRadius: 8)) }
                Button { link = url } label: { Label(description, systemImage: "photo") }.frame(minHeight: 44)
            }
            return spoiler ? AnyView(DisclosureGroup("Ausgeblendetes Bild") { media }.frame(minHeight: 44)) : AnyView(media)
        case let .file(url, name, spoiler):
            let file = Button { link = url } label: { Label(name, systemImage: "doc") }.frame(minHeight: 44)
            return spoiler ? AnyView(DisclosureGroup("Ausgeblendete Datei") { file }.frame(minHeight: 44)) : AnyView(file)
        case let .separator(divider, large): return AnyView(Group { if divider { Divider() }; Color.clear.frame(height: large ? 16 : 4) })
        }
    }

    private func fetch(_ buttonID: String, press button: NativeMessageButton?) {
        guard let originUser = store.user?.id, pending.insert(buttonID).inserted else { return }
        let operation = revision
        tasks[buttonID] = Task {
            defer { if operation == revision { pending.remove(buttonID); tasks[buttonID] = nil } }
            do {
                if let button {
                    let id = try await store.withAuthenticatedSession { api, session in try await api.pressMessageButton(messageID: message.id, button: button, session: session) }
                    guard revision == operation, store.user?.id == originUser else { return }
                    interactions[buttonID] = id
                    try await Task.sleep(for: .seconds(3))
                }
                guard let interaction = interactions[buttonID], store.user?.id == originUser else { throw CancellationError() }
                let rows = try await store.withAuthenticatedSession { api, session in try await api.messageButtonReplies(interactionID: interaction, messageID: message.id, channelID: message.channelID, session: session) }
                guard revision == operation, !Task.isCancelled else { return }
                var seen = Set(replies.map(\.id))
                replies = Array((replies + rows.filter { seen.insert($0.id).inserted }).suffix(20))
                error = rows.isEmpty ? "Noch keine private Antwort. Öffentliche Antworten erscheinen im Gespräch." : nil
            } catch is CancellationError {} catch { if revision == operation { self.error = error.localizedDescription } }
        }
    }
}
