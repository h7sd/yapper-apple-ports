import Foundation
import Observation

@MainActor @Observable final class NativeStore {
    private(set) var user: YapperUser?
    private(set) var conversations: [Conversation] = []
    private(set) var messages: [ChatMessage] = []
    var selectedConversation: Conversation?
    private(set) var isLoadingConversations = false
    private(set) var isLoadingMessages = false
    private(set) var hasMoreMessages = false
    var isLoading: Bool { isLoadingConversations || isLoadingMessages || authState == .restoring || authState == .signingIn }
    private(set) var isSending = false
    var errorMessage: String?
    private(set) var authState: AuthState = .signedOut
    var drafts: [String: String] = [:]
    private(set) var realtimeStatus = "Nicht verbunden"

    @ObservationIgnored private let api: NativeAPI
    @ObservationIgnored private let vault: any SessionVault
    @ObservationIgnored private let realtime: RealtimeClient?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var session: NativeSession?
    @ObservationIgnored private var pendingFactor: String?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var listRevision = 0
    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Bool, Never>?
    @ObservationIgnored private var refreshTask: Task<NativeSession, any Error>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectSyncTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var seenRealtimeInserts: Set<String> = []
    @ObservationIgnored private var profiles: [String: YapperUser] = [:]
    @ObservationIgnored private var pendingSendIDs: [String: (text: String, id: String)] = [:]
    @ObservationIgnored private var oldestMessageCursor: String?
    @ObservationIgnored private var didExplicitlySignOut = false
    #if DEBUG
    @ObservationIgnored private var isFixture = false
    #endif

    init(api: NativeAPI = NativeAPI(), vault: any SessionVault = KeychainSessionVault(), realtime: RealtimeClient? = RealtimeClient(), now: @escaping @MainActor () -> Date = Date.init) {
        self.api = api
        self.vault = vault
        self.realtime = realtime
        self.now = now
        realtime?.onMutation = { [weak self] mutation in self?.apply(mutation) }
        realtime?.onStatus = { [weak self] status in self?.realtimeStatus = status }
        realtime?.onReconnect = { [weak self] in self?.resyncAfterReconnect() }
    }

    func setDraft(_ text: String, for conversationID: String) { drafts[conversationID] = text }

    func restoreSession() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard authState == .signedOut, !didExplicitlySignOut else { return }
        let revision = epoch
        authState = .restoring
        errorMessage = nil
        authTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let saved = try self.vault.read() else {
                    if self.epoch == revision { self.authState = .signedOut }
                    return
                }
                self.session = saved
                let valid = try await self.validSession(revision: revision)
                try await self.finishAuthentication(valid, revision: revision)
            } catch {
                guard self.epoch == revision, !Task.isCancelled else { return }
                if error as? NativeClientError == .sessionExpired {
                    self.failAuthentication(error)
                } else if case let NativeClientError.api(status, _) = error, status == 401 || status == 400 {
                    self.failAuthentication(error)
                } else {
                    // A transient offline/timeout response must not destroy a valid saved refresh token.
                    self.session = nil
                    self.authState = .signedOut
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        authTask = task
        await task.value
    }

    func signIn(identifier: String, password: String, code: String? = nil) async {
        #if DEBUG
        if isFixture {
            guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
                errorMessage = "Bitte Benutzername und Passwort eingeben."
                return
            }
            populateFixture()
            return
        }
        #endif
        guard authState != .signingIn, authState != .signedIn else { return }
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code != nil || (!identifier.isEmpty && !password.isEmpty) else {
            errorMessage = "Bitte Benutzername oder E-Mail und Passwort eingeben."
            return
        }
        if code != nil, pendingFactor == nil || session == nil {
            errorMessage = NativeClientError.unsupportedChallenge.localizedDescription
            return
        }
        epoch += 1
        let revision = epoch
        authState = .signingIn
        errorMessage = nil
        authTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        if code == nil { session = nil; pendingFactor = nil }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let tokens: NativeSession
                if let code, let factor = self.pendingFactor, let pending = self.session {
                    tokens = try await self.api.verifyTOTP(factorID: factor, code: code, session: pending)
                    guard tokens.userID == pending.userID else { throw NativeClientError.invalidResponse }
                } else {
                    tokens = try await self.api.signIn(identifier: identifier, password: password)
                    let authUser = try await self.api.authUser(token: tokens.accessToken)
                    guard authUser.id == tokens.userID else { throw NativeClientError.invalidResponse }
                    guard self.epoch == revision, !Task.isCancelled else { return }
                    if let factor = authUser.factors?.first(where: { $0.factor_type == "totp" && $0.status == "verified" }) {
                        self.session = tokens
                        self.pendingFactor = factor.id
                        self.authState = .requiresTwoFactor
                        return
                    }
                }
                try await self.finishAuthentication(tokens, revision: revision)
            } catch {
                guard self.epoch == revision, !Task.isCancelled else { return }
                if self.pendingFactor != nil {
                    self.authState = .requiresTwoFactor
                    self.errorMessage = error.localizedDescription
                } else {
                    self.failAuthentication(error)
                }
            }
        }
        authTask = task
        await task.value
    }

    private func finishAuthentication(_ tokens: NativeSession, revision: Int) async throws {
        let bootstrap = try await api.bootstrap(session: tokens)
        let profile: ProfileRow
        if let found = bootstrap.profiles.first(where: { $0.id == tokens.userID }) { profile = found }
        else { profile = try await api.profile(id: tokens.userID, session: tokens) }
        let list = try bootstrap.conversations(currentUserID: tokens.userID)
        try Task.checkCancellation()
        guard epoch == revision else { throw CancellationError() }
        try vault.save(tokens)
        session = tokens
        didExplicitlySignOut = false
        user = profile.user()
        profiles = Dictionary(bootstrap.profiles.map { ($0.id, $0.user()) }, uniquingKeysWith: { _, new in new })
        profiles[tokens.userID] = user
        conversations = list
        pendingFactor = nil
        authState = .signedIn
        errorMessage = nil
        if isActive { realtime?.connect(session: tokens); startMaintenance() }
    }

    func loadConversations() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard authState == .signedIn else { return }
        let revision = epoch
        listRevision += 1
        let listID = listRevision
        listTask?.cancel()
        isLoadingConversations = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == revision, self.listRevision == listID { self.isLoadingConversations = false }
            }
            do {
                let valid = try await self.validSession(revision: revision)
                let data = try await self.api.bootstrap(session: valid)
                let list = try data.conversations(currentUserID: valid.userID)
                try Task.checkCancellation()
                guard self.epoch == revision, self.listRevision == listID else { return }
                for profile in data.profiles { self.profiles[profile.id] = profile.user() }
                self.conversations = list
            } catch {
                guard self.epoch == revision, self.listRevision == listID, !Task.isCancelled else { return }
                self.handle(error)
            }
        }
        listTask = task
        await task.value
    }

    func loadMessages(for conversation: Conversation) async {
        guard authState == .signedIn else { return }
        selectedConversation = conversation
        #if DEBUG
        if isFixture {
            messages = Self.fixtureMessages(conversationID: conversation.id, selfUser: user!)
            return
        }
        #endif
        hasMoreMessages = false
        oldestMessageCursor = nil
        await loadHistory(for: conversation, before: nil)
    }

    func loadOlderMessages(in conversation: Conversation) async {
        guard authState == .signedIn, selectedConversation?.id == conversation.id,
              hasMoreMessages, !isLoadingMessages, let oldestMessageCursor else { return }
        await loadHistory(for: conversation, before: oldestMessageCursor)
    }

    func closeConversation(id: String) {
        guard selectedConversation?.id == id else { return }
        historyRevision += 1
        historyTask?.cancel()
        selectedConversation = nil
        messages = []
        oldestMessageCursor = nil
        hasMoreMessages = false
        isLoadingMessages = false
    }

    func cancelSignIn() {
        guard authState == .requiresTwoFactor || authState == .signingIn else { return }
        signOut()
    }

    private func loadHistory(for conversation: Conversation, before: String?) async {
        let revision = epoch
        historyRevision += 1
        let historyID = historyRevision
        historyTask?.cancel()
        if before == nil { messages = [] }
        isLoadingMessages = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == revision, self.historyRevision == historyID { self.isLoadingMessages = false }
            }
            do {
                let valid = try await self.validSession(revision: revision)
                let history = try await self.api.history(channelID: conversation.id, before: before, session: valid)
                var profiles = self.profiles
                for profile in history.profiles { profiles[profile.id] = profile.user() }
                let messages = try history.messages.map { try $0.message(profiles: profiles) }
                guard messages.allSatisfy({ $0.channelID == conversation.id }) else { throw NativeClientError.invalidResponse }
                try Task.checkCancellation()
                guard self.epoch == revision, self.historyRevision == historyID, self.selectedConversation?.id == conversation.id else { return }
                self.profiles = profiles
                let cursor = history.messages.min { $0.created_at < $1.created_at }?.created_at
                self.hasMoreMessages = history.messages.count == 50 && cursor != before
                if let cursor { self.oldestMessageCursor = cursor }
                // Include inserts received while the history request was in flight.
                self.messages = Self.merged(messages + self.messages)
            } catch {
                guard self.epoch == revision, self.historyRevision == historyID, !Task.isCancelled else { return }
                self.handle(error)
            }
        }
        historyTask = task
        await task.value
    }

    @discardableResult func sendMessage(_ text: String, in conversation: Conversation) async -> Bool {
        guard authState == .signedIn, !isSending else { return false }
        drafts[conversation.id] = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = NativeClientError.emptyMessage.localizedDescription; return false }
        guard trimmed.utf16.count <= 2000 else { errorMessage = NativeClientError.messageTooLong.localizedDescription; return false }
        #if DEBUG
        if isFixture, let user {
            messages = Self.merged(messages + [ChatMessage(id: UUID().uuidString, channelID: conversation.id, author: user, content: trimmed, createdAt: Date(), attachments: [], isEdited: false)])
            drafts[conversation.id] = ""
            return true
        }
        #endif
        let revision = epoch
        let sendID = pendingSendIDs[conversation.id].flatMap { $0.text == trimmed ? $0.id : nil } ?? UUID().uuidString
        pendingSendIDs[conversation.id] = (trimmed, sendID)
        isSending = true
        errorMessage = nil
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { if self.epoch == revision { self.isSending = false } }
            do {
                let valid = try await self.validSession(revision: revision)
                let row = try await self.api.send(id: sendID, text: trimmed, channelID: conversation.id, session: valid)
                guard row.id == sendID, row.channel_id == conversation.id, row.author_id == valid.userID else { throw NativeClientError.invalidResponse }
                let message = try row.message(profiles: self.profiles)
                try Task.checkCancellation()
                guard self.epoch == revision else { return false }
                if self.selectedConversation?.id == conversation.id { self.messages = Self.merged(self.messages + [message]) }
                if self.drafts[conversation.id] == text { self.drafts[conversation.id] = "" }
                self.pendingSendIDs[conversation.id] = nil
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) { self.conversations[index].lastMessage = trimmed }
                return true
            } catch {
                guard self.epoch == revision, !Task.isCancelled else { return false }
                self.handle(error)
                return false
            }
        }
        sendTask = task
        return await task.value
    }

    func signOut() {
        epoch += 1
        didExplicitlySignOut = true
        authTask?.cancel()
        listTask?.cancel()
        historyTask?.cancel()
        sendTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        maintenanceTask?.cancel()
        reconnectSyncTask?.cancel()
        realtime?.disconnect()
        session = nil
        pendingFactor = nil
        user = nil
        conversations = []
        messages = []
        profiles = [:]
        seenRealtimeInserts = []
        drafts = [:]
        pendingSendIDs = [:]
        oldestMessageCursor = nil
        hasMoreMessages = false
        selectedConversation = nil
        isSending = false
        isLoadingConversations = false
        isLoadingMessages = false
        authState = .signedOut
        realtimeStatus = "Nicht verbunden"
        errorMessage = nil
        do { try vault.clear() }
        catch { errorMessage = "Die Sitzung wurde in der App beendet, konnte aber nicht aus dem iOS-Schlüsselbund gelöscht werden. Bitte versuche das Abmelden erneut. " + error.localizedDescription }
    }

    private func validSession(revision: Int) async throws -> NativeSession {
        guard epoch == revision, let session else { throw NativeClientError.missingSession }
        if session.expiresAt.timeIntervalSince(now()) > 60 { return session }
        let task: Task<NativeSession, any Error>
        let operationID: UUID
        if let refreshing = refreshTask, let existingID = refreshID {
            task = refreshing
            operationID = existingID
        }
        else {
            operationID = UUID()
            // Refresh owns the token rotation. Cancelling a chat request must not discard new tokens.
            task = Task { [weak self, api] in
                let fresh: NativeSession
                do { fresh = try await api.refresh(session) }
                catch let NativeClientError.api(status, _) where status == 400 || status == 401 { throw NativeClientError.sessionExpired }
                guard let self, self.epoch == revision, !Task.isCancelled else { throw CancellationError() }
                guard fresh.userID == session.userID else { throw NativeClientError.invalidResponse }
                try self.vault.save(fresh)
                self.session = fresh
                if self.isActive, self.authState == .signedIn { self.realtime?.connect(session: fresh) }
                return fresh
            }
            refreshTask = task
            refreshID = operationID
        }
        do {
            let fresh = try await task.value
            guard epoch == revision else { throw CancellationError() }
            if refreshID == operationID { refreshTask = nil; refreshID = nil }
            try Task.checkCancellation()
            return fresh
        } catch {
            if epoch == revision, refreshID == operationID { refreshTask = nil; refreshID = nil }
            throw error
        }
    }

    private func failAuthentication(_ error: any Error) {
        signOut()
        if let deletionError = errorMessage { errorMessage = error.localizedDescription + " " + deletionError }
        else { errorMessage = error.localizedDescription }
    }

    private func handle(_ error: any Error) {
        if error as? NativeClientError == .sessionExpired {
            failAuthentication(NativeClientError.sessionExpired)
        } else if case let NativeClientError.api(status, _) = error, status == 401 {
            failAuthentication(NativeClientError.sessionExpired)
        } else { errorMessage = error.localizedDescription }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        #if DEBUG
        if isFixture { return }
        #endif
        if active, authState == .signedIn {
            startMaintenance()
            resyncAfterReconnect()
        } else {
            maintenanceTask?.cancel()
            reconnectSyncTask?.cancel()
            realtime?.disconnect()
            realtimeStatus = "Verbindung pausiert"
        }
    }

    private func startMaintenance() {
        guard realtime != nil else { return }
        maintenanceTask?.cancel()
        let revision = epoch
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            while self.epoch == revision, self.authState == .signedIn, self.isActive, !Task.isCancelled {
                do {
                    let valid = try await self.validSession(revision: revision)
                    guard self.epoch == revision, self.isActive, !Task.isCancelled else { return }
                    let delay = max(1, min(60, valid.expiresAt.timeIntervalSince(self.now()) - 60))
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    guard self.epoch == revision, !Task.isCancelled else { return }
                    if error as? NativeClientError == .sessionExpired { self.handle(error); return }
                    self.realtimeStatus = "Sitzung konnte nicht aktualisiert werden · erneuter Versuch …"
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
        }
    }

    private func resyncAfterReconnect() {
        reconnectSyncTask?.cancel()
        let revision = epoch
        let selectedID = selectedConversation?.id
        reconnectSyncTask = Task { [weak self] in
            guard let self else { return }
            do {
                let valid = try await self.validSession(revision: revision)
                guard self.epoch == revision, self.isActive, !Task.isCancelled else { return }
                // Foreground resumption opens a fresh native socket; a socket reconnect already has one.
                if self.realtimeStatus == "Nicht verbunden" || self.realtimeStatus == "Verbindung pausiert" {
                    self.realtime?.connect(session: valid)
                }
                await self.loadConversations()
                guard self.epoch == revision, !Task.isCancelled, self.selectedConversation?.id == selectedID,
                      let selected = self.selectedConversation else { return }
                await self.loadMessages(for: selected)
            } catch {
                guard self.epoch == revision, !Task.isCancelled else { return }
                self.handle(error)
            }
        }
    }

    private func apply(_ mutation: RealtimeMutation) {
        guard authState == .signedIn, mutation.table == "messages" else { return }
        if mutation.operation == "DELETE", let old = mutation.old_record, let id = old.id {
            messages.removeAll { $0.id == id }
            return
        }
        guard let row = mutation.record else { return }
        guard conversations.contains(where: { $0.id == row.channel_id }) else { return }
        do {
            let message = try row.message(profiles: profiles)
            if selectedConversation?.id == row.channel_id { messages = Self.merged(messages + [message]) }
            if let index = conversations.firstIndex(where: { $0.id == row.channel_id }) {
                conversations[index].lastMessage = message.content
                if mutation.operation == "INSERT", seenRealtimeInserts.insert(row.id).inserted,
                   selectedConversation?.id != row.channel_id, row.author_id != user?.id { conversations[index].unreadCount += 1 }
            }
            if seenRealtimeInserts.count > 5000 { seenRealtimeInserts = [row.id] }
        } catch { realtimeStatus = "Live-Nachricht konnte nicht gelesen werden. Bitte Chat aktualisieren." }
    }

    private static func merged(_ messages: [ChatMessage]) -> [ChatMessage] {
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    #if DEBUG
    static func fixture(signedIn: Bool = true) -> NativeStore {
        let api = NativeAPI(transport: { _ in throw NativeClientError.invalidEndpoint })
        let store = NativeStore(api: api, vault: MemorySessionVault(), realtime: nil)
        store.isFixture = true
        if signedIn { store.populateFixture() }
        return store
    }

    private func populateFixture() {
        let selfUser = YapperUser(id: "fixture-self", username: "yapper-demo", displayName: "Yapper Demo", presence: "online", bio: "Native iOS-Vorschau mit synthetischen Beispieldaten.")
        let friend = YapperUser(id: "fixture-friend", username: "nova", displayName: "Nova", presence: "online")
        let other = YapperUser(id: "fixture-other", username: "milo", displayName: "Milo", presence: "idle")
        user = selfUser
        profiles = [selfUser.id: selfUser, friend.id: friend, other.id: other]
        conversations = [Conversation(id: "fixture-chat", title: "Nova", participants: [friend], lastMessage: "Das läuft jetzt direkt in SwiftUI.", unreadCount: 2),
                         Conversation(id: "fixture-group", title: "Yapper iOS", participants: [friend, other], lastMessage: "Willkommen im nativen Client!", isGroup: true),
                         Conversation(id: "fixture-milo", title: "Milo", participants: [other], lastMessage: "Bis später 👋")]
        authState = .signedIn
        realtimeStatus = "Demo · keine Serververbindung"
        errorMessage = nil
    }

    private static func fixtureMessages(conversationID: String, selfUser: YapperUser) -> [ChatMessage] {
        let friend = YapperUser(id: "fixture-friend", username: "nova", displayName: "Nova", presence: "online")
        let date = Date(timeIntervalSince1970: 1_793_360_000)
        return [ChatMessage(id: "fixture-message-1", channelID: conversationID, author: friend, content: "Hey! Wie sieht die native App aus?", createdAt: date, attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-2", channelID: conversationID, author: selfUser, content: "Chats, Profile und Tastatur sind jetzt echte iOS-Oberflächen.", createdAt: date.addingTimeInterval(60), attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-3", channelID: conversationID, author: friend, content: "Das läuft jetzt direkt in SwiftUI.", createdAt: date.addingTimeInterval(120), attachments: [], isEdited: false)]
    }
    #endif
}
