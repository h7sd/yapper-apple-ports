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
    private(set) var peerPresenceByID: [String: String] = [:]
    private(set) var channelUnread: [String: NativeChannelUnread] = [:]
    private(set) var channelServerIDs: [String: String] = [:]
    private(set) var voiceMembers: [String: [NativeVoiceMember]] = [:]
    private(set) var latestIncomingMention: NativeIncomingMention?
    private(set) var liveProfileRevision = 0
    @ObservationIgnored private var liveServerID: String?
    @ObservationIgnored private var liveServerMemberIDs: [String: Set<String>] = [:]
    @ObservationIgnored private var ownServerRoleIDs: [String: Set<String>] = [:]
    @ObservationIgnored private var unreadRevisions: [String: Int] = [:]
    @ObservationIgnored private var readRevisions: [String: Int] = [:]
    @ObservationIgnored private var liveMessageBadges: [String: (channelID: String, mentioned: Bool)] = [:]
    @ObservationIgnored private var liveScopeTask: Task<Void, Never>?
    @ObservationIgnored private var peerPresenceRevision = 0
    @ObservationIgnored private var peerPresenceEventRevision = 0
    @ObservationIgnored private var unreadFetchRevision = 0
    @ObservationIgnored private var pendingLiveProfileIDs: Set<String> = []
    @ObservationIgnored private var voiceServerChannelIDs: [String: Set<String>] = [:]
    @ObservationIgnored private var mappedUnreadServerIDs: Set<String> = []
    @ObservationIgnored private var unreadRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var serverNotificationContext: NativeServerNotificationState?
    @ObservationIgnored private var readLiveMessageIDs: Set<String> = []
    @ObservationIgnored private var readLiveMessageOrder: [String] = []
    @ObservationIgnored private var pendingMentionCandidates: [String: (channelID: String, authorID: String)] = [:]
    @ObservationIgnored private var shownMentionNoticeIDs: Set<String> = []
    @ObservationIgnored private var mentionLookupTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastMentionNoticeAt: Date?
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
    @ObservationIgnored private var historyDeletedIDs: Set<String> = []
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
    @ObservationIgnored private var ownPresencePreference: NativeOwnPresencePreference?
    @ObservationIgnored private var presenceRevision = 0
    @ObservationIgnored private var ownPresenceCommitRevision = 0
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
        realtime?.onPresence = { [weak self] snapshot in self?.applyPeerPresence(snapshot) }
        realtime?.onConnectionLost = { [weak self] in
            self?.peerPresenceByID = [:]
            self?.voiceMembers = [:]
        }
    }

    func setDraft(_ text: String, for conversationID: String) { drafts[conversationID] = text }

    func peerPresence(userID: String) -> String {
        if userID == user?.id { return user?.presence == "invisible" ? "offline" : user?.presence ?? "unknown" }
        return peerPresenceByID[userID.lowercased()] ?? "unknown"
    }

    func userWithLivePresence(_ user: YapperUser) -> YapperUser {
        var updated = user
        let current = peerPresence(userID: user.id)
        if current != "unknown" { updated.presence = current }
        return updated
    }

    func knownUser(id: String) -> YapperUser? {
        _ = liveProfileRevision
        let key = id.lowercased()
        return profiles[key].map(userWithLivePresence) ?? conversations.lazy.flatMap(\.participants).first(where: { $0.id == key }).map(userWithLivePresence)
    }

    func unreadCount(inChannel id: String) -> Int { channelUnread[id]?.unread ?? conversations.first(where: { $0.id == id })?.unreadCount ?? 0 }
    func mentionCount(inChannel id: String) -> Int { channelUnread[id]?.mentions ?? 0 }
    func unreadCount(channelID: String) -> Int { unreadCount(inChannel: channelID) }
    func mentionCount(channelID: String) -> Int { mentionCount(inChannel: channelID) }
    func unreadCount(inServer id: String) -> Int { channelServerIDs.filter { $0.value == id }.keys.reduce(0) { $0 + unreadCount(inChannel: $1) } }
    func mentionCount(inServer id: String) -> Int { channelServerIDs.filter { $0.value == id }.keys.reduce(0) { $0 + mentionCount(inChannel: $1) } }
    func dismissIncomingMention() { latestIncomingMention = nil }
    func updateServerNotificationContext(_ state: NativeServerNotificationState?) {
        serverNotificationContext = state
        if let notice = latestIncomingMention, let sid = notice.serverID,
           state == nil || state?.isMuted(sid, now: now()) == true || state?.isMuted(notice.channelID, now: now()) == true {
            latestIncomingMention = nil
        }
    }

    func observeServer(id: String?, channelIDs: [String] = [], members: [YapperUser] = []) {
        if let id {
            guard UUID(uuidString: id) != nil || id.hasPrefix("fixture-") else { return }
            for channel in channelIDs { channelServerIDs[channel] = id }
            liveServerMemberIDs[id] = Set(members.map(\.id))
            if UUID(uuidString: id) != nil { capabilities.joinedServerIDs.insert(id); realtime?.observeServers(capabilities.joinedServerIDs) }
            for person in members { profiles[person.id] = person }
            liveProfileRevision += 1
        }
        liveServerID = id
        updatePresenceSubscription()
        liveScopeTask?.cancel()
        liveScopeTask = Task { [weak self] in await self?.refreshPeerPresence() }
    }

    func registerServerRoles(serverID: String, ownRoleIDs: Set<String>) { ownServerRoleIDs[serverID] = ownRoleIDs }

    /// Feed only the server list already returned for this authenticated account.
    func observeJoinedServers(_ ids: Set<String>) {
        guard authState == .signedIn, ids.allSatisfy({ UUID(uuidString: $0) != nil || $0.hasPrefix("fixture-") }) else { return }
        let departed = capabilities.joinedServerIDs.subtracting(ids)
        let departedChannels = Set(channelServerIDs.filter { departed.contains($0.value) }.keys)
        for channel in departedChannels { channelUnread.removeValue(forKey: channel); voiceMembers.removeValue(forKey: channel) }
        channelServerIDs = channelServerIDs.filter { !departed.contains($0.value) }
        capabilities.joinedServerIDs = ids
        realtime?.observeServers(ids)
        if !departed.isEmpty { latestIncomingMention = nil }
    }

    func messageMentionsCurrentUser(_ message: ChatMessage) -> Bool {
        guard let uid = user?.id else { return false }
        let sid = channelServerIDs[message.channelID]
        let roles = sid.flatMap { capabilities.flagOn("role_mentions", userID: uid, serverID: $0) ? ownServerRoleIDs[$0] : nil } ?? []
        if message.mentions.includes(userID: uid, roleIDs: roles) { return true }
        return !message.mentions.isForwarded && message.grouping.replyToID.flatMap { replyID in
            messages.first(where: { $0.id == replyID && $0.channelID == message.channelID })?.author.id
        } == uid
    }

    /// Refresh optional live context separately from loading chat history.
    func refreshLiveState() async {
        #if DEBUG
        if isFixture { return }
        #endif
        async let presence: Void = refreshPeerPresence()
        async let unread: Void = refreshUnreadState()
        _ = await (presence, unread)
    }

    func loadMentionMessages() async throws -> [ChatMessage] {
        #if DEBUG
        if isFixture, let user {
            return Self.fixtureMessages(conversationID: NativeServerFixtures.textChannelID, selfUser: user).filter { $0.mentions.includes(userID: user.id) }
        }
        #endif
        let account = epoch
        let rows = try await withAuthenticatedSession { api, session in
            try await api.nativeMentionMessages(useV2: self.capabilities.flagOn("mentions_v2", userID: session.userID), session: session)
        }
        await hydrateLiveProfiles(ids: rows.compactMap(\.author_id) + rows.flatMap { Array(NativeMessageMentions(content: $0.content ?? "").userIDs) })
        guard epoch == account, authState == .signedIn, !Task.isCancelled else { throw CancellationError() }
        return try rows.map { try $0.message(profiles: profiles) }
    }

    private var presenceExtraIDs: [String] { Array(Set(conversations.flatMap { $0.participants.map(\.id) })).sorted() }
    private func updatePresenceSubscription() { realtime?.observePresence(ids: presenceExtraIDs, serverID: liveServerID) }

    private func refreshPeerPresence() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard authState == .signedIn, !Task.isCancelled else { return }
        let account = epoch
        peerPresenceRevision += 1
        let revision = peerPresenceRevision
        let sid = liveServerID
        let ids = presenceExtraIDs
        let eventRevision = peerPresenceEventRevision
        do {
            let snapshot = try await withAuthenticatedSession { api, session in
                try await api.nativePeerPresence(serverID: sid, extraIDs: ids, session: session)
            }
            guard epoch == account, revision == peerPresenceRevision, peerPresenceEventRevision == eventRevision,
                  liveServerID == sid, !Task.isCancelled else { return }
            applyPeerPresence(snapshot)
        } catch { /* Optional presence failures do not interrupt a conversation or invent Online. */ }
    }

    func applyPeerPresence(_ snapshot: NativePeerPresenceSnapshot) {
        guard authState == .signedIn, snapshot.serverID == nil || snapshot.serverID == liveServerID else { return }
        peerPresenceEventRevision += 1
        if snapshot.full {
            let scoped = Set(presenceExtraIDs).union(snapshot.serverID.flatMap { liveServerMemberIDs[$0] } ?? [])
            for id in scoped where id != user?.id { peerPresenceByID[id] = "offline" }
        }
        for (id, status) in snapshot.statuses where id != user?.id { peerPresenceByID[id] = status }
    }

    private func refreshUnreadState() async {
        guard authState == .signedIn, !Task.isCancelled else { return }
        let account = epoch
        unreadFetchRevision += 1
        let fetchID = unreadFetchRevision
        let baseline = unreadRevisions
        do {
            let counts = try await withAuthenticatedSession { api, session in try await api.nativeUnreadCounts(session: session) }
            guard epoch == account, fetchID == unreadFetchRevision, !Task.isCancelled else { return }
            applyUnreadSnapshot(counts, baseline: baseline, clearMissing: true)
            await resolvePendingMentionCandidates()
        } catch { /* Keep existing badges when an optional counts request fails. */ }
        guard epoch == account, !Task.isCancelled else { return }
        do {
            let servers = capabilities.joinedServerIDs
            guard servers != mappedUnreadServerIDs else { return }
            let mapping = try await withAuthenticatedSession { api, session in try await api.nativeChannelServerMap(serverIDs: servers, session: session) }
            guard epoch == account, fetchID == unreadFetchRevision, !Task.isCancelled else { return }
            channelServerIDs = mapping.merging(channelServerIDs) { remote, _ in remote }
            mappedUnreadServerIDs = servers
        } catch { /* Visible snapshots can also contribute their authorized channel mapping. */ }
    }

    private func applyUnreadSnapshot(_ counts: [String: NativeChannelUnread], baseline: [String: Int], clearMissing: Bool) {
        let keys = clearMissing ? Set(channelUnread.keys).union(counts.keys) : Set(counts.keys)
        for id in keys where unreadRevisions[id, default: 0] == baseline[id, default: 0] {
            channelUnread[id] = counts[id] ?? NativeChannelUnread()
        }
        for index in conversations.indices { conversations[index].unreadCount = unreadCount(inChannel: conversations[index].id) }
    }

    private func applyBootstrapUnread(_ rows: [UnreadRow]?, baseline: [String: Int]) {
        var counts: [String: NativeChannelUnread] = [:]
        for row in rows ?? [] where row.unread >= 0 {
            guard let id = UUID(uuidString: row.channel_id)?.uuidString.lowercased() else { continue }
            counts[id] = NativeChannelUnread(unread: row.unread, mentions: row.mentions ?? 0, muted: row.muted ?? false)
        }
        applyUnreadSnapshot(counts, baseline: baseline, clearMissing: false)
    }

    private func hydrateLiveProfiles(ids: [String]) async {
        let requested = Set(ids.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() }).subtracting(profiles.keys).subtracting(pendingLiveProfileIDs)
        guard !requested.isEmpty, authState == .signedIn else { return }
        let account = epoch
        pendingLiveProfileIDs.formUnion(requested)
        defer { if epoch == account { pendingLiveProfileIDs.subtract(requested) } }
        do {
            let rows = try await withAuthenticatedSession { api, session in try await api.publicProfiles(ids: Array(requested.prefix(500)), session: session) }
            guard epoch == account, !Task.isCancelled else { return }
            for row in rows {
                let person = try NativeProfileDetail(row: row).user
                profiles[person.id] = person
            }
            liveProfileRevision += 1
        } catch { /* Missing/deleted mention targets retain the visible fallback. */ }
    }

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
            let fresh = preservingOwnPresence(profile.user())
            profiles[fresh.id] = fresh
            user = fresh
            await refreshOwnPresence()
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    /// Own status is a separate account preference, independent of notification permissions.
    func refreshOwnPresence() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard authState == .signedIn, let ownerID = user?.id else { return }
        let accountRevision = epoch
        presenceRevision += 1
        let operation = presenceRevision
        let fallback = ownPresencePreference?.ownerID == ownerID ? ownPresencePreference?.preference : nil
        do {
            let preference = try await withAuthenticatedSession { api, session in
                try await api.nativeOwnPresencePreference(session: session, defaultPreference: fallback ?? .online)
            }
            guard epoch == accountRevision, presenceRevision == operation, !Task.isCancelled else { return }
            applyOwnPresence(preference)
        } catch is CancellationError { }
        catch { /* Retain a known preference; an unavailable read must not invent Online. */ }
    }

    func setOwnPresence(_ preference: NativePresencePreference) async throws {
        guard authState == .signedIn, let ownerID = user?.id else { throw NativeClientError.missingSession }
        let accountRevision = epoch
        presenceRevision += 1
        #if DEBUG
        if !isFixture {
            try await withAuthenticatedSession { api, session in try await api.setSocialPresence(preference.rawValue, session: session) }
        }
        #else
        try await withAuthenticatedSession { api, session in try await api.setSocialPresence(preference.rawValue, session: session) }
        #endif
        guard epoch == accountRevision, user?.id == ownerID else { throw CancellationError() }
        presenceRevision += 1
        applyOwnPresence(NativeOwnPresencePreference(ownerID: ownerID, preference: preference))
    }

    private func applyOwnPresence(_ preference: NativeOwnPresencePreference) {
        guard authState == .signedIn, user?.id == preference.ownerID else { return }
        ownPresencePreference = preference
        ownPresenceCommitRevision += 1
        realtime?.publishPresence(preference.preference)
        user?.presence = preference.status
        if let user { profiles[user.id] = user }
        if let policy = notificationPolicy, policy.ownerID == preference.ownerID {
            notificationPolicy = NativeNotificationSoundPolicy(ownerID: policy.ownerID, status: preference.status, blockedIDs: policy.blockedIDs, mutedIDs: policy.mutedIDs)
        }
    }

    private func preservingOwnPresence(_ profile: YapperUser) -> YapperUser {
        var profile = profile
        if let preference = ownPresencePreference, preference.ownerID == profile.id { profile.presence = preference.status }
        return profile
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
        historyDeletedIDs = []
        isLoadingMessages = true
        defer { if epoch == revision, historyRevision == historyID { isLoadingMessages = false; historyDeletedIDs = [] } }
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
            guard !historyDeletedIDs.contains(id) else { return false }
            let displayed = try rows.filter { !historyDeletedIDs.contains($0.id) }.map { try $0.message(profiles: profiles) }
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
        guard authState == .signedIn, selectedConversation?.id == conversation.id, !Task.isCancelled else { return }
        #if DEBUG
        if isFixture {
            if ProcessInfo.processInfo.arguments.contains("--native-ui-live-fixtures") { clearUnread(channelID: conversation.id) }
            return
        }
        #endif
        do {
            _ = try await withAuthenticatedSession { api, session in
                try await api.rpc("mark_read", arguments: ["cid": .string(conversation.id)], session: session)
            }
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) { conversations[index].unreadCount = 0 }
            clearUnread(channelID: conversation.id)
            realtime?.read(channelID: conversation.id)
        } catch is CancellationError { }
        catch { if selectedConversation?.id == conversation.id { errorMessage = error.localizedDescription } }
    }

    func applyEvent(_ event: String, payload: NativeJSON) {
        guard authState == .signedIn else { return }
        if event == "revoked" {
            for topic in payload["topics"].array.compactMap(\.string) {
                if topic.hasPrefix("server:") {
                    let sid = String(topic.dropFirst("server:".count))
                    let channels = Set(channelServerIDs.filter { $0.value == sid }.keys)
                    for channel in channels { channelUnread.removeValue(forKey: channel); voiceMembers.removeValue(forKey: channel) }
                    channelServerIDs = channelServerIDs.filter { $0.value != sid }
                    voiceServerChannelIDs.removeValue(forKey: sid)
                    if latestIncomingMention?.serverID == sid { latestIncomingMention = nil }
                }
            }
            return
        }
        if event == "read", let channel = payload["channel"].string {
            clearUnread(channelID: channel)
            return
        }
        if event == "voice" { applyVoiceMembers(payload); return }
        if event == "unread" {
            if let sid = payload["server_id"].string, capabilities.joinedServerIDs.contains(sid),
               let channel = payload["channel_id"].string, UUID(uuidString: channel) != nil {
                channelServerIDs[channel.lowercased()] = sid
            }
            if payload["operation"].string == "DELETE", let id = payload["id"].string {
                removeLiveUnread(messageID: id)
            } else if payload["operation"].string == "INSERT", let rawID = payload["id"].string,
                      let rawChannel = payload["channel_id"].string, let rawAuthor = payload["author_id"].string,
                      let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                      let channel = UUID(uuidString: rawChannel)?.uuidString.lowercased(),
                      let author = UUID(uuidString: rawAuthor)?.uuidString.lowercased(),
                      channelServerIDs[channel] != nil || conversations.contains(where: { $0.id == channel }) {
                let mention = payload["everyone"].bool == true || payload["here_to"].array.contains(.string(user?.id ?? ""))
                recordLiveUnread(messageID: id, channelID: channel, authorID: author, mentioned: mention)
                let recent = payload["created_at"].string.map { value in
                    (try? NativeDate.parse(value)).map { (-30...120).contains(now().timeIntervalSince($0)) } ?? false
                } ?? true
                if recent, mayPresentMention(channelID: channel, authorID: author), !readLiveMessageIDs.contains(id) {
                    pendingMentionCandidates[id] = (channel, author)
                    if pendingMentionCandidates.count > 5_000 { pendingMentionCandidates = [id: (channel, author)] }
                }
                if mention { fetchCompactMention(id: id, channelID: channel, authorID: author, createdAt: payload["created_at"].string) }
            }
            scheduleUnreadRefresh()
            return
        }
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

    private func clearUnread(channelID: String) {
        readRevisions[channelID, default: 0] += 1
        let readIDs = Array(liveMessageBadges.filter { $0.value.channelID == channelID }.keys) + messages.filter { $0.channelID == channelID }.map(\.id)
        for id in readIDs where readLiveMessageIDs.insert(id).inserted { readLiveMessageOrder.append(id) }
        if readLiveMessageOrder.count > 10_000 {
            let excess = readLiveMessageOrder.count - 10_000
            for id in readLiveMessageOrder.prefix(excess) { readLiveMessageIDs.remove(id) }
            readLiveMessageOrder.removeFirst(excess)
        }
        pendingMentionCandidates = pendingMentionCandidates.filter { $0.value.channelID != channelID }
        channelUnread[channelID] = NativeChannelUnread(muted: channelUnread[channelID]?.muted ?? false)
        unreadRevisions[channelID, default: 0] += 1
        liveMessageBadges = liveMessageBadges.filter { $0.value.channelID != channelID }
        if let index = conversations.firstIndex(where: { $0.id == channelID }) { conversations[index].unreadCount = 0 }
        if latestIncomingMention?.channelID == channelID { latestIncomingMention = nil }
    }

    private func mayPresentMention(channelID: String, authorID: String) -> Bool {
        guard authState == .signedIn, isActive, selectedConversation?.id != channelID, authorID != user?.id,
              let policy = currentNotificationSoundPolicy, policy.canDisturb,
              !policy.blockedIDs.contains(authorID), !policy.mutedIDs.contains(channelID),
              channelUnread[channelID]?.muted != true else { return false }
        if let sid = channelServerIDs[channelID] {
            guard let context = serverNotificationContext, !context.isMuted(sid, now: now()), !context.isMuted(channelID, now: now()),
                  (context.levels[channelID] ?? context.levels[sid]) != .some(.none) else { return false }
        }
        return true
    }

    private func fetchCompactMention(id: String, channelID: String, authorID: String, createdAt: String?) {
        guard mayPresentMention(channelID: channelID, authorID: authorID), !readLiveMessageIDs.contains(id),
              !shownMentionNoticeIDs.contains(id), mentionLookupTasks[id] == nil else { return }
        let expectedDate: Date?
        if let createdAt {
            guard let date = try? NativeDate.parse(createdAt), (-30...120).contains(now().timeIntervalSince(date)) else { return }
            guard lastMentionNoticeAt.map({ date >= $0 }) ?? true else { return }
            expectedDate = date
        } else { expectedDate = nil }
        let account = epoch
        let readRevision = readRevisions[channelID, default: 0]
        let navigationRevision = historyRevision
        mentionLookupTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == account { self.mentionLookupTasks.removeValue(forKey: id) } }
            do {
                guard let row = try await self.withAuthenticatedSession({ api, session in
                    try await api.nativeMentionMessage(id: id, channelID: channelID, authorID: authorID, session: session)
                }) else { return }
                let date = try NativeDate.parse(row.created_at)
                guard self.epoch == account, !Task.isCancelled, self.readRevisions[channelID, default: 0] == readRevision,
                      self.historyRevision == navigationRevision,
                      !self.readLiveMessageIDs.contains(id), (-30...120).contains(self.now().timeIntervalSince(date)),
                      expectedDate.map({ abs($0.timeIntervalSince(date)) < 0.001 }) ?? true,
                      self.mayPresentMention(channelID: channelID, authorID: authorID) else { return }
                await self.hydrateLiveProfiles(ids: [authorID] + Array(NativeMessageMentions(content: row.content ?? "").userIDs))
                guard self.epoch == account, !Task.isCancelled, self.readRevisions[channelID, default: 0] == readRevision,
                      self.historyRevision == navigationRevision else { return }
                let message = try row.message(profiles: self.profiles)
                self.showIncomingMentionIfAllowed(message)
            } catch { /* Read denied/deleted/stale rows do not become invented notifications. */ }
        }
    }

    private func scheduleUnreadRefresh() {
        #if DEBUG
        if isFixture { return }
        #endif
        guard unreadRefreshTask == nil else { return }
        let account = epoch
        unreadRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
            guard let self, self.epoch == account, !Task.isCancelled else { return }
            await self.refreshUnreadState()
            if self.epoch == account { self.unreadRefreshTask = nil }
        }
    }

    private func recordLiveUnread(messageID: String, channelID: String, authorID: String, mentioned: Bool) {
        guard authorID != user?.id, selectedConversation?.id != channelID, !readLiveMessageIDs.contains(messageID) else { return }
        if let previous = liveMessageBadges[messageID] {
            // A compact summary may arrive before the full content containing a direct/role ping.
            if mentioned && !previous.mentioned {
                if var counts = channelUnread[channelID] {
                    counts.mentions = min(counts.unread, min(100, counts.mentions + 1))
                    channelUnread[channelID] = counts
                }
                liveMessageBadges[messageID] = (channelID, true)
                unreadRevisions[channelID, default: 0] += 1
            }
            return
        }
        var counts = channelUnread[channelID] ?? NativeChannelUnread(unread: conversations.first(where: { $0.id == channelID })?.unreadCount ?? 0)
        counts.unread = min(100, counts.unread + 1)
        if mentioned { counts.mentions = min(100, counts.mentions + 1) }
        channelUnread[channelID] = counts
        liveMessageBadges[messageID] = (channelID, mentioned)
        unreadRevisions[channelID, default: 0] += 1
        if let index = conversations.firstIndex(where: { $0.id == channelID }) { conversations[index].unreadCount = counts.unread }
        if liveMessageBadges.count > 5_000 { liveMessageBadges = [messageID: (channelID, mentioned)] }
    }

    private func resolvePendingMentionCandidates() async {
        guard !pendingMentionCandidates.isEmpty else { return }
        let candidates = pendingMentionCandidates
        pendingMentionCandidates = [:]
        guard candidates.values.contains(where: { mentionCount(inChannel: $0.channelID) > 0 }) else { return }
        let account = epoch
        let navigationRevision = historyRevision
        do {
            let rows = try await withAuthenticatedSession { api, session in
                try await api.nativeMentionMessages(useV2: self.capabilities.flagOn("mentions_v2", userID: session.userID), session: session)
            }
            guard epoch == account, historyRevision == navigationRevision, !Task.isCancelled else { return }
            let matching = rows.filter { row in candidates[row.id.lowercased()].map { $0.channelID == row.channel_id.lowercased() && $0.authorID == row.author_id?.lowercased() } ?? false }
            await hydrateLiveProfiles(ids: matching.compactMap(\.author_id) + matching.flatMap { Array(NativeMessageMentions(content: $0.content ?? "").userIDs) })
            guard epoch == account, historyRevision == navigationRevision, !Task.isCancelled else { return }
            for row in matching.sorted(by: { $0.created_at < $1.created_at }) {
                let message = try row.message(profiles: profiles)
                guard (-30...120).contains(now().timeIntervalSince(message.createdAt)) else { continue }
                // This authenticated own-mentions feed proves recipient eligibility even if
                // the compact server event omitted the direct/role mention content.
                showIncomingMentionIfAllowed(message, verifiedRecipient: true)
            }
        } catch { /* Do not invent a content preview or a recipient if the authorized feed fails. */ }
    }

    private func removeLiveUnread(messageID: String) {
        guard let old = liveMessageBadges.removeValue(forKey: messageID) else { return }
        if var counts = channelUnread[old.channelID] {
            counts.unread = max(0, counts.unread - 1)
            if old.mentioned { counts.mentions = max(0, counts.mentions - 1) }
            channelUnread[old.channelID] = counts
            unreadRevisions[old.channelID, default: 0] += 1
            if let index = conversations.firstIndex(where: { $0.id == old.channelID }) { conversations[index].unreadCount = counts.unread }
        }
    }

    private func applyVoiceMembers(_ payload: NativeJSON) {
        guard let sid = payload["server_id"].string,
              capabilities.joinedServerIDs.contains(sid) || sid == liveServerID,
              case .array = payload["members"] else { return }
        var grouped: [String: [NativeVoiceMember]] = [:]
        var seen: Set<String> = []
        for row in payload["members"].array {
            guard let rawChannel = row["channel_id"].string, let rawUser = row["user_id"].string,
                  let channel = UUID(uuidString: rawChannel)?.uuidString.lowercased(),
                  let uid = UUID(uuidString: rawUser)?.uuidString.lowercased() else { return }
            guard seen.insert(uid).inserted else { continue }
            grouped[channel, default: []].append(NativeVoiceMember(userID: uid, muted: row["muted"].bool ?? false,
                deafened: row["deafened"].bool ?? false, sharing: row["sharing"].bool ?? false))
        }
        let oldChannels = voiceServerChannelIDs[sid] ?? []
        for channel in oldChannels { voiceMembers.removeValue(forKey: channel) }
        for (channel, members) in grouped {
            voiceMembers[channel] = members
            channelServerIDs[channel] = sid
        }
        voiceServerChannelIDs[sid] = Set(grouped.keys)
        let account = epoch
        Task { [weak self] in
            guard let self, self.epoch == account else { return }
            await self.hydrateLiveProfiles(ids: Array(seen))
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
        user = preservingOwnPresence(profile.user())
        capabilities = bootstrap.capabilities
        activeCallChannels = bootstrap.activeCallChannels(now: now())
        profiles = Dictionary(bootstrap.profiles.map { ($0.id, $0.user()) }, uniquingKeysWith: { _, new in new })
        profiles[tokens.userID] = user
        conversations = list
        applyBootstrapUnread(bootstrap.unread, baseline: unreadRevisions)
        pendingFactor = nil
        authState = .signedIn
        errorMessage = nil
        if isActive {
            realtime?.connect(session: tokens)
            realtime?.observeServers(capabilities.joinedServerIDs)
            updatePresenceSubscription()
            startMaintenance()
        }
    }

    func loadConversations() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard authState == .signedIn, !Task.isCancelled else { return }
        let revision = epoch
        listRevision += 1
        let listID = listRevision
        let unreadBaseline = unreadRevisions
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
                if let own = data.profiles.first(where: { $0.id == valid.userID }) {
                    self.user = self.preservingOwnPresence(own.user())
                    self.profiles[own.id] = self.user
                }
                self.conversations = list
                self.applyBootstrapUnread(data.unread, baseline: unreadBaseline)
                self.capabilities = data.capabilities
                self.realtime?.observeServers(self.capabilities.joinedServerIDs)
                self.updatePresenceSubscription()
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
        guard authState == .signedIn, !Task.isCancelled else { return }
        let changingConversation = selectedConversation?.id != conversation.id
        if changingConversation {
            messages = []
            hasMoreMessages = false
            oldestMessageCursor = nil
        }
        selectedConversation = conversation
        realtime?.observe(channelID: conversation.id, serverID: conversation.serverID)
        #if DEBUG
        if isFixture {
            messages = Self.fixtureMessages(conversationID: conversation.id, selfUser: user!)
            return
        }
        #endif
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
        historyDeletedIDs = []
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
        guard !Task.isCancelled else { return }
        let revision = epoch
        historyRevision += 1
        let historyID = historyRevision
        historyTask?.cancel()
        historyDeletedIDs = []
        let messagesAtStart = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        isLoadingMessages = true
        errorMessage = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.epoch == revision, self.historyRevision == historyID { self.isLoadingMessages = false; self.historyDeletedIDs = [] }
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
                self.liveProfileRevision += 1
                let cursor = history.messages.min { $0.created_at < $1.created_at }?.created_at
                self.hasMoreMessages = history.messages.count == 50 && cursor != before
                if before == nil { self.oldestMessageCursor = cursor }
                else if let cursor { self.oldestMessageCursor = cursor }
                if before == nil {
                    // Keep the current history visible during refresh. Replace it only after a
                    // successful response, retaining live inserts/edits/deletes from this request.
                    let removed = Set(messagesAtStart.keys).subtracting(self.messages.map(\.id)).union(self.historyDeletedIDs)
                    let liveChanges = self.messages.filter { messagesAtStart[$0.id] != $0 }
                    self.messages = Self.merged(messages.filter { !removed.contains($0.id) } + liveChanges)
                } else { self.messages = Self.merged(messages.filter { !self.historyDeletedIDs.contains($0.id) } + self.messages) }
                await self.hydrateLiveProfiles(ids: messages.flatMap { Array($0.mentions.userIDs) })
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
        let sendID = pendingSendIDs[conversation.id].flatMap { $0.text == trimmed ? $0.id : nil } ?? UUID().uuidString.lowercased()
        pendingSendIDs[conversation.id] = (trimmed, sendID)
        isSending = true
        errorMessage = nil
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { if self.epoch == revision { self.isSending = false } }
            do {
                let valid = try await self.validSession(revision: revision)
                let row = try await self.api.send(id: sendID, text: trimmed, channelID: conversation.id, session: valid, messagePolicy: self.messagePolicy)
                guard row.confirmsSend(id: sendID, channelID: conversation.id, authorID: valid.userID) else { throw NativeClientError.invalidResponse }
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

    /// Recheck account, mute expiry and the latest DND choice at the moment of playback.
    var currentNotificationSoundPolicy: NativeNotificationSoundPolicy? {
        guard authState == .signedIn, let ownerID = user?.id,
              let policy = notificationPolicy, policy.ownerID == ownerID,
              let muted = notificationMutedIDs else { return nil }
        let ownDND = ownPresencePreference?.ownerID == ownerID && ownPresencePreference?.preference == .dnd
        return NativeNotificationSoundPolicy(ownerID: ownerID, status: ownDND ? "dnd" : policy.status,
                                             blockedIDs: policy.blockedIDs, mutedIDs: muted)
    }

    func refreshNotificationSoundContext() async {
        #if DEBUG
        if isFixture { return }
        #endif
        guard !refreshingNotificationPolicy, authState == .signedIn, let ownerID = user?.id,
              let muted = notificationMutedIDs else { return }
        let revision = epoch
        let preferenceRevision = ownPresenceCommitRevision
        refreshingNotificationPolicy = true
        defer { if epoch == revision { refreshingNotificationPolicy = false } }
        do {
            let known = ownPresencePreference?.ownerID == ownerID ? ownPresencePreference?.preference : nil
            let policy = try await withAuthenticatedSession { api, session in try await api.nativeNotificationSoundPolicy(mutedIDs: muted, session: session, defaultPreference: known ?? .online) }
            guard epoch == revision, !Task.isCancelled, user?.id == ownerID, policy.ownerID == ownerID,
                  let currentMuted = notificationMutedIDs else { return }
            let latest = ownPresencePreference?.ownerID == ownerID ? ownPresencePreference : nil
            let status = ownPresenceCommitRevision != preferenceRevision ? latest?.status ?? policy.status : policy.status
            notificationPolicy = NativeNotificationSoundPolicy(ownerID: ownerID, status: status, blockedIDs: policy.blockedIDs, mutedIDs: currentMuted)
            notificationPolicyAt = now()
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
                  let policy = self.currentNotificationSoundPolicy else { return }
            self.notificationSound.receive(message: message, currentUserID: userID, currentConversationID: self.selectedConversation?.id, isActive: self.isActive, policy: policy)
        }
    }

    func signOut() {
        notificationSound.reset(); notificationPolicy = nil; notificationPolicyAt = nil; notificationPreferences = nil; refreshingNotificationPolicy = false
        ownPresencePreference = nil
        presenceRevision += 1
        ownPresenceCommitRevision += 1
        liveScopeTask?.cancel(); liveScopeTask = nil
        unreadRefreshTask?.cancel(); unreadRefreshTask = nil
        peerPresenceRevision += 1; peerPresenceEventRevision += 1; unreadFetchRevision += 1
        peerPresenceByID = [:]; channelUnread = [:]; channelServerIDs = [:]; voiceMembers = [:]
        latestIncomingMention = nil; liveServerID = nil; liveServerMemberIDs = [:]; ownServerRoleIDs = [:]
        unreadRevisions = [:]; liveMessageBadges = [:]; pendingLiveProfileIDs = []; voiceServerChannelIDs = [:]
        readRevisions = [:]
        mappedUnreadServerIDs = []
        serverNotificationContext = nil
        readLiveMessageIDs = []; readLiveMessageOrder = []; pendingMentionCandidates = [:]; shownMentionNoticeIDs = []
        for task in mentionLookupTasks.values { task.cancel() }
        mentionLookupTasks = [:]
        lastMentionNoticeAt = nil
        liveProfileRevision += 1
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
        historyDeletedIDs = []
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
        guard !(error is CancellationError), !Task.isCancelled else { return }
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
            peerPresenceByID = [:]
            voiceMembers = [:]
            latestIncomingMention = nil
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
                    await self.refreshOwnPresence()
                    guard self.epoch == revision, self.isActive, !Task.isCancelled else { return }
                    if let preference = self.ownPresencePreference, preference.ownerID == valid.userID {
                        self.realtime?.publishPresence(preference.preference)
                        // REST heartbeat is the official fallback for other clients not using RT presence.
                        _ = try? await self.withAuthenticatedSession { api, session in
                            try await api.rpc("heartbeat", arguments: ["st": .string(preference.preference.rawValue), "act": .null], session: session)
                        }
                    }
                    await self.refreshLiveState()
                    guard self.epoch == revision, self.isActive, !Task.isCancelled else { return }
                    let delay = max(1, min(45, valid.expiresAt.timeIntervalSince(self.now()) - 60))
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
                    self.realtime?.observeServers(self.capabilities.joinedServerIDs)
                    self.updatePresenceSubscription()
                }
                await self.loadConversations()
                await self.refreshLiveState()
                guard self.epoch == revision, !Task.isCancelled, self.selectedConversation?.id == selectedID,
                      let selected = self.selectedConversation else { return }
                await self.loadMessages(for: selected)
            } catch {
                guard self.epoch == revision, !Task.isCancelled else { return }
                self.handle(error)
            }
        }
    }

    func apply(_ mutation: RealtimeMutation) {
        guard authState == .signedIn, mutation.table == "messages" else { return }
        if mutation.operation == "DELETE", let old = mutation.old_record, let id = old.id {
            removeLiveUnread(messageID: id.lowercased())
            if isLoadingMessages { historyDeletedIDs.insert(id) }
            messages.removeAll { $0.id == id }
            return
        }
        guard let row = mutation.record else { return }
        let channelID = row.channel_id.lowercased()
        guard conversations.contains(where: { $0.id == channelID }) || selectedConversation?.id == channelID || channelServerIDs[channelID] != nil else { return }
        do {
            let message = try row.message(profiles: profiles)
            pendingMentionCandidates.removeValue(forKey: message.id)
            if selectedConversation?.id == channelID { messages = Self.merged(messages + [message]) }
            let inserted = mutation.operation == "INSERT" && seenRealtimeInserts.insert(message.id).inserted
            if inserted || mutation.operation == "INSERT" && liveMessageBadges[message.id] != nil {
                recordLiveUnread(messageID: message.id, channelID: channelID, authorID: message.author.id,
                                 mentioned: messageMentionsCurrentUser(message))
            }
            if inserted {
                if !readLiveMessageIDs.contains(message.id) { soundForUnreadDM(message) }
                showIncomingMentionIfAllowed(message)
                let account = epoch
                Task { [weak self] in
                    guard let self, self.epoch == account else { return }
                    await self.hydrateLiveProfiles(ids: [message.author.id] + Array(message.mentions.userIDs))
                }
            }
            if let index = conversations.firstIndex(where: { $0.id == channelID }) {
                conversations[index].lastMessage = message.content
                if mutation.operation == "INSERT" {
                    conversations[index].lastMessageAt = max(conversations[index].lastMessageAt ?? .distantPast, message.createdAt)
                }
            }
            if seenRealtimeInserts.count > 5000 { seenRealtimeInserts = [row.id] }
        } catch { realtimeStatus = "Live-Nachricht konnte nicht gelesen werden. Bitte Chat aktualisieren." }
    }

    private func showIncomingMentionIfAllowed(_ message: ChatMessage, verifiedRecipient: Bool = false) {
        guard mayPresentMention(channelID: message.channelID, authorID: message.author.id),
              !readLiveMessageIDs.contains(message.id), !shownMentionNoticeIDs.contains(message.id), !message.mentions.isForwarded,
              lastMentionNoticeAt.map({ message.createdAt >= $0 }) ?? true,
              (verifiedRecipient || messageMentionsCurrentUser(message)) else { return }
        latestIncomingMention = NativeIncomingMention(id: message.id, channelID: message.channelID,
            serverID: channelServerIDs[message.channelID], author: userWithLivePresence(message.author),
            content: message.content, createdAt: message.createdAt)
        shownMentionNoticeIDs.insert(message.id)
        lastMentionNoticeAt = message.createdAt
        if shownMentionNoticeIDs.count > 5_000 { shownMentionNoticeIDs = [message.id] }
    }

    private static func merged(_ messages: [ChatMessage]) -> [ChatMessage] {
        var byID: [String: ChatMessage] = [:]
        for message in messages { byID[message.id] = message }
        return byID.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    #if DEBUG
    /// Deterministic completion of the real asynchronous lookup path in synthetic tests.
    func awaitPendingMentionResolution() async {
        for task in Array(mentionLookupTasks.values) { await task.value }
    }

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
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures"),
           ProcessInfo.processInfo.arguments.contains("--native-ui-live-fixtures") {
            let sid = NativeServerFixtures.serverID
            let cid = NativeServerFixtures.textChannelID
            capabilities.joinedServerIDs.insert(sid)
            if var flags = capabilities.flags.object {
                for key in ["role_mentions", "channel_notify", "quick_notify", "mentions_v2", "voice_chat", "rt_presence"] {
                    flags[key] = .object(["mode": .string("everyone")])
                }
                capabilities.flags = .object(flags)
            }
            channelUnread[cid] = NativeChannelUnread(unread: 9, mentions: 2)
            channelUnread[NativeServerFixtures.readOnlyChannelID] = NativeChannelUnread(unread: 4)
            channelServerIDs[cid] = sid
            channelServerIDs[NativeServerFixtures.readOnlyChannelID] = sid
            channelServerIDs[NativeServerFixtures.voiceChannelID] = sid
            ownServerRoleIDs[sid] = ["bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"]
            peerPresenceByID = [friend.id: "online", other.id: "idle"]
            voiceMembers[NativeServerFixtures.voiceChannelID] = [
                NativeVoiceMember(userID: friend.id, muted: false, deafened: false, sharing: false),
                NativeVoiceMember(userID: other.id, muted: true, deafened: false, sharing: false)
            ]
            notificationPreferences = NativeConversationPreferenceSnapshot(capabilities: NativeConversationPreferenceCapabilities(flags: capabilities.flags, userID: selfUser.id, joinedServerIDs: [sid]), pins: [], hidden: [], hiddenAt: [:], muted: [], muteUntil: [:])
            notificationPolicy = NativeNotificationSoundPolicy(ownerID: selfUser.id, status: "online", blockedIDs: [], mutedIDs: [])
            notificationPolicyAt = now()
            serverNotificationContext = NativeServerNotificationState()
            latestIncomingMention = NativeIncomingMention(id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1", channelID: cid,
                serverID: sid, author: friend, content: "Hallo <@\(selfUser.id)> – eine synthetische Erwähnung.", createdAt: Date())
        }
    }

    private static func fixtureMessages(conversationID: String, selfUser: YapperUser) -> [ChatMessage] {
        let friend = YapperUser(id: "33333333-3333-4333-8333-333333333333", username: "nova", displayName: "Nova", presence: "online")
        let date = Date(timeIntervalSince1970: 1_793_360_000)
        var messages = [ChatMessage(id: "fixture-message-1", channelID: conversationID, author: friend, content: "Hey! Wie sieht die native App aus?", createdAt: date, attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-2", channelID: conversationID, author: selfUser, content: "Chats, Profile und Tastatur sind jetzt echte iOS-Oberflächen.", createdAt: date.addingTimeInterval(60), attachments: [], isEdited: false),
                ChatMessage(id: "fixture-message-3", channelID: conversationID, author: friend, content: "Das läuft jetzt direkt in SwiftUI.", createdAt: date.addingTimeInterval(120), attachments: [], isEdited: false)]
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures"),
           ProcessInfo.processInfo.arguments.contains("--native-ui-live-fixtures") {
            messages.append(ChatMessage(id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1", channelID: conversationID, author: friend,
                content: "Hallo <@\(selfUser.id)> und <@&bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb> in <#77777777-7777-4777-8777-777777777777>",
                createdAt: date.addingTimeInterval(180), attachments: [], isEdited: false))
        }
        return messages
    }
    #endif
}
