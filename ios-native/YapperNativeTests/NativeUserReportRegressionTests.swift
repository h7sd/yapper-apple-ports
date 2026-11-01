import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeUserReportRegressionTests {
    private let uid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let cid = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test func `Own Online status loads without notification preferences or blocks access`() async throws {
        var requests: [String] = []
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            requests.append(path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("my_status_pref") { return try http(request, data: Data("\"online\"".utf8)) }
            return try http(request, data: Data("{\"message\":\"denied\"}".utf8), status: 403)
        })
        let store = try await signedIn(api)
        #expect(store.user?.presence == "unknown")
        await store.refreshOwnPresence()
        #expect(store.user?.presence == "online")
        #expect(!requests.contains { $0.hasSuffix("blocks") })
        #expect(store.errorMessage == nil)
        store.signOut()
    }

    @Test func `Profile and list refresh never replace a known DND with unknown or a failed read`() async throws {
        var first = true
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("profiles") { return try http(request, data: profile()) }
            if path.hasSuffix("my_status_pref") {
                if first { first = false; return try http(request, data: Data("\"dnd\"".utf8)) }
                throw URLError(.notConnectedToInternet)
            }
            throw NativeClientError.invalidEndpoint
        })
        let store = try await signedIn(api)
        await store.refreshOwnPresence()
        #expect(store.user?.presence == "dnd")
        await store.loadConversations()
        #expect(store.user?.presence == "dnd")
        await store.refreshOwnProfile()
        #expect(store.user?.presence == "dnd")
        #expect(store.errorMessage == nil)
        store.signOut()
    }

    @Test func `A saved invisible choice survives successful null preference reads`() async throws {
        var writes = 0
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("set_status_pref") {
                writes += 1
                let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
                #expect(body["p"].string == "invisible")
                return try http(request, data: Data("null".utf8))
            }
            if path.hasSuffix("my_status_pref") { return try http(request, data: Data("null".utf8)) }
            throw NativeClientError.invalidEndpoint
        })
        let store = try await signedIn(api)
        try await store.setOwnPresence(.invisible)
        #expect(store.user?.presence == "invisible")
        await store.refreshOwnPresence()
        #expect(store.user?.presence == "invisible")
        #expect(writes == 1)
        store.signOut()
    }

    @Test func `Accepted mixed case UUID replies clear the draft and merge with live history once`() async throws {
        var posts = 0
        var sentID: String?
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try http(request, data: bootstrap()) }
            if request.url?.path.hasSuffix("channel_messages") == true { return try http(request, data: Data("{\"messages\":[],\"profiles\":[]}".utf8)) }
            #expect(request.httpMethod == "POST")
            posts += 1
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            let id = try #require(body["id"].string)
            #expect(id == id.lowercased())
            sentID = id
            return try http(request, data: message(id: id.uppercased(), channel: cid.uppercased(), author: uid.uppercased()))
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        store.setDraft("Hallo", for: cid)
        let accepted = await store.sendMessage("Hallo", in: conversation)
        #expect(accepted)
        #expect(store.errorMessage == nil)
        #expect(store.drafts[cid] == "")
        #expect(store.messages.count == 1)
        #expect(store.messages.first?.channelID == cid)
        #expect(store.messages.first?.author.id == uid)
        let id = try #require(sentID)
        let row = try JSONDecoder().decode(NativeJSON.self, from: message(id: id, channel: cid, author: uid))
        let event = NativeJSON.object(["table": .string("messages"), "operation": .string("INSERT"), "record": row])
        store.apply(try JSONDecoder().decode(RealtimeMutation.self, from: JSONEncoder().encode(event)))
        #expect(store.messages.count == 1)
        #expect(posts == 1)
        store.signOut()
    }

    @Test func `An older sound policy response cannot overwrite a newly confirmed DND choice`() async throws {
        var started: CheckedContinuation<Void, Never>?
        var finishBlocks: CheckedContinuation<Void, Never>?
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("my_status_pref") { return try http(request, data: Data("\"online\"".utf8)) }
            if path.hasSuffix("set_status_pref") { return try http(request, data: Data("null".utf8)) }
            if path.hasSuffix("blocks") {
                started?.resume(); started = nil
                await withCheckedContinuation { finishBlocks = $0 }
                return try http(request, data: Data("[]".utf8))
            }
            throw NativeClientError.invalidEndpoint
        })
        let store = try await signedIn(api)
        store.updateNotificationPreferences(emptyPreferences())
        let refresh = Task { await store.refreshNotificationSoundContext() }
        await withCheckedContinuation { started = $0 }
        try await store.setOwnPresence(.dnd)
        finishBlocks?.resume(); finishBlocks = nil
        await refresh.value
        let policy = try #require(store.currentNotificationSoundPolicy)
        #expect(policy.status == "dnd")
        #expect(store.user?.presence == "dnd")
        var plays = 0
        let name = "NativeUserReportRegressionTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let sound = NativeNotificationSound(defaults: defaults, play: { plays += 1 })
        let incoming = ChatMessage(id: "new", channelID: cid, author: YapperUser(id: "peer", username: "peer"),
                                   content: "Hello", createdAt: Date(), attachments: [], isEdited: false)
        #expect(!sound.receive(message: incoming, currentUserID: uid, currentConversationID: nil, isActive: true, policy: policy))
        #expect(plays == 0)
        store.signOut()
        #expect(store.currentNotificationSoundPolicy == nil)
    }

    @Test func `A fresh server DND policy is retained when cached own presence is Online`() async throws {
        var status = "online"
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("my_status_pref") { return try http(request, data: Data("\"\(status)\"".utf8)) }
            if path.hasSuffix("blocks") { return try http(request, data: Data("[]".utf8)) }
            throw NativeClientError.invalidEndpoint
        })
        let store = try await signedIn(api)
        await store.refreshOwnPresence()
        #expect(store.user?.presence == "online")
        store.updateNotificationPreferences(emptyPreferences())
        status = "dnd"
        await store.refreshNotificationSoundContext()
        #expect(store.currentNotificationSoundPolicy?.status == "dnd")
        store.signOut()
    }

    @Test func `Returning home prevents a late view callback from sending another read request`() async throws {
        var reads = 0
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("channel_messages") { return try http(request, data: Data("{\"messages\":[],\"profiles\":[]}".utf8)) }
            if path.hasSuffix("mark_read") { reads += 1; return try http(request, data: Data("null".utf8)) }
            throw NativeClientError.invalidEndpoint
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        store.closeConversation(id: cid)
        await store.markConversationRead(conversation)
        #expect(reads == 0)
        #expect(store.selectedConversation == nil)
        store.signOut()
    }

    private func signedIn(_ api: NativeAPI) async throws -> NativeStore {
        let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: uid)
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedIn)
        return store
    }
    private func emptyPreferences() -> NativeConversationPreferenceSnapshot {
        NativeConversationPreferenceSnapshot(capabilities: NativeConversationPreferenceCapabilities(flags: .null, userID: uid, joinedServerIDs: []),
                                             pins: [], hidden: [], hiddenAt: [:], muted: [], muteUntil: [:])
    }
    private func profile() -> Data { Data("{\"id\":\"\(uid)\",\"username\":\"synthetic\"}".utf8) }
    private func bootstrap() -> Data { Data("{\"profiles\":[{\"id\":\"\(uid)\",\"username\":\"synthetic\"}],\"dm_channels\":[{\"id\":\"\(cid)\",\"kind\":\"dm\",\"server_id\":null}],\"dm_members\":[[\"\(cid)\",\"\(uid)\"]]}".utf8) }
    private func message(id: String, channel: String, author: String) -> Data { Data("{\"id\":\"\(id)\",\"channel_id\":\"\(channel)\",\"author_id\":\"\(author)\",\"content\":\"Hallo\",\"created_at\":\"2026-11-01T12:00:00Z\"}".utf8) }
    private func http(_ request: URLRequest, data: Data, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
}
