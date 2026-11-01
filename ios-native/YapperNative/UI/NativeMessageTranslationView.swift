import SwiftUI

struct NativeMessageTranslationView: View {
    let store: NativeStore
    let text: String
    @Environment(\.dismiss) private var dismiss
    @State private var translated: String?
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        List {
            Section("Original") { Text(text).textSelection(.enabled) }
            if let translated { Section("Übersetzung") { Text(translated).textSelection(.enabled) } }
            if let errorMessage { Section { NativeErrorBanner(message: errorMessage) } }
            if busy { Section { ProgressView("Wird übersetzt …") } }
            else if translated == nil { Section { Button("Übersetzen") { Task { await translate() } } } }
        }
        .navigationTitle("Übersetzung")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
        .task { await translate() }
    }

    private func translate() async {
        guard !busy, translated == nil else { return }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            translated = try await store.withAuthenticatedSession { api, session in
                try await NativeMessageTranslationService(api: api).translate(text, language: Locale.preferredLanguages.first ?? "en", session: session)
            }
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
}
