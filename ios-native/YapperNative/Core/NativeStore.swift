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
    private(set) var capabilities = NativeCapabilities()
    var messagePolicy: NativeMessagePolicy { NativeMessagePolicy(user: user, capabilities: capabilities) }
    var messageCharacterLimit: Int { messagePolicy.maximumLength(for: user?.id, at: now()) }
    var drafts: [String: String] = [:]
    private(set) var realtimeStatus = "Nicht verbunden"
    private(set) var typingUsers: [String: [YapperUser]] = [:]
    private(set) var incomingCall: NativeIncomingCall?
    private(set) var activeCallChannels: Set<String> = []
    @ObservationIgnored private var callExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var typingExpiry: [String: [String: Date]] = [:]
    @ObservationIgnored private var typingTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastTypingSent: [String: Date] = [:]

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
    @ObservationIgnored private var notificationSound = NativeNotificationSound()
    @ObservationIgnored private var notificationPolicy: NativeNotificationSoundPolicy?
    @ObservationIgnored private var notificationPolicyAt: Date?
    @ObservationIgnored private var notificationPreferences: NativeConversationPreferenceSnapshot?
    @ObservationIgnored private var refreshingNotificationPolicy = false
    @ObservationIgnored private var profiles: [String: YapperUser] = [:]
    @ObservationIgnored private var pendingSendIDs: [String: (text: String, id: String)] = [:]
    @ObservationIgnored private var oldestMessageCursor: String?
    @ObservationIgnored private var didExplicitlySignOut = false
    @ObservationIgnored private var browserFlowID: UUID?
    @ObservationIgnored private var browserTask: Task<BrowserLoginResult, Never>?
    @ObservationIgnored private var browserOperationID: UUID?
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
        realtime?.onEvent = { [weak self] event, payload in self?.applyEvent(event, payload: payload) }
    }

    func setDraft(_ text: String, for conversationID: String) { drafts[conversationID] = text }

    /// All feature services share token refresh and the same logout/account boundary.
    func withAuthenticatedSession<T: Sendable>(_ operation: @MainActor (NativeAPI, NativeSession) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard authState == .signedIn else { throw NativeClientError.missingSession }
        let revision = epoch
        do {
            let valid = try await validSession(revision: revision)
            guard epoch == revision, authState == .signedIn else { throw CancellationError() }
            try Task.checkCancellation()
            let result = try await NativeAuthenticationContext.$check.withValue({ [weak self] in
                guard let self, self.epoch == revision, self.authState == .signedIn else { throw CancellationError() }
                try Task.checkCancellation()
            }) {
                try await operation(api, valid)
            }
            guard epoch == revision, authState == .signedIn else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        } catch {
            guard epoch == revision else { throw CancellationError() }
            if error as? NativeClientError == .sessionExpired { handle(error) }
            else if case let NativeClientError.api(status, _) = error, status == 401 { handle(error) }
            throw error
        }
    }

    func refreshOwnProfile() async {
        #if DEBUG
        if isFixture { return }
        #endif
        do {
            let profile = try await withAuthenticatedSession { api, session in
                try await api.profile(id: session.userID, session: session)
            }
            guard profile.id == user?.id else { return }
            let fresh = profile.user()
            profiles[fresh.id] = fresh
            user = fresh
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    func verifyNativeSecurityFactor(factorID: String, code: String) async throws {
        let revision = epoch
        let fresh = try await withAuthenticatedSession { api, session in
            let verified = try await api.verifyTOTP(factorID: factorID, code: code, session: session)
            guard verified.userID == session.userID else { throw NativeClientError.invalidResponse }
            return verified
        }
        guard epoch == revision, authState == .signedIn, user?.id == fresh.userID else { throw CancellationError() }
        try vault.save(fresh)
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        session = fresh
        if isActive { realtime?.connect(session: fresh) }
    }

    func focusMessage(id: String, in conversation: Conversation) async -> Bool {
        guard authState == .signedIn, selectedConversation?.id == conversation.id else { return false }
        if messages.contains(where: { $0.id == id && $0.channelID == conversation.id }) { return true }
        let revision = epoch
        historyRevision += 1
        let historyID = historyRevision
        historyTask?.cancel()
        isLoadingMessages = true
        defer { if epoch == revision, historyRevision == historyID { isLoadingMessages = false } }
        do {
            let context = try await withAuthenticatedSession { api, session in
                let body = try JSONEncoder().encode(["cid": conversation.id, "mid": id])
                return try await api.response(MessageContextResponse.self, request: api.request(path: "rest/v1/rpc/channel_messages_around", method: "POST", token: session.accessToken, body: body))
            }
            guard epoch == revision, historyRevision == historyID, selectedConversation?.id == conversation.id else { return false }
            guard context.found, let rows = context.messages, rows.contains(where: { $0.id == id }), rows.allSatisfy({ $0.channel_id == conversation.id }) else {
                throw NativeClientError.api(status: 404, message: "Diese Nachricht ist nicht mehr verfügbar.")
            }
            var profiles = profiles
            for profile in context.profiles ?? [] { profiles[profile.id] = profile.user() }
            let displayed = try rows.map { try $0.message(profiles: profiles) }
            self.profiles = profiles
            messages = Self.merged(displayed)
            oldestMessageCursor = rows.min { $0.created_at < $1.created_at }?.created_at
            hasMoreMessages = rows.count >= 50
            return true
        } catch is CancellationError { return false }
        catch {
            if epoch == revision, historyRevision == historyID { errorMessage = error.localizedDescription }
            return false
        }
    }

    func noteTyping(in conversation: Conversation) {
        guard authState == .signedIn, UUID(uuidString: conversation.id) != nil,
              now().timeIntervalSince(lastTypingSent[conversation.id] ?? .distantPast) >= 3 else { return }
        lastTypingSent[conversation.id] = now()
        realtime?.typing(channelID: conversation.id, recipients: conversation.serverID == nil ? conversation.participants.map(\.id) : nil)
    }

    func markConversationRead(_ conversation: Conversation) async {
        #if DEBUG
        if isFixture { return }
        #endif
        do {
            _ = try await withAuthenticatedSession { api, session in
                try await api.rpc("mark_read", arguments: ["cid": .string(conversation.id)], session: session)
            }
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index].unreadCount = 0 }
            realtime?.read(channelID: conversation.id)
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    private func applyEvent(_ event: String, payload: NativeJSON) {
        guard authState == .signedIn else { return }
        if event == "call" {
            applyCall(payload["record"])
            return
        }
        if event == "typing", let channel = payload["channel_id"].string, let uid = payload["uid"].string, uid != user?.id {
            guard channel == selectedConversation?.id else { return }
            typingExpiry[channel, default: [:]][uid] = now().addingTimeInterval(6)
            let people = selectedConversation?.participants ?? []
            typingUsers[channel] = typingExpiry[channel, default: [:]].keys.map { id in profiles[id] ?? people.first(where: { $0.id == id }) ?? YapperUser(id: id, username: "Jemand") }
            typingTasks[channel]?.cancel()
            let revision = epoch
            typingTasks[channel] = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.epoch == revision else { return }
                    self.typingExpiry[channel] = self.typingExpiry[channel, default: [:]].filter { $0.value > self.now() }
                    let ids = Set(self.typingExpiry[channel, default: [:]].keys)
                    self.typingUsers[channel]?.removeAll { !ids.contains($0.id) }
                    if ids.isEmpty { self.typingTasks.removeValue(forKey: channel); return }
                }
            }
        }
    }

    func dismissIncomingCall() { incomingCall = nil; callExpiryTask?.cancel(); callExpiryTask = nil }

    private func applyCall(_ record: NativeJSON) {
        guard let channel = record["channel_id"].string else { return }
        if record["ended_at"].string != nil {
            activeCallChannels.remove(channel)
            if incomingCall?.channelID == channel { dismissIncomingCall() }
            return
        }
        activeCallChannels.insert(channel)
        if record["answered_at"].string != nil {
            if incomingCall?.channelID == channel { dismissIncomingCall() }
            return
        }
        guard let caller = record["started_by"].string, caller != user?.id,
              let date = record["started_at"].string.flatMap({ try? NativeDate.parse($0) }),
              (-30..<30).contains(now().timeIntervalSince(date)),
              let conversation = conversations.first(where: { $0.id == channel }) else { return }
        incomingCall = NativeIncomingCall(channelID: channel, fromUserID: caller, title: conversation.title, startedAt: date)
        callExpiryTask?.cancel()
        let revision = epoch
        let remaining = max(1, 30 - now().timeIntervalSince(date))
        callExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.epoch == revision, self.incomingCall?.channelID == channel else { return }
            self.incomingCall = nil
        }
    }

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

    func beginBrowserSignIn() -> UUID? {
        guard authState != .signedIn else { return nil }
        epoch += 1
        authTask?.cancel()
        browserTask?.cancel()
        browserTask = nil
        browserOperationID = nil
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        pendingFactor = nil
        session = nil
        errorMessage = nil
        authState = .signedOut
        let flow = UUID()
        browserFlowID = flow
        return flow
    }

    func cancelBrowserSignIn(flowID: UUID) {
        guard browserFlowID == flowID else { return }
        epoch += 1
        browserFlowID = nil
        browserTask?.cancel()
        browserTask = nil
        browserOperationID = nil
        session = nil
        pendingFactor = nil
        if authState != .signedIn { authState = .signedOut }
    }

    func pauseBrowserSignIn(flowID: UUID) {
        guard browserFlowID == flowID else { return }
        epoch += 1
        browserTask?.cancel()
        browserTask = nil
        browserOperationID = nil
        session = nil
        pendingFactor = nil
        if authState != .signedIn { authState = .signedOut }
    }

    func completeBrowserSignIn(tokens: BrowserLoginTokens, flowID: UUID) async -> BrowserLoginResult {
        guard browserFlowID == flowID, authState != .signedIn, isActive, browserTask == nil else { return .rejected }
        #if DEBUG
        if isFixture { return .rejected }
        #endif
        let revision = epoch
        let operation = UUID()
        browserOperationID = operation
        errorMessage = nil
        authState = .signingIn
        let task = Task { [weak self] () -> BrowserLoginResult in
            guard let self else { return .rejected }
            do {
                let validation = try await self.api.validateBrowserLogin(tokens)
                guard self.browserFlowID == flowID, self.epoch == revision, self.isActive, !Task.isCancelled else { return .rejected }
                if validation.requiresTwoFactor {
                    self.authState = .signedOut
                    return .requiresTwoFactor
                }
                try await self.finishAuthentication(validation.session, revision: revision, browserFlow: flowID)
                self.browserFlowID = nil
                return .signedIn
            } catch {
                guard self.browserFlowID == flowID, self.epoch == revision, !Task.isCancelled else { return .rejected }
                self.authState = .signedOut
                self.errorMessage = error.localizedDescription
                return .rejected
            }
        }
        browserTask = task
        let result = await task.value
        if browserOperationID == operation { browserTask = nil; browserOperationID = nil }
        return result
    }

    #if DEBUG
    func completeBrowserFixture(flowID: UUID) -> Bool {
        guard isFixture, browserFlowID == flowID, authState != .signedIn else { return false }
        browserFlowID = nil
        populateFixture()
        return true
    }
    #endif

    private func finishAuthentication(_ tokens: NativeSession, revision: Int, browserFlow: UUID? = nil) async throws {
        let bootstrap = try await api.bootstrap(session: tokens)
        let profile: ProfileRow
        if let found = bootstrap.profiles.first(where: { $0.id == tokens.userID }) { profile = found }
        else { profile = try await api.profile(id: tokens.userID, session: tokens) }
        let list = try bootstrap.conversations(currentUserID: tokens.userID)
        try Task.checkCancellation()
        guard epoch == revision else { throw CancellationError() }
        if let browserFlow { guard browserFlowID == browserFlow, isActive else { throw CancellationError() } }
        try vault.save(tokens)
        session = tokens
        didExplicitlySignOut = false
        user = profile.user()
        capabilities = bootstrap.capabilities
        activeCallChannels = bootstrap.activeCallChannels(now: now())
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
                if let own = data.profiles.first(where: { $0.id == valid.userID }) { self.user = own.user() }
                self.conversations = list
                self.capabilities = data.capabilities
                self.activeCallChannels = data.activeCallChannels(now: self.now())
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
        realtime?.observe(channelID: conversation.id, serverID: conversation.serverID)
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
        guard trimmed.utf16.count <= messageCharacterLimit else { errorMessage = NativeClientError.messageTooLong.localizedDescription; return false }
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
                let row = try await self.api.send(id: sendID, text: trimmed, channelID: conversation.id, session: valid, messagePolicy: self.messagePolicy)
                guard row.id == sendID, row.channel_id == conversation.id, row.author_id == valid.userID else { throw NativeClientError.invalidResponse }
                let message = try row.message(profiles: self.profiles)
                try Task.checkCancellation()
                guard self.epoch == revision else { return false }
                if self.selectedConversation?.id == conversation.id { self.messages = Self.merged(self.messages + [message]) }
                if self.drafts[conversation.id] == text { self.drafts[conversation.id] = "" }
                self.pendingSendIDs[conversation.id] = nil
                if let index = self.conversations.firstIndex(where: { $0.id == conversation.id }) {
                    self.conversations[index].lastMessage = trimmed
                    self.conversations[index].lastMessageAt = max(self.conversations[index].lastMessageAt ?? .distantPast, message.createdAt)
                }
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

    private var notificationMutedIDs: Set<String>? {
        notificationPreferences.map { snapshot in
            Set(snapshot.muted.filter { snapshot.muteUntil[$0].map { $0 > now() } ?? true }).union(snapshot.hidden)
        }
    }

    func updateNotificationPreferences(_ snapshot: NativeConversationPreferenceSnapshot?) {
        notificationPreferences = snapshot
        if let policy = notificationPolicy, let muted = notificationMutedIDs {
            notificationPolicy = NativeNotificationSoundPolicy(ownerID: policy.ownerID, status: policy.status, blockedIDs: policy.blockedIDs, mutedIDs: muted)
        } else { notificationPolicy = nil }
    }

    func refreshNotificationSoundContext() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard !refreshingNotificationPolicy, authState == .signedIn, let ownerID = user?.id,
              let muted = notificationMutedIDs else { return }
        let revision = epoch
        refreshingNotificationPolicy = true
        defer { if epoch == revision { refreshingNotificationPolicy = false } }
        do {
            let policy = try await withAuthenticatedSession { api, session in try await api.nativeNotificationSoundPolicy(mutedIDs: muted, session: session) }
            guard epoch == revision, !Task.isCancelled, user?.id == ownerID, policy.ownerID == ownerID,
                  let currentMuted = notificationMutedIDs else { return }
            notificationPolicy = NativeNotificationSoundPolicy(ownerID: ownerID, status: policy.status, blockedIDs: policy.blockedIDs, mutedIDs: currentMuted)
            notificationPolicyAt = now()
            user?.presence = policy.status
        } catch { if epoch == revision { notificationPolicy = nil; notificationPolicyAt = nil } }
    }

    private func soundForUnreadDM(_ message: ChatMessage) {
        guard authState == .signedIn, isActive, message.author.id != user?.id,
              selectedConversation?.id != message.channelID,
              conversations.contains(where: { $0.id == message.channelID && $0.serverID == nil }),
              notificationMutedIDs != nil else { return }
        let revision = epoch
        Task { [weak self] in
            guard let self, self.epoch == revision else { return }
            if self.notificationPolicyAt.map({ self.now().timeIntervalSince($0) >= 60 }) ?? true { await self.refreshNotificationSoundContext() }
            guard self.epoch == revision, self.authState == .signedIn, let userID = self.user?.id,
                  let policy = self.notificationPolicy else { return }
            let effective = NativeNotificationSoundPolicy(ownerID: policy.ownerID, status: policy.status, blockedIDs: policy.blockedIDs, mutedIDs: self.notificationMutedIDs ?? policy.mutedIDs)
            self.notificationSound.receive(message: message, currentUserID: userID, currentConversationID: self.selectedConversation?.id, isActive: self.isActive, policy: effective)
        }
    }

    func signOut() {
        notificationSound.reset(); notificationPolicy = nil; notificationPolicyAt = nil; notificationPreferences = nil; refreshingNotificationPolicy = false
        capabilities = NativeCapabilities()
        dismissIncomingCall()
        activeCallChannels = []
        for task in typingTasks.values { task.cancel() }
        typingTasks = [:]
        typingUsers = [:]
        typingExpiry = [:]
        lastTypingSent = [:]
        epoch += 1
        didExplicitlySignOut = true
        authTask?.cancel()
        browserFlowID = nil
        browserTask?.cancel()
        browserTask = nil
        browserOperationID = nil
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
        guard conversations.contains(where: { $0.id == row.channel_id }) || selectedConversation?.id == row.channel_id else { return }
        do {
            let message = try row.message(profiles: profiles)
            if selectedConversation?.id == row.channel_id { messages = Self.merged(messages + [message]) }
            if let index = conversations.firstIndex(where: { $0.id == row.channel_id }) {
                conversations[index].lastMessage = message.content
                if mutation.operation == "INSERT" {
                    conversations[index].lastMessageAt = max(conversations[index].lastMessageAt ?? .distantPast, message.createdAt)
                }
                if mutation.operation == "INSERT", seenRealtimeInserts.insert(row.id).inserted,
                   selectedConversation?.id != row.channel_id, row.author_id != user?.id {
                    conversations[index].unreadCount += 1
                    soundForUnreadDM(message)
                }
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
        let selfUser = YapperUser(id: "11111111-1111-4111-8111-111111111111", username: "yapper-demo", displayName: "Yapper Demo", presence: "online", bio: "Native iOS-Vorschau mit synthetischen Beispieldaten.")
        let friend = YapperUser(id: "33333333-3333-4333-8333-333333333333", username: "nova", displayName: "Nova", presence: "online")
        let other = YapperUser(id: "44444444-4444-4444-8444-444444444444", username: "milo", displayName: "Milo", presence: "idle")
        user = selfUser
        // Explicit anonymous fixture rollout, matching the offline original-React comparison.
        capabilities = NativeCapabilities(flags: .object(Dictionary(uniqueKeysWithValues:
            ["calls", "user_search", "mentions_inbox", "mobile_nav", "ui_panel", "ui_refresh", "voice_messages"].map { ($0, .object(["mode": .string("everyone")])) }
        )))
        profiles = [selfUser.id: selfUser, friend.id: friend, other.id: other]
        conversations = [Conversation(id: "fixture-chat", title: "Nova", participants: [friend], lastMessage: "Das läuft jetzt direkt in SwiftUI.", unreadCount: 2, lastMessageAt: Date()),
                         Conversation(id: "fixture-group", title: "Yapper iOS", participants: [friend, other], lastMessage: "Willkommen im nativen Client!", isGroup: true),
                         Conversation(id: "fixture-milo", title: "Milo", participants: [other], lastMessage: "Bis später 👋")]
        authState = .signedIn
        realtimeStatus = "Demo · keine Serververbindung"
        errorMessage = nil
    }

    private static func fixtureMessages(conversationID: String, selfUser: YapperUser) -> [ChatMessage] {
        let friend = YapperUser(id: "33333333-3333-4333-8333-333333333333", username: "nova", displayName: "Nova", presence: "online")
        let date = Date(timeIntervalSince1970: 1_793_360_000)
        return [ChatMessage(id: "fixture-message-1", channelID: conversationID, author: friend, content: "Hey! Wie sieht die native App aus?", createdAt: date, attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-2", channelID: conversationID, author: selfUser, content: "Chats, Profile und Tastatur sind jetzt echte iOS-Oberflächen.", createdAt: date.addingTimeInterval(60), attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-3", channelID: conversationID, author: friend, content: "Das läuft jetzt direkt in SwiftUI.", createdAt: date.addingTimeInterval(120), attachments: [], isEdited: false)]
    }
    #endif
}
