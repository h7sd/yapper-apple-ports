import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeLiveStateTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let other = "33333333-3333-4333-8333-333333333333"
    private let channel = "44444444-4444-4444-8444-444444444444"
    private let server = "55555555-5555-4555-8555-555555555555"
    private let role = "66666666-6666-4666-8666-666666666666"

    @Test func `Presence uses the top level rows protocol and invisible never becomes Online`() throws {
        let payload = Data("{\"type\":\"presence\",\"rows\":[[\"\(peer)\",\"dnd\",null],[\"\(other)\",\"invisible\",null]],\"full\":true,\"server\":\"\(server)\"}".utf8)
        let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: payload)
        #expect(envelope.type == "presence")
        #expect(envelope.presenceFull == true)
        #expect(envelope.presenceServer == server)
        let snapshot = try NativePeerPresenceSnapshot(rows: #require(envelope.presenceRows), full: true, serverID: server)
        #expect(snapshot.statuses[peer] == "dnd")
        #expect(snapshot.statuses[other] == "offline")
    }

    @Test func `Malformed presence rows cannot establish a false Online status`() throws {
        let row = NativeJSON.array([.array([.string(peer), .string("unknown-server-value"), .null])])
        #expect(throws: NativeClientError.invalidResponse) { try NativePeerPresenceSnapshot(rows: row, full: true, serverID: nil) }
        #expect(throws: NativeClientError.invalidResponse) { try NativePeerPresenceSnapshot(rows: .object([:]), full: true, serverID: nil) }
    }

    @Test func `Presence request matches who_online scope and unread route keeps server counts separate`() async throws {
        var paths: [String] = []
        let api = NativeAPI(transport: { request in
            paths.append(try #require(request.url?.path))
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            if request.url?.path.hasSuffix("who_online") == true {
                #expect(body["sid"].string == server)
                #expect(body["extra"].array == [.string(peer)])
                #expect(body["since"] == .null)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
                return try http(request, json: .object(["now": .string("2026-11-01T14:00:00Z"), "rows": .array([.array([.string(peer), .string("online"), .null])])]))
            }
            #expect(body == .object([:]))
            return try http(request, json: .array([.object(["channel_id": .string(channel), "unread": .number(4), "mentions": .number(2), "muted": .bool(false)])]))
        })
        let snapshot = try await api.nativePeerPresence(serverID: server, extraIDs: [peer, peer], session: session())
        #expect(snapshot.statuses[peer] == "online")
        let counts = try await api.nativeUnreadCounts(session: session())
        #expect(counts[channel] == NativeChannelUnread(unread: 4, mentions: 2))
        #expect(paths.map { $0.split(separator: "/").last.map(String.init) } == ["who_online", "unread_counts_v2"])
    }

    @Test func `Mention targets preserve direct role and server selected here recipients`() {
        let mention = NativeMessageMentions(content: "Hi <@\(peer.uppercased())> <@&\(role)> <#\(channel)> @here", hereRecipientIDs: [own])
        #expect(mention.userIDs == [peer])
        #expect(mention.roleIDs == [role])
        #expect(mention.channelIDs == [channel])
        #expect(mention.includes(userID: own))
        #expect(mention.includes(userID: other, roleIDs: [role]))
        #expect(!NativeMessageMentions(content: "@here").includes(userID: own))
        #expect(!NativeMessageMentions(content: "contact me@everyone.invalid").includes(userID: own))
        #expect(NativeMessageMentions(content: "@everyone").includes(userID: own))
        #expect(!NativeMessageMentions(content: "↪ Forwarded\n<@\(own)> @everyone").includes(userID: own))
    }

    @Test func `Peer full snapshots resolve missing scoped members offline without replacing own preference`() async throws {
        let store = try await store()
        defer { store.signOut() }
        #expect(store.peerPresence(userID: peer) == "unknown")
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer"), YapperUser(id: other, username: "other")])
        store.applyPeerPresence(try NativePeerPresenceSnapshot(rows: .array([.array([.string(peer), .string("online"), .null])]), full: true, serverID: server))
        #expect(store.peerPresence(userID: peer) == "online")
        #expect(store.peerPresence(userID: other) == "offline")
        #expect(store.user?.presence == "unknown")
        store.applyPeerPresence(try NativePeerPresenceSnapshot(rows: .array([.array([.string(peer), .string("off"), .null])]), full: false, serverID: server))
        #expect(store.peerPresence(userID: peer) == "offline")
    }

    @Test func `Server unread summaries deduplicate full message delivery and upgrade direct mentions`() async throws {
        let store = try await store()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [])
        let mid = "77777777-7777-4777-8777-777777777777"
        let summary: NativeJSON = .object(["operation": .string("INSERT"), "id": .string(mid), "channel_id": .string(channel), "author_id": .string(peer), "server_id": .string(server)])
        store.applyEvent("unread", payload: summary)
        #expect(store.unreadCount(channelID: channel) == 1)
        #expect(store.mentionCount(channelID: channel) == 0)
        let mutation = try message(id: mid, content: "Hello <@\(own)>")
        store.apply(mutation)
        store.apply(mutation)
        #expect(store.unreadCount(inServer: server) == 1)
        #expect(store.mentionCount(inServer: server) == 1)
        store.applyEvent("read", payload: .object(["channel": .string(channel)]))
        #expect(store.unreadCount(inServer: server) == 0)
        #expect(store.mentionCount(inServer: server) == 0)
    }

    @Test func `Voice snapshots replace one server roster without inventing presence or retaining departed users`() async throws {
        let store = try await store()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer")])
        store.applyEvent("voice", payload: .object(["server_id": .string(server), "members": .array([.object(["channel_id": .string(channel), "user_id": .string(peer), "muted": .bool(true), "sharing": .bool(true)])])]))
        #expect(store.voiceMembers[channel]?.count == 1)
        #expect(store.voiceMembers[channel]?.first?.userID == peer)
        #expect(store.voiceMembers[channel]?.first?.muted == true)
        #expect(store.voiceMembers[channel]?.first?.sharing == true)
        #expect(store.peerPresence(userID: peer) == "unknown")
        store.applyEvent("voice", payload: .object(["server_id": .string(server), "members": .array([])]))
        #expect(store.voiceMembers[channel] == nil)
    }

    @Test func `A delayed full message cannot restore a compact summary already read elsewhere`() async throws {
        let store = try await store()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [])
        let mid = "77777777-7777-4777-8777-777777777776"
        let summary: NativeJSON = .object(["operation": .string("INSERT"), "id": .string(mid), "channel_id": .string(channel), "author_id": .string(peer), "server_id": .string(server)])
        store.applyEvent("unread", payload: summary)
        #expect(store.unreadCount(channelID: channel) == 1)
        store.applyEvent("read", payload: .object(["channel": .string(channel)]))
        store.apply(try message(id: mid, content: "<@\(own)>"))
        store.applyEvent("unread", payload: summary)
        #expect(store.unreadCount(channelID: channel) == 0)
        #expect(store.mentionCount(channelID: channel) == 0)
        #expect(store.latestIncomingMention == nil)
    }

    @Test func `Mention inbox selects observed versioned RPC and loads actual message rows`() async throws {
        var used: String?
        let api = NativeAPI(transport: { request in
            used = request.url?.lastPathComponent
            let args = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            #expect(args == .object(["lim": .number(40)]))
            return try http(request, json: .array([messageRow(id: "77777777-7777-4777-8777-777777777777", content: "<@\(own)>")]))
        })
        let rows = try await api.nativeMentionMessages(useV2: true, session: session())
        #expect(used == "my_mentions_v2")
        #expect(rows.count == 1)
        #expect(try rows.first?.message(profiles: [:]).mentions.includes(userID: own) == true)
    }

    @Test func `Read on another device is decoded and an older counts response cannot restore cleared badges`() async throws {
        let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data("{\"type\":\"read\",\"channel\":\"\(channel)\"}".utf8))
        #expect(envelope.readChannel == channel)
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let api = NativeAPI(transport: { request in
            if request.url?.lastPathComponent == "bootstrap" { return try http(request, json: bootstrap()) }
            if request.url?.lastPathComponent == "unread_counts_v2" {
                started?.resume(); started = nil
                await withCheckedContinuation { release = $0 }
                return try http(request, json: .array([.object(["channel_id": .string(channel), "unread": .number(8), "mentions": .number(3), "muted": .bool(false)])]))
            }
            throw NativeClientError.invalidEndpoint
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        let refresh = Task { await store.refreshLiveState() }
        await withCheckedContinuation { started = $0 }
        store.applyEvent("read", payload: .object(["channel": .string(channel)]))
        release?.resume(); release = nil
        await refresh.value
        #expect(store.unreadCount(channelID: channel) == 0)
        #expect(store.mentionCount(channelID: channel) == 0)
        store.signOut()
    }

    @Test func `Mention notice requires verified policy and respects DND and channel mute`() async throws {
        let api = NativeAPI(transport: { request in
            switch request.url?.lastPathComponent {
            case "bootstrap": return try http(request, json: bootstrap())
            case "my_status_pref": return try http(request, json: .string("online"))
            case "blocks": return try http(request, json: .array([]))
            case "set_status_pref": return try http(request, json: .null)
            default: throw NativeClientError.invalidEndpoint
            }
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer")])
        store.apply(try message(id: "77777777-7777-4777-8777-777777777771", content: "<@\(own)>"))
        #expect(store.latestIncomingMention == nil)
        store.updateNotificationPreferences(preferences())
        store.updateServerNotificationContext(NativeServerNotificationState())
        await store.refreshNotificationSoundContext()
        store.apply(try message(id: "77777777-7777-4777-8777-777777777772", content: "<@\(own)>"))
        #expect(store.latestIncomingMention?.author.id == peer)
        #expect(store.latestIncomingMention?.channelID == channel)
        store.dismissIncomingMention()
        try await store.setOwnPresence(.dnd)
        store.apply(try message(id: "77777777-7777-4777-8777-777777777773", content: "@everyone"))
        #expect(store.latestIncomingMention == nil)
        try await store.setOwnPresence(.online)
        store.updateNotificationPreferences(preferences(muted: [channel]))
        store.apply(try message(id: "77777777-7777-4777-8777-777777777774", content: "<@\(own)>"))
        #expect(store.latestIncomingMention == nil)
    }

    @Test func `Unread API rejects fractional or duplicate rows rather than fabricating counts`() async throws {
        let api = NativeAPI(transport: { request in
            try http(request, json: .array([.object(["channel_id": .string(channel), "unread": .number(2.5), "mentions": .number(1), "muted": .bool(false)])]))
        })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeUnreadCounts(session: session()) }
    }

    @Test func `Role ping eligibility follows the rollout and the actual own role assignment`() async throws {
        let store = try await store()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [])
        let row = try #require(message(id: "77777777-7777-4777-8777-777777777775", content: "<@&\(role)>").record)
        let chat = try row.message(profiles: [:])
        #expect(!store.messageMentionsCurrentUser(chat))
        store.registerServerRoles(serverID: server, ownRoleIDs: [role])
        #expect(store.messageMentionsCurrentUser(chat))
        store.registerServerRoles(serverID: server, ownRoleIDs: [])
        #expect(!store.messageMentionsCurrentUser(chat))
    }

    private func session() -> NativeSession { NativeSession(accessToken: "synthetic", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: own) }
    @Test func `Compact everyone ping retrieves one scoped actual message and discards out of order summaries`() async throws {
        let instant = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let timestamp = ISO8601DateFormatter().string(from: instant)
        var reads = 0
        let api = NativeAPI(transport: { request in
            switch request.url?.lastPathComponent {
            case "bootstrap": return try http(request, json: bootstrap())
            case "my_status_pref": return try http(request, json: .string("online"))
            case "blocks": return try http(request, json: .array([]))
            case "messages":
                #expect(request.httpMethod == "GET")
                reads += 1
                let query = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
                let id = try #require(query.first(where: { $0.name == "id" })?.value).replacingOccurrences(of: "eq.", with: "")
                #expect(query.contains(URLQueryItem(name: "channel_id", value: "eq.\(channel)")))
                #expect(query.contains(URLQueryItem(name: "author_id", value: "eq.\(peer)")))
                var row = try #require(messageRow(id: id, content: "Actual @everyone <@\(own)>").object)
                row["created_at"] = .string(timestamp)
                return try http(request, json: .array([.object(row)]))
            default: throw NativeClientError.invalidEndpoint
            }
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil, now: { instant })
        await store.restoreSession()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer")])
        store.updateNotificationPreferences(preferences())
        store.updateServerNotificationContext(NativeServerNotificationState())
        await store.refreshNotificationSoundContext()
        let mid = "77777777-7777-4777-8777-777777777778"
        let summary: NativeJSON = .object(["operation": .string("INSERT"), "id": .string(mid), "channel_id": .string(channel), "author_id": .string(peer), "server_id": .string(server), "everyone": .bool(true), "created_at": .string(timestamp)])
        store.applyEvent("unread", payload: summary)
        await store.awaitPendingMentionResolution()
        #expect(reads == 1)
        #expect(store.latestIncomingMention?.content == "Actual @everyone <@\(own)>")
        store.dismissIncomingMention()
        store.applyEvent("unread", payload: summary)
        await store.awaitPendingMentionResolution()
        #expect(reads == 1)
        var old = try #require(summary.object)
        old["id"] = .string("77777777-7777-4777-8777-777777777779")
        old["created_at"] = .string(ISO8601DateFormatter().string(from: instant.addingTimeInterval(-5)))
        store.applyEvent("unread", payload: .object(old))
        await store.awaitPendingMentionResolution()
        #expect(reads == 1)
        #expect(store.latestIncomingMention == nil)
    }

    @Test func `Reading during a compact ping lookup suppresses the late actual message notice`() async throws {
        let instant = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let timestamp = ISO8601DateFormatter().string(from: instant)
        var started: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let mid = "77777777-7777-4777-8777-777777777780"
        let api = NativeAPI(transport: { request in
            switch request.url?.lastPathComponent {
            case "bootstrap": return try http(request, json: bootstrap())
            case "my_status_pref": return try http(request, json: .string("online"))
            case "blocks": return try http(request, json: .array([]))
            case "messages":
                started?.resume(); started = nil
                await withCheckedContinuation { release = $0 }
                var row = try #require(messageRow(id: mid, content: "@everyone").object)
                row["created_at"] = .string(timestamp)
                return try http(request, json: .array([.object(row)]))
            default: throw NativeClientError.invalidEndpoint
            }
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil, now: { instant })
        await store.restoreSession()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer")])
        store.updateNotificationPreferences(preferences())
        store.updateServerNotificationContext(NativeServerNotificationState())
        await store.refreshNotificationSoundContext()
        let summary: NativeJSON = .object(["operation": .string("INSERT"), "id": .string(mid), "channel_id": .string(channel), "author_id": .string(peer), "server_id": .string(server), "everyone": .bool(true), "created_at": .string(timestamp)])
        store.applyEvent("unread", payload: summary)
        await withCheckedContinuation { started = $0 }
        store.applyEvent("read", payload: .object(["channel": .string(channel)]))
        release?.resume(); release = nil
        await store.awaitPendingMentionResolution()
        #expect(store.latestIncomingMention == nil)
        #expect(store.unreadCount(channelID: channel) == 0)
        store.apply(try message(id: mid, content: "@everyone"))
        #expect(store.latestIncomingMention == nil)
        #expect(store.unreadCount(channelID: channel) == 0)
    }

    @Test func `Opaque compact direct ping resolves through the authenticated own mentions feed`() async throws {
        let mid = "77777777-7777-4777-8777-777777777781"
        var mentionReads = 0
        let api = NativeAPI(transport: { request in
            switch request.url?.lastPathComponent {
            case "bootstrap": return try http(request, json: bootstrap())
            case "my_status_pref": return try http(request, json: .string("online"))
            case "blocks": return try http(request, json: .array([]))
            case "unread_counts_v2": return try http(request, json: .array([.object(["channel_id": .string(channel), "unread": .number(1), "mentions": .number(1), "muted": .bool(false)])]))
            case "visible_server_channels": return try http(request, json: .array([.object(["id": .string(channel), "server_id": .string(server)])]))
            case "my_mentions":
                mentionReads += 1
                var row = try #require(messageRow(id: mid, content: "A real direct ping <@\(own)>").object)
                row["created_at"] = .string(ISO8601DateFormatter().string(from: Date()))
                return try http(request, json: .array([.object(row)]))
            default: throw NativeClientError.invalidEndpoint
            }
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        defer { store.signOut() }
        store.observeServer(id: server, channelIDs: [channel], members: [YapperUser(id: peer, username: "peer")])
        store.updateNotificationPreferences(preferences())
        store.updateServerNotificationContext(NativeServerNotificationState())
        await store.refreshNotificationSoundContext()
        store.applyEvent("unread", payload: .object(["operation": .string("INSERT"), "id": .string(mid), "channel_id": .string(channel), "author_id": .string(peer), "server_id": .string(server)]))
        #expect(store.latestIncomingMention == nil)
        await store.refreshLiveState()
        #expect(mentionReads == 1)
        #expect(store.latestIncomingMention?.id == mid)
        #expect(store.latestIncomingMention?.content == "A real direct ping <@\(own)>")
    }

    @Test(arguments: [false, true]) func `Compact lookup rejects denied or mismatched message rows`(denied: Bool) async throws {
        let mid = "77777777-7777-4777-8777-777777777782"
        let api = NativeAPI(transport: { request in
            #expect(request.httpMethod == "GET")
            if denied { return try http(request, json: .object(["message": .string("denied")]), status: 403) }
            var row = try #require(messageRow(id: mid, content: "@everyone").object)
            row["author_id"] = .string(other)
            return try http(request, json: .array([.object(row)]))
        })
        do {
            _ = try await api.nativeMentionMessage(id: mid, channelID: channel, authorID: peer, session: session())
            Issue.record("Denied or mismatched data must not become a valid notification message.")
        } catch {
            if denied {
                guard case let NativeClientError.api(status, _) = error else { Issue.record("Expected the actual permission failure."); return }
                #expect(status == 403)
            } else { #expect(error as? NativeClientError == .invalidResponse) }
        }
    }

    private func store() async throws -> NativeStore {
        let api = NativeAPI(transport: { request in
            if request.url?.lastPathComponent == "bootstrap" {
                return try http(request, json: bootstrap())
            }
            throw NativeClientError.invalidEndpoint
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedIn)
        return store
    }
    private func message(id: String, content: String) throws -> RealtimeMutation {
        try JSONDecoder().decode(RealtimeMutation.self, from: JSONEncoder().encode(NativeJSON.object(["table": .string("messages"), "operation": .string("INSERT"), "record": messageRow(id: id, content: content)])))
    }
    private func messageRow(id: String, content: String) -> NativeJSON {
        .object(["id": .string(id), "channel_id": .string(channel), "author_id": .string(peer), "content": .string(content), "created_at": .string("2026-11-01T14:00:00Z")])
    }
    private func bootstrap() -> NativeJSON {
        .object(["profiles": .array([.object(["id": .string(own), "username": .string("own")]), .object(["id": .string(peer), "username": .string("peer")])]), "dm_channels": .array([]), "dm_members": .array([]), "servers": .array([.object(["id": .string(server)])]), "flags": .object(["role_mentions": .object(["mode": .string("everyone")])])])
    }
    private func preferences(muted: Set<String> = []) -> NativeConversationPreferenceSnapshot {
        NativeConversationPreferenceSnapshot(capabilities: NativeConversationPreferenceCapabilities(flags: .null, userID: own, joinedServerIDs: [server]),
                                             pins: [], hidden: [], hiddenAt: [:], muted: muted, muteUntil: [:])
    }
    private func http(_ request: URLRequest, json: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(json), response)
    }
}
