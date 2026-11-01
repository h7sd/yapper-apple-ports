import SwiftUI

struct NativeMessageSearchDestination: View {
    let store: NativeStore
    let message: ChatMessage
    @State private var conversation: Conversation?
    @State private var error: String?
    var body: some View {
        Group {
            if let conversation { NativeConversationView(store: store, conversation: conversation, initialMessageID: message.id) }
            else if let error { NativeErrorBanner(message: error) { Task { await load() } }.padding() }
            else { ProgressView("Gespräch wird geladen …") }
        }
        .task { await load() }
    }
    private func load() async {
        error = nil
        do { conversation = try await store.withAuthenticatedSession { api, session in try await api.conversationForSearchResult(message, session: session) } }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
