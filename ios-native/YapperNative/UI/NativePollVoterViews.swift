import SwiftUI

struct NativePollVoterView: View {
    let store: NativeStore
    let state: NativePollViewState
    let option: NativePollOption
    let serverID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var voters: [NativePollVoter] = []
    @State private var busy = false
    @State private var more = false
    @State private var error: String?
    @State private var revision = UUID()

    var body: some View {
        NavigationStack {
            List {
                ForEach(voters) { voter in
                    HStack(spacing: 12) {
                        NativeAvatar(name: voter.profile?.displayName ?? "Unbekannt", url: voter.profile?.avatarURL, size: 36)
                        Text(voter.profile?.displayName ?? "Unbekannt")
                    }.frame(minHeight: 44)
                }
                if busy { ProgressView("Stimmen werden geladen …") }
                if let error { NativeErrorBanner(message: error); Button("Erneut versuchen") { Task { await load(more: !voters.isEmpty) } }.frame(minHeight: 44) }
                if more && !busy { Button("Weitere anzeigen") { Task { await load(more: true) } }.frame(minHeight: 44) }
                if !busy && error == nil && voters.isEmpty { Text("Noch keine Stimmen").foregroundStyle(YapperPalette.secondary) }
            }
            .navigationTitle("Stimmen für „\(option.text)“").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.frame(minHeight: 44) } }
            .task { await load(more: false) }
            .onDisappear { revision = UUID() }
            .yapperNavigation()
        }
    }

    private func load(more: Bool) async {
        guard !busy else { return }; busy = true; error = nil
        let operation = revision
        defer { if operation == revision { busy = false } }
        do {
            let rows = try await store.withAuthenticatedSession { api, session in
                try await api.pollVoters(state: state, optionID: option.id, before: more ? voters.last : nil, capabilities: store.capabilities, serverID: serverID, session: session)
            }
            guard operation == revision, !Task.isCancelled else { return }
            let previous = more ? voters : []
            var seen = Set(previous.map(\.id))
            voters = previous + rows.filter { seen.insert($0.id).inserted }
            self.more = rows.count == 50
        } catch is CancellationError {} catch { if operation == revision { self.error = error.localizedDescription } }
    }
}
