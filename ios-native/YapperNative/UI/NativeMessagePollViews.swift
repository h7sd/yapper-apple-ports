import SwiftUI

struct NativePollCard: View {
    let store: NativeStore
    let message: ChatMessage
    @State private var state: NativePollViewState?
    @State private var selected: Set<String> = []
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var showingVoters: NativePollOption?

    private var serverID: String? { store.selectedConversation?.id == message.channelID ? store.selectedConversation?.serverID : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let state {
                let poll = state.poll
                HStack { Label(poll.quiz ? "Quiz" : "Umfrage", systemImage: "chart.bar.xaxis").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary); Spacer(); Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("Umfrage aktualisieren").disabled(busy) }
                Text(poll.question).font(OriginalYapper.font(16, weight: .semibold))
                ForEach(poll.options) { option in
                    let tally = state.results.first { $0.optionID == option.id }
                    Button {
                        if poll.quiz {
                            if poll.multi { if !selected.insert(option.id).inserted { selected.remove(option.id) } }
                            else { selected = selected == [option.id] ? [] : [option.id] }
                        } else {
                            var votes = Set(state.results.filter(\.mine).map(\.optionID))
                            if poll.multi { if !votes.insert(option.id).inserted { votes.remove(option.id) } }
                            else { votes = votes == [option.id] ? [] : [option.id] }
                            Task { await vote(votes) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            if selected.contains(option.id) || tally?.mine == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(YapperPalette.accent) }
                            if state.visible && state.correct.contains(option.id) { Image(systemName: "checkmark.shield.fill").foregroundStyle(YapperPalette.success) }
                            Text(option.text).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if state.visible { Text("\(tally?.votes ?? 0)").foregroundStyle(YapperPalette.secondary).monospacedDigit() }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(YapperPalette.input, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || poll.closed || (poll.quiz && (state.voted || state.visible)))
                    .accessibilityLabel("\(option.text)\(state.visible ? ", \(tally?.votes ?? 0) Stimmen" : "")")
                    if !poll.anonymous && state.visible && (tally?.votes ?? 0) > 0 && store.capabilities.flagOn("quiz_polls", userID: store.user?.id, serverID: serverID) {
                        Button("Abstimmende für „\(option.text)“ anzeigen") { showingVoters = option }.font(OriginalYapper.font(12)).frame(minHeight: 44)
                    }
                }
                if poll.quiz && !state.voted && !state.visible && !poll.closed {
                    Button("Antwort bestätigen") { Task { await vote(selected) } }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || busy)
                }
                if let right = state.youRight { Label(right ? "Richtig beantwortet" : "Leider falsch", systemImage: right ? "checkmark.circle" : "xmark.circle").foregroundStyle(right ? YapperPalette.success : YapperPalette.secondary).font(OriginalYapper.font(14)) }
                Text("\(state.total) \(poll.quiz ? "Antworten" : "Stimmen")\(poll.multi ? " · Mehrfachauswahl" : "")\(poll.anonymous ? " · anonym" : "")").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                if let closes = poll.closesAt { Text(poll.closed ? "Umfrage beendet" : "Endet \(closes.formatted(date: .abbreviated, time: .shortened))").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                if poll.quiz && state.voted && !state.visible { Text("Deine Antwort ist gespeichert. Das Ergebnis erscheint nach Ende des Quiz.").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
            } else if loaded && error == nil { Text(.init(message.content)).textSelection(.enabled) }
            else if !loaded { ProgressView("Umfrage wird geladen …") }
            if let error {
                Text(error).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.danger)
                Button("Erneut versuchen") { Task { await load() } }.frame(minHeight: 44)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .task { await load() }
        .sheet(item: $showingVoters) { option in if let state { NativePollVoterView(store: store, state: state, option: option, serverID: serverID) } }
    }

    private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            state = try await store.withAuthenticatedSession { api, session in try await api.pollForMessage(message.id, session: session) }
            loaded = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription; loaded = true }
    }

    private func vote(_ options: Set<String>) async {
        guard let state, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            self.state = try await store.withAuthenticatedSession { api, session in try await api.votePoll(state.poll, options: options, session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct NativePollCreator: View {
    let store: NativeStore
    let conversation: Conversation
    let didCreate: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multi = false
    @State private var hours = 24
    @State private var quiz = false
    @State private var correct: Set<Int> = []
    @State private var reveal = "vote"
    @State private var anonymous = false
    @State private var busy = false
    @State private var error: String?

    private var valid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.utf16.count <= 200
        && options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 80 }
        && (!quiz || (!correct.isEmpty && correct.count < options.count && (reveal != "close" || hours > 0)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Quiz", isOn: $quiz)
                    TextField("Frage", text: $question, axis: .vertical).lineLimit(2...4)
                    Text("\(question.utf16.count) / 200").font(OriginalYapper.font(12)).foregroundStyle(.secondary)
                }
                Section("Antworten") {
                    ForEach(options.indices, id: \.self) { index in
                        HStack {
                            if quiz { Button { if !correct.insert(index).inserted { correct.remove(index) } } label: { Image(systemName: correct.contains(index) ? "checkmark.circle.fill" : "circle").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Option \(index + 1) als richtige Antwort markieren") }
                            TextField("Option \(index + 1)", text: $options[index])
                            if options.count > 2 { Button(role: .destructive) { removeOption(index) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("Option \(index + 1) entfernen") }
                        }
                    }
                    if options.count < 10 { Button("Option hinzufügen") { options.append("") } }
                    if quiz { Text("Markiere mindestens eine richtige und eine falsche Antwort.").font(OriginalYapper.font(12)).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("Mehrere Antworten erlauben", isOn: $multi)
                    Toggle("Anonym abstimmen", isOn: $anonymous)
                    Picker("Laufzeit", selection: $hours) {
                        Text("Kein Ende").tag(0); Text("1 Stunde").tag(1); Text("4 Stunden").tag(4); Text("8 Stunden").tag(8)
                        Text("24 Stunden").tag(24); Text("3 Tage").tag(72); Text("7 Tage").tag(168)
                    }
                    if quiz { Picker("Richtige Antwort zeigen", selection: $reveal) { Text("Nach der Antwort").tag("vote"); Text("Nach Quizende").tag("close") } }
                }
                if let error { Section { Text(error).foregroundStyle(YapperPalette.danger) } }
            }
            .navigationTitle(quiz ? "Quiz erstellen" : "Umfrage erstellen").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Erstellen") { Task { await create() } }.disabled(!valid || busy) }
            }
            .interactiveDismissDisabled(busy)
            .yapperNavigation()
        }
    }

    private func removeOption(_ index: Int) {
        options.remove(at: index)
        correct = Set(correct.filter { $0 != index }.map { $0 > index ? $0 - 1 : $0 })
    }

    private func create() async {
        guard valid, !busy else { return }
        busy = true; error = nil
        do {
            _ = try await store.withAuthenticatedSession { api, session in
                try await api.createPoll(channelID: conversation.id, question: question, options: options, multi: multi, hours: hours, quiz: quiz, correct: correct, reveal: reveal, anonymous: anonymous, session: session); return true
            }
            await didCreate(); dismiss()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        busy = false
    }
}
