import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct NativeCommunityView: View {
    let store: NativeStore
    @State private var flags: Set<String>?
    @State private var error: String?

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if let flags {
                if flags.contains("shards") {
                    NavigationLink { NativeShardsView(store: store, flags: flags) } label: { Label("Shards & Quests", systemImage: "diamond") }
                }
                if flags.contains("global_leaderboards") || flags.contains("shards") {
                    NavigationLink { NativeLeaderboardView(store: store) } label: { Label("Ranglisten", systemImage: "list.number") }
                }
                if flags.contains("community_decos") {
                    NavigationLink { NativeDecorationCatalogView(store: store) } label: { Label("Dekorationen", systemImage: "sparkles") }
                }
                NavigationLink { NativeCommunitySupportView(store: store, flags: flags) } label: { Label("Hilfe & Kontostatus", systemImage: "questionmark.circle") }
                if flags.contains("plus") {
                    Link(destination: URL(string: "https://www.yapin.gg/")!) { Label("Plus & Geschenke auf yapin.gg", systemImage: "safari") }
                        .frame(minHeight: 44)
                }
            } else if error == nil { ProgressView("Community wird geladen …").frame(maxWidth: .infinity) }
        }
        .scrollContentBackground(.hidden)
        .background(YapperPalette.background.ignoresSafeArea())
        .navigationTitle("Community")
        .task { await load() }
        .refreshable { await load() }
        .yapperNavigation()
    }

    private func load() async {
        error = nil
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { flags = ["shards", "shard_quests", "global_leaderboards", "community_decos", "verification", "suggest_form"]; return }
            #endif
            flags = try await store.withAuthenticatedSession { api, session in try await api.communityFlags(session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeShardsView: View {
    let store: NativeStore
    let flags: Set<String>
    @State private var balance: NativeShardBalance?
    @State private var quests: [NativeShardQuest] = []
    @State private var ledger: [NativeShardLedgerEntry] = []
    @State private var streak: NativeChatStreak?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isBusy = false
    @State private var hasMore = false
    @State private var confirmLevel = false

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if let balance {
                Section("Deine Shards") {
                    LabeledContent("Guthaben") { Label(balance.balance.formatted(), systemImage: "diamond") }
                    LabeledContent("Level", value: balance.level.formatted())
                    LabeledContent("Insgesamt verdient", value: balance.earned.formatted())
                    if balance.frozen { Text("Deine Shards sind aktuell eingefroren. Du kannst sie derzeit nicht verdienen oder ausgeben.").foregroundStyle(YapperPalette.danger) }
                    if let cost = balance.nextCost {
                        Button("Level für \(cost.formatted()) Shards erhöhen") { confirmLevel = true }
                            .frame(minHeight: 44)
                            .disabled(isBusy || balance.frozen || balance.balance < cost)
                    }
                }
            } else if isLoading { ProgressView("Shards werden geladen …").frame(maxWidth: .infinity) }
            if !quests.isEmpty {
                Section("Quests") {
                    ForEach(quests) { quest in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: quest.title).font(OriginalYapper.font(16, weight: .semibold))
                            if !quest.how.isEmpty { Text(verbatim: quest.how).foregroundStyle(YapperPalette.secondary) }
                            Label("\(quest.reward.formatted()) Shards", systemImage: "diamond").font(OriginalYapper.font(14))
                            if quest.claimed { Label("Abgeholt", systemImage: "checkmark.circle").foregroundStyle(YapperPalette.secondary) }
                            else if quest.done {
                                Button("Belohnung abholen") { Task { await claim(quest) } }.frame(minHeight: 44).disabled(isBusy || balance?.frozen == true)
                            } else { Text("Noch nicht abgeschlossen").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            if let streak {
                Section("Chat-Streak") {
                    LabeledContent("Aktuell", value: "\(streak.current) Tage")
                    LabeledContent("Beste Serie", value: "\(streak.best) Tage")
                    LabeledContent("Heute", value: streak.counted ? "Zählt bereits" : "\(min(streak.todayMessages, streak.requiredMessages))/\(streak.requiredMessages) Nachrichten")
                    LabeledContent("Streak-Freezes", value: streak.freezesLeft.formatted())
                    Toggle("Auf meinem Profil anzeigen", isOn: Binding(get: { !streak.hidden }, set: { show in Task { await setStreakHidden(!show) } })).disabled(isBusy)
                }
            }
            Section("Verlauf") {
                if ledger.isEmpty && !isLoading { Text("Noch keine Einträge.").foregroundStyle(YapperPalette.secondary) }
                ForEach(ledger) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.label)
                            Text(entry.createdAt, format: .dateTime.day().month().hour().minute()).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                        }
                        Spacer()
                        Text(entry.amount, format: .number.sign(strategy: .always())).monospacedDigit()
                    }
                }
                if hasMore { Button("Ältere Einträge laden") { Task { await loadOlder() } }.frame(minHeight: 44).disabled(isLoading || isBusy) }
            }
        }
        .navigationTitle("Shards & Quests")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Level erhöhen?", isPresented: $confirmLevel, titleVisibility: .visible) {
            if let cost = balance?.nextCost { Button("\(cost.formatted()) Shards ausgeben") { Task { await levelUp() } } }
        }
        .yapperNavigation()
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { balance = try NativeShardBalance(row: .object(["balance": .number(120), "earned": .number(300), "level": .number(2)])); ledger = []; quests = []; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in
                let balance = try await api.communityShards(session: session)
                try Task.checkCancellation()
                let ledger = try await api.communityLedger(session: session)
                try Task.checkCancellation()
                let quests = flags.contains("shard_quests") ? try await api.communityQuests(session: session) : []
                let streak = try await api.communityStreak(session: session)
                return (balance, ledger, quests, streak)
            }
            balance = result.0; ledger = result.1; quests = result.2; streak = result.3; hasMore = ledger.count == 50
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    private func claim(_ quest: NativeShardQuest) async {
        guard quest.done, !quest.claimed else { return }
        await mutate { api, session in _ = try await api.claimCommunityQuest(key: quest.id, session: session) }
    }
    private func levelUp() async { await mutate { api, session in _ = try await api.communityLevelUp(session: session) } }
    private func setStreakHidden(_ value: Bool) async { await mutate { api, session in _ = try await api.setCommunityStreakHidden(value, session: session) } }
    private func mutate(_ operation: @MainActor (NativeAPI, NativeSession) async throws -> Void) async {
        guard !isBusy else { return }; isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession(operation)
            await store.refreshOwnProfile(); await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func loadOlder() async {
        guard let last = ledger.last, !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.communityLedger(before: last.id, session: session) }
            let seen = Set(ledger.map(\.id)); ledger += result.filter { !seen.contains($0.id) }; hasMore = result.count == 50
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeLeaderboardView: View {
    let store: NativeStore
    @State private var kind: NativeLeaderboardKind = .level
    @State private var board: NativeLeaderboard?
    @State private var error: String?
    @State private var busy = false
    @State private var openedConversation: Conversation?

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            Section {
                Picker("Rangliste", selection: $kind) { ForEach(NativeLeaderboardKind.allCases) { Text($0.label).tag($0) } }
            }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if let board {
                Section {
                    if board.rows.isEmpty { Text("Auf dieser Rangliste ist noch niemand aufgeführt.").foregroundStyle(YapperPalette.secondary) }
                    ForEach(board.rows) { row in
                        if let profile = row.profile {
                            NavigationLink {
                                NativeProfileView(store: store, userID: row.id) { openedConversation = $0 }
                            } label: {
                                HStack(spacing: 12) {
                                    Text("#\(row.position)").monospacedDigit().foregroundStyle(YapperPalette.secondary)
                                    NativeAvatar(name: profile.displayName, identity: profile.id, username: profile.username, url: profile.avatarURL, size: 38, decorationURL: profile.user.avatarDecorationURL)
                                    Text(verbatim: profile.displayName)
                                    Spacer(minLength: 8)
                                    Text(score(row.score)).font(OriginalYapper.font(14)).monospacedDigit()
                                }
                                .frame(minHeight: 44)
                            }
                        }
                    }
                }
                if let position = board.ownPosition, !board.rows.contains(where: { $0.id == store.user?.id }) {
                    Section("Deine Platzierung") { LabeledContent("#\(position)", value: score(board.ownScore ?? 0)) }
                }
                Section {
                    Toggle("Mich aus Ranglisten ausblenden", isOn: Binding(get: { board.hidden }, set: { value in Task { await setHidden(value) } })).disabled(busy)
                }
            } else if error == nil { ProgressView("Rangliste wird geladen …").frame(maxWidth: .infinity) }
        }
        .navigationTitle("Ranglisten")
        .task(id: kind) { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $openedConversation) { NativeConversationView(store: store, conversation: $0) }
        .yapperNavigation()
    }
    private func score(_ value: Int) -> String { kind == .voice ? "\(value / 60) Min." : value.formatted() }
    private func load() async {
        let requested = kind; board = nil; error = nil
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { board = NativeLeaderboard(rows: [], ownPosition: nil, ownScore: nil, hidden: false); return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.communityLeaderboard(requested, session: session) }
            guard requested == kind, !Task.isCancelled else { return }; board = result
        } catch is CancellationError {} catch { if requested == kind { self.error = error.localizedDescription } }
    }
    private func setHidden(_ hidden: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.setCommunityLeaderboardHidden(hidden, session: session) }
            await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeDecorationCatalogView: View {
    let store: NativeStore
    @State private var kind: NativeDecorationKind = .avatar
    @State private var items: [NativeCommunityDecoration] = []
    @State private var selected: NativeCommunityDecoration?
    @State private var error: String?
    @State private var isLoading = false
    @State private var hasMore = false
    @State private var busy = false
    @State private var confirmingPurchase = false

    var body: some View {
        List {
            if NativeCommunityFixture.enabled { NativeCommunityFixtureNotice() }
            Section { Picker("Art", selection: $kind) { ForEach(NativeDecorationKind.allCases) { Text($0.label).tag($0) } } }
            if let error { NativeErrorBanner(message: error) { Task { await load() } } }
            if isLoading && items.isEmpty { ProgressView("Dekorationen werden geladen …").frame(maxWidth: .infinity) }
            else if items.isEmpty && error == nil { Text("Zurzeit keine Dekorationen verfügbar.").foregroundStyle(YapperPalette.secondary) }
            ForEach(items) { item in
                Button { selected = item } label: {
                    HStack(spacing: 16) {
                        NativeRemoteImage(url: item.imageURL, maximumPixelSize: 300, mode: .fit).frame(width: 72, height: 72).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: item.name).font(OriginalYapper.font(16, weight: .semibold))
                            if item.owned { Label("In deinem Besitz", systemImage: "checkmark").font(OriginalYapper.font(12)) }
                            else if let price = item.price { Label("\(price.formatted()) Shards", systemImage: "diamond").font(OriginalYapper.font(12)) }
                        }
                        .foregroundStyle(YapperPalette.text)
                    }
                    .frame(minHeight: 72)
                }
                .buttonStyle(.plain)
            }
            if hasMore { Button("Weitere Dekorationen laden") { Task { await load(more: true) } }.frame(minHeight: 44).disabled(isLoading) }
            Section {
                Button("Aktuelle Auswahl entfernen", role: .destructive) { Task { await equip(nil) } }.frame(minHeight: 44).disabled(busy)
            }
        }
        .navigationTitle("Dekorationen")
        .task(id: kind) { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { item in
            NavigationStack {
                List {
                    Section {
                        NativeRemoteImage(url: item.imageURL, mode: .fit).frame(maxWidth: .infinity).frame(height: 260)
                        Text(verbatim: item.name).font(OriginalYapper.font(24, weight: .bold))
                    }
                    if let error { NativeErrorBanner(message: error) }
                    Section {
                        if let price = item.price, price > 0, !item.owned {
                            Button("Für \(price.formatted()) Shards kaufen und verwenden") { confirmingPurchase = true }.frame(minHeight: 44).disabled(busy)
                        } else {
                            Button("Verwenden") { Task { await equip(item) } }.frame(minHeight: 44).disabled(busy)
                        }
                    }
                }
                .navigationTitle("Vorschau")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { selected = nil }.disabled(busy) } }
                .confirmationDialog("Dekoration kaufen?", isPresented: $confirmingPurchase, titleVisibility: .visible) {
                    if let price = item.price { Button("\(price.formatted()) Shards ausgeben und verwenden") { Task { await equip(item, purchase: true) } } }
                }
                .interactiveDismissDisabled(busy)
            }
        }
        .yapperNavigation()
    }
    private func load(more: Bool = false) async {
        guard !more || !isLoading else { return }
        let requested = kind; let offset = more ? items.count : 0; isLoading = true; error = nil
        defer { isLoading = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { items = []; hasMore = false; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.communityDecorations(kind: requested, offset: offset, session: session) }
            guard requested == kind, !Task.isCancelled else { return }
            if more { let known = Set(items.map(\.id)); items += result.filter { !known.contains($0.id) } } else { items = result }
            hasMore = result.count == 200
        } catch is CancellationError {} catch { if requested == kind { self.error = error.localizedDescription } }
    }
    private func equip(_ item: NativeCommunityDecoration?, purchase: Bool = false) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            #if DEBUG
            if NativeCommunityFixture.enabled { error = NativeCommunityFixture.actionMessage; return }
            #endif
            let requestedKind = item?.kind ?? kind
            try await store.withAuthenticatedSession { api, session in
                if purchase, let item { _ = try await api.buyCommunityDecoration(item, session: session) }
                try Task.checkCancellation()
                try await api.equipCommunityDecoration(item, kind: requestedKind, session: session)
            }
            await store.refreshOwnProfile(); selected = nil; await load()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

private struct NativeCommunitySupportView: View {
    let store: NativeStore
    let flags: Set<String>
    var body: some View {
        List {
            NavigationLink { NativeAccountStandingView(store: store) } label: { Label("Kontostatus & Widerspruch", systemImage: "shield") }
            NavigationLink { NativeBugReportsView(store: store, canEdit: flags.contains("bug_report_edit")) } label: { Label("Fehlerberichte", systemImage: "ladybug") }
            if flags.contains("suggest_form") {
                NavigationLink { NativeSuggestionsView(store: store) } label: { Label("Meine Vorschläge", systemImage: "lightbulb") }
            }
            if flags.contains("verification") {
                NavigationLink { NativeVerificationApplicationView(store: store) } label: { Label("Verifizierung beantragen", systemImage: "checkmark.seal") }
            }
            Section("Yapper") {
                Link("Community-Richtlinien", destination: URL(string: "https://www.yapin.gg/guidelines")!).frame(minHeight: 44)
                Link("Nutzungsbedingungen", destination: URL(string: "https://www.yapin.gg/terms")!).frame(minHeight: 44)
                Link("Datenschutz", destination: URL(string: "https://www.yapin.gg/privacy")!).frame(minHeight: 44)
            }
        }
        .navigationTitle("Hilfe")
        .yapperNavigation()
    }
}

enum NativeCommunityFixture {
    static var enabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }
    static var actionMessage: String { "In der Testansicht werden keine Kontoänderungen ausgeführt." }
}

struct NativeCommunityFixtureNotice: View {
    var body: some View { Label("Testansicht · Beispieldaten", systemImage: "testtube.2").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
}
