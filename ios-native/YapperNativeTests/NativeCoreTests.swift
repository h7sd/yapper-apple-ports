import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeCoreTests {
    private let currentID = "11111111-1111-4111-8111-111111111111"
    private let chatID = "22222222-2222-4222-8222-222222222222"
    private let secondID = "33333333-3333-4333-8333-333333333333"

    private func session(expired: Bool = false) -> NativeSession {
        NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(expired ? -10 : 3600), userID: currentID)
    }

    private func bootstrap() -> Data {
        Data("""
        {"profiles":[{"id":"\(currentID)","username":"demo","display_name":"Demo","avatar_path":"demo/avatar image.png"}],
        "dm_channels":[{"id":"\(chatID)","kind":"dm","server_id":null},{"id":"\(secondID)","kind":"group","server_id":null,"name":"Native"}],
        "dm_members":[["\(chatID)","\(currentID)"],["\(secondID)","\(currentID)"]],"unread":[{"channel_id":"\(chatID)","unread":3}]}
        """.utf8)
    }

    private func http(_ request: URLRequest, data: Data, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }

    private func history(channel: String, id: String = "44444444-4444-4444-8444-444444444444", text: String = "Hallo") -> Data {
        Data("""
        {"messages":[{"id":"\(id)","channel_id":"\(channel)","author_id":"\(currentID)","content":"\(text)","created_at":"2026-10-30T12:30:00.123Z"}],"profiles":[]}
        """.utf8)
    }

    @Test func `API routes keep tokens on the exact HTTPS origin`() throws {
        #expect(NativeConfiguration.permits(URL(string: "https://dnfkuqzddwvtdojzgmdm.supabase.co/rest/v1/messages")!))
        #expect(!NativeConfiguration.permits(URL(string: "http://dnfkuqzddwvtdojzgmdm.supabase.co/rest/v1/messages")!))
        #expect(!NativeConfiguration.permits(URL(string: "https://dnfkuqzddwvtdojzgmdm.supabase.co.evil.test/rest/v1/messages")!))
        #expect(!NativeConfiguration.permits(URL(string: "https://name:password@dnfkuqzddwvtdojzgmdm.supabase.co/rest/v1/messages")!))
        #expect(!NativeConfiguration.permits(URL(string: "https://dnfkuqzddwvtdojzgmdm.supabase.co:444/rest/v1/messages")!))
        let api = NativeAPI(transport: { _ in throw URLError(.unsupportedURL) })
        let login = try api.request(path: "api/login", method: "POST", loginOrigin: true)
        #expect(login.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(login.value(forHTTPHeaderField: "apikey") == nil)
        #expect(throws: NativeClientError.invalidEndpoint) { try api.request(path: "elsewhere", loginOrigin: true) }
    }

    @Test func `Asset paths stay on public HTTPS and preserve encoded characters`() throws {
        let asset = try #require(NativeConfiguration.publicAsset(bucket: "avatars", path: "a folder/avatar ?.png"))
        #expect(asset.host == "files.yapper.website")
        #expect(asset.scheme == "https")
        #expect(asset.query == nil)
        #expect(asset.absoluteString.contains("a%20folder"))
        #expect(NativeConfiguration.publicAsset(bucket: "avatars", path: "https://untrusted.test/token") == nil)
        #expect(NativeConfiguration.publicAsset(bucket: "avatars", path: "../private") == nil)
    }

    @Test func `Bootstrap tuple membership decodes and malformed data fails visibly`() throws {
        let decoded = try JSONDecoder().decode(BootstrapResponse.self, from: bootstrap())
        let list = try decoded.conversations(currentUserID: currentID)
        #expect(list.count == 2)
        #expect(list.first(where: { $0.id == chatID })?.unreadCount == 3)
        #expect(list.first(where: { $0.id == secondID })?.title == "Native")
        let invalid = Data("{\"dm_channels\":[],\"profiles\":[],\"dm_members\":[[\"one\"]]}".utf8)
        let malformed = try JSONDecoder().decode(BootstrapResponse.self, from: invalid)
        #expect(throws: (any Error).self) { try malformed.conversations(currentUserID: currentID) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(BootstrapResponse.self, from: Data("{}".utf8)) }
    }

    @Test func `Current profile fallback accepts only the requested named account`() async throws {
        var responseID = currentID
        var username = "demo"
        let api = NativeAPI(transport: { request in
            let body = try JSONSerialization.data(withJSONObject: ["id": responseID, "username": username])
            return try http(request, data: body)
        })
        let valid = try await api.profile(id: currentID, session: session())
        #expect(valid.id == currentID)
        #expect(valid.username == "demo")
        responseID = secondID
        await #expect(throws: NativeClientError.invalidResponse) { try await api.profile(id: currentID, session: session()) }
        responseID = currentID
        username = ""
        await #expect(throws: NativeClientError.invalidResponse) { try await api.profile(id: currentID, session: session()) }
    }

    @Test func `Initial and older history send the exact explicit RPC parameters`() async throws {
        var bodies: [[String: Any]] = []
        let api = NativeAPI(transport: { request in
            let bytes = try #require(request.httpBody)
            bodies.append(try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any]))
            return try http(request, data: Data("{\"messages\":[],\"profiles\":[]}".utf8))
        })
        _ = try await api.history(channelID: chatID, session: session())
        _ = try await api.history(channelID: chatID, before: "2026-10-30T12:30:00.123Z", session: session())
        #expect(bodies.count == 2)
        #expect(bodies[0]["before"] is NSNull)
        #expect(bodies[0]["lim"] as? Int == 50)
        #expect(bodies[1]["before"] as? String == "2026-10-30T12:30:00.123Z")
    }

    @Test func `Server malformed JSON and HTTP errors are never empty successes`() async throws {
        let malformed = NativeAPI(transport: { request in try http(request, data: Data("{}".utf8)) })
        await #expect(throws: (any Error).self) { try await malformed.history(channelID: chatID, session: session()) }
        let denied = NativeAPI(transport: { request in try http(request, data: Data("{\"message\":\"permission denied\"}".utf8), status: 403) })
        await #expect(throws: NativeClientError.api(status: 403, message: "permission denied")) { try await denied.history(channelID: chatID, session: session()) }
    }

    @Test func `Required CAPTCHA explains the native limitation without signing in`() async {
        let api = NativeAPI(transport: { request in try http(request, data: Data("{\"error\":\"captcha verification failed\"}".utf8), status: 400) })
        let vault = MemorySessionVault()
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.signIn(identifier: "demo", password: "synthetic-password")
        #expect(store.authState == .signedOut)
        #expect(store.user == nil)
        #expect(store.errorMessage?.contains("CAPTCHA") == true)
        #expect(vault.session == nil)
    }

    @Test func `Transient restore failure keeps the saved refresh token`() async {
        let saved = session()
        let vault = MemorySessionVault(session: saved)
        let api = NativeAPI(transport: { _ in throw URLError(.notConnectedToInternet) })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedOut)
        #expect(store.user == nil)
        #expect(vault.session == saved)
        #expect(store.errorMessage != nil)
    }

    @Test func `Logout invalidates a history response that ignores cancellation`() async throws {
        let gate = ResponseGate()
        let vault = MemorySessionVault(session: session())
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try http(request, data: bootstrap()) }
            return try await gate.wait()
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.restoreSession()
        let conversation = try #require(store.conversations.first)
        let load = Task { await store.loadMessages(for: conversation) }
        await gate.waitUntilEntered()
        store.setDraft("privater Entwurf", for: conversation.id)
        store.signOut()
        let request = try api.request(path: "rest/v1/rpc/channel_messages")
        gate.resume(try http(request, data: history(channel: conversation.id)))
        await load.value
        #expect(store.user == nil)
        #expect(store.messages.isEmpty)
        #expect(store.drafts.isEmpty)
        #expect(store.selectedConversation == nil)
        #expect(vault.session == nil)
        #expect(!store.isLoading)
    }

    @Test func `Rapid chat navigation cannot replace the selected history with stale rows`() async throws {
        let gate = ResponseGate()
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try http(request, data: bootstrap()) }
            let bytes = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if body["cid"] as? String == chatID { return try await gate.wait() }
            return try http(request, data: history(channel: secondID, text: "Zweiter Chat"))
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        let first = try #require(store.conversations.first(where: { $0.id == chatID }))
        let second = try #require(store.conversations.first(where: { $0.id == secondID }))
        let old = Task { await store.loadMessages(for: first) }
        await gate.waitUntilEntered()
        await store.loadMessages(for: second)
        gate.resume(try http(api.request(path: "rest/v1/rpc/channel_messages"), data: history(channel: chatID)))
        await old.value
        #expect(store.selectedConversation?.id == secondID)
        #expect(store.messages.map(\.content) == ["Zweiter Chat"])
        #expect(!store.isLoadingMessages)
        store.signOut()
    }

    @Test func `A failed send preserves the draft and retry reuses its UUID`() async throws {
        var sentBodies: [[String: Any]] = []
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try http(request, data: bootstrap()) }
            if request.url?.path.hasSuffix("channel_messages") == true { return try http(request, data: Data("{\"messages\":[],\"profiles\":[]}".utf8)) }
            let bytes = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            sentBodies.append(body)
            if sentBodies.count == 1 { throw URLError(.networkConnectionLost) }
            var row = body
            row["created_at"] = "2026-10-30T12:30:00Z"
            return try http(request, data: JSONSerialization.data(withJSONObject: row))
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        #expect(await store.sendMessage(" Hallo ", in: conversation) == false)
        #expect(store.drafts[conversation.id] == " Hallo ")
        #expect(!store.isSending)
        #expect(await store.sendMessage(" Hallo ", in: conversation))
        #expect(sentBodies.count == 2)
        #expect(sentBodies[0]["id"] as? String == sentBodies[1]["id"] as? String)
        #expect(sentBodies[0]["created_at"] == nil)
        #expect(sentBodies[0]["content"] as? String == "Hallo")
        #expect(store.messages.count == 1)
        #expect(store.drafts[conversation.id] == "")
        store.signOut()
    }

    @Test func `Closing a conversation cancels selection but preserves its draft`() async throws {
        let store = NativeStore.fixture()
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        store.setDraft("später senden", for: conversation.id)
        store.closeConversation(id: conversation.id)
        #expect(store.selectedConversation == nil)
        #expect(store.messages.isEmpty)
        #expect(store.drafts[conversation.id] == "später senden")
    }

    @Test(arguments: [false, true]) func `Refresh rotation survives caller cancellation and never survives logout`(logout: Bool) async throws {
        let gate = ResponseGate()
        let start = Date()
        var clock = start
        var refreshCalls = 0
        let saved = NativeSession(accessToken: "old-access", refreshToken: "old-refresh", expiresAt: start.addingTimeInterval(3600), userID: currentID)
        let vault = MemorySessionVault(session: saved)
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try http(request, data: bootstrap()) }
            if request.url?.path.hasSuffix("token") == true {
                refreshCalls += 1
                return try await gate.wait()
            }
            return try http(request, data: Data("{\"messages\":[],\"profiles\":[]}".utf8))
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil, now: { clock })
        await store.restoreSession()
        let conversation = try #require(store.conversations.first)
        clock = start.addingTimeInterval(4000)
        let load = Task { await store.loadMessages(for: conversation) }
        await gate.waitUntilEntered()
        if logout { store.signOut() }
        else { store.closeConversation(id: conversation.id) }
        let bytes = try JSONSerialization.data(withJSONObject: ["access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_at": start.addingTimeInterval(10_800).timeIntervalSince1970, "user": ["id": currentID]])
        let request = try api.request(path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")])
        gate.resume(try http(request, data: bytes))
        await load.value
        #expect(refreshCalls == 1)
        #expect(store.selectedConversation == nil)
        #expect(store.messages.isEmpty)
        if logout {
            #expect(vault.session == nil)
            #expect(store.authState == .signedOut)
        } else {
            #expect(vault.session?.refreshToken == "rotated-refresh")
            #expect(store.authState == .signedIn)
            await store.loadConversations()
            #expect(refreshCalls == 1)
            store.signOut()
        }
    }

    @Test func `Refresh cannot switch the active account`() async {
        let saved = session(expired: true)
        let vault = MemorySessionVault(session: saved)
        let api = NativeAPI(transport: { request in
            try http(request, data: Data("{\"access_token\":\"different-access\",\"refresh_token\":\"different-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"different-user\"}}".utf8))
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedOut)
        #expect(store.user == nil)
        #expect(vault.session == saved)
        #expect(store.errorMessage != nil)
    }

    @Test func `TOTP keeps the lower assurance token out of Keychain until verification`() async throws {
        let factor = "55555555-5555-4555-8555-555555555555"
        let vault = MemorySessionVault()
        var challengeSent = false
        var verifySent = false
        let api = NativeAPI(transport: { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("bootstrap") { return try http(request, data: bootstrap()) }
            if path.hasSuffix("/user") {
                return try http(request, data: Data("{\"id\":\"\(currentID)\",\"factors\":[{\"id\":\"\(factor)\",\"factor_type\":\"totp\",\"status\":\"verified\"}]}".utf8))
            }
            if path.hasSuffix("/challenge") {
                let bytes = try #require(request.httpBody)
                let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
                #expect(body["factorId"] == factor)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer lower-access")
                challengeSent = true
                return try http(request, data: Data("{\"id\":\"challenge-id\"}".utf8))
            }
            if path.hasSuffix("/verify") {
                let bytes = try #require(request.httpBody)
                let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: String])
                #expect(body["challenge_id"] == "challenge-id")
                #expect(body["code"] == "123456")
                verifySent = true
            }
            let token = path.hasSuffix("/verify") ? "verified" : "lower"
            return try http(request, data: Data("{\"access_token\":\"\(token)-access\",\"refresh_token\":\"\(token)-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(currentID)\"}}".utf8))
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.signIn(identifier: "demo@example.test", password: "synthetic-password")
        #expect(store.authState == .requiresTwoFactor)
        #expect(vault.session == nil)
        await store.signIn(identifier: "", password: "", code: "123456")
        #expect(challengeSent && verifySent)
        #expect(store.authState == .signedIn)
        #expect(vault.session?.refreshToken == "verified-refresh")
        store.signOut()
    }

    @Test func `Realtime acknowledgement arrays and unrelated events decode safely`() throws {
        let ack = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data("{\"type\":\"subscribed\",\"ok\":[\"all\",\"user:demo\"],\"no\":[],\"retry\":[]}".utf8))
        #expect(ack.approvedTopics == ["all", "user:demo"])
        let unrelated = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data("{\"type\":\"event\",\"event\":\"profile\",\"payload\":{\"anything\":1}}".utf8))
        #expect(unrelated.payload == nil)
        let auth = try JSONDecoder().decode(RealtimeEnvelope.self, from: Data("{\"type\":\"auth\",\"ok\":true}".utf8))
        #expect(auth.ok == true)
    }
}

@MainActor private final class ResponseGate {
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var entered = false
    private var startContinuation: CheckedContinuation<Void, Never>?

    func wait() async throws -> (Data, HTTPURLResponse) {
        entered = true
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func resume(_ response: (Data, HTTPURLResponse)) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}
