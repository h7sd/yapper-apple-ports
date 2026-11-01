import SwiftUI

struct NativeConversationPreferencesView: View {
    let store: NativeStore
    let conversation: Conversation
    let model: NativeConversationPreferenceModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingHide = false

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error { NativeErrorBanner(message: error) }
                if model.isLoading { ProgressView("Chat-Einstellungen werden geladen …") }
                if let snapshot = model.snapshot {
                    if snapshot.capabilities.pin {
                        Section {
                            Button {
                                Task { await model.pin(conversation, store: store) }
                            } label: {
                                Label(snapshot.pins.contains(conversation.id) ? "Chat lösen" : "Chat anheften", systemImage: snapshot.pins.contains(conversation.id) ? "pin.slash" : "pin")
                            }
                            .accessibilityIdentifier("native.conversation.preferences.pin")
                        }
                    }
                    Section("Benachrichtigungen") {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            if model.isMuted(conversation.id, at: context.date) {
                                if let until = snapshot.muteUntil[conversation.id] {
                                    LabeledContent("Stumm bis", value: until.formatted(date: .abbreviated, time: .shortened))
                                } else { Label("Stumm bis du die Stummschaltung aufhebst", systemImage: "bell.slash") }
                            } else { Label("Benachrichtigungen aktiviert", systemImage: "bell") }
                        }
                        if model.isMuted(conversation.id) {
                            Button("Stummschaltung aufheben") { changeMute(.off) }
                        } else if snapshot.capabilities.timedMute {
                            ForEach(NativeConversationMuteDuration.allCases.filter { $0 != .off }) { duration in
                                Button("Stummschalten: " + duration.label) { changeMute(duration) }
                            }
                        } else {
                            Button("Chat stummschalten") { changeMute(.forever) }
                        }
                    }
                    if snapshot.capabilities.hide {
                        Section {
                            Button(conversation.isGroup ? "Gruppe ausblenden" : "Chat schließen") { confirmingHide = true }
                                .accessibilityIdentifier("native.conversation.preferences.hide")
                        } footer: {
                            Text("Blendet den Chat aus deiner Liste aus. Eine neue Nachricht lässt ihn wieder erscheinen. Deine Nachrichten und die Gruppenmitgliedschaft bleiben erhalten.")
                        }
                    }
                } else if !model.isLoading {
                    Button("Erneut laden") { Task { await model.load(store: store) } }
                }
            }
            .disabled(model.isBusy)
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.frame(minHeight: 44) } }
            .confirmationDialog(conversation.isGroup ? "Gruppe ausblenden?" : "Chat schließen?", isPresented: $confirmingHide, titleVisibility: .visible) {
                Button("Ausblenden") { Task { if await model.hide(conversation, store: store) { dismiss() } } }
            } message: { Text("Eine neue Nachricht zeigt den Chat wieder in deiner Liste an.") }
            .task { if model.snapshot == nil { await model.load(store: store) } }
            .scrollContentBackground(.hidden)
            .background(YapperPalette.background.ignoresSafeArea())
            .yapperNavigation()
        }
    }

    private func changeMute(_ duration: NativeConversationMuteDuration) {
        Task { await model.mute(conversation, duration: duration, store: store) }
    }
}
