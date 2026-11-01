import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeReloadRegressionTests {
    private let uid = "11111111-1111-4111-8111-111111111111"
    private let cid = "22222222-2222-4222-8222-222222222222"

    @Test func `Changing topics and duplicate approvals never become socket reconnects`() {
        var lifecycle = RealtimeSubscriptionLifecycle()
        lifecycle.beginSocket()
        let denied = lifecycle.acknowledge(userTopicApproved: false)
        let initial = lifecycle.acknowledge(userTopicApproved: true)
        #expect(!denied)
        #expect(!initial)
        #expect(lifecycle.hasConnected)
        // A history resync observes its channel again. Its acknowledgement must
        // not schedule another history resync, even after many topic changes.
        for _ in 0..<20 { let resync = lifecycle.acknowledge(userTopicApproved: true); #expect(!resync) }
        lifecycle.beginSocket()
        let reconnectDenied = lifecycle.acknowledge(userTopicApproved: false)
        let reconnect = lifecycle.acknowledge(userTopicApproved: true)
        #expect(!reconnectDenied)
        #expect(reconnect)
        for _ in 0..<20 { let resync = lifecycle.acknowledge(userTopicApproved: true); #expect(!resync) }
        lifecycle.beginSocket()
        let nextReconnect = lifecycle.acknowledge(userTopicApproved: true)
        #expect(nextReconnect)
    }

    @Test func `Token rotation retains reconnect history but another account starts fresh`() {
        var rotated = RealtimeSubscriptionLifecycle(previouslyConnected: true)
        rotated.beginSocket()
        let reconnect = rotated.acknowledge(userTopicApproved: true)
        let topicChange = rotated.acknowledge(userTopicApproved: true)
        #expect(reconnect)
        #expect(!topicChange)
        var nextAccount = RealtimeSubscriptionLifecycle()
        nextAccount.beginSocket()
        let firstApproval = nextAccount.acknowledge(userTopicApproved: true)
        #expect(!firstApproval)
    }

    @Test(arguments: [403, 503]) func `A failed refresh retains visible messages and reports the real error`(status: Int) async throws {
        let gate = ReloadResponseGate()
        var histories = 0
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try response(request, data: bootstrap()) }
            histories += 1
            if histories == 1 { return try response(request, data: history(text: "Bereits geladen")) }
            return try await gate.wait(request)
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        let refresh = Task { await store.loadMessages(for: conversation) }
        let pending = await gate.entered()
        #expect(store.isLoadingMessages)
        #expect(store.messages.map(\.content) == ["Bereits geladen"])
        gate.finish(.success(try response(pending, data: Data("{\"message\":\"real server failure\"}".utf8), status: status)))
        await refresh.value
        #expect(store.messages.map(\.content) == ["Bereits geladen"])
        #expect(store.errorMessage?.contains("real server failure") == true)
        #expect(!store.isLoadingMessages)
        #expect(store.authState == .signedIn)
        store.signOut()
    }

    @Test func `Successful refresh updates the snapshot without keeping removed messages`() async throws {
        let gate = ReloadResponseGate()
        var histories = 0
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try response(request, data: bootstrap()) }
            histories += 1
            if histories == 1 { return try response(request, data: history(text: "Alter Stand")) }
            return try await gate.wait(request)
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        let refresh = Task { await store.loadMessages(for: conversation) }
        let pending = await gate.entered()
        #expect(store.messages.map(\.content) == ["Alter Stand"])
        gate.finish(.success(try response(pending, data: Data("{\"messages\":[],\"profiles\":[]}".utf8))))
        await refresh.value
        #expect(store.messages.isEmpty)
        #expect(store.errorMessage == nil)
        #expect(histories == 2)
        store.signOut()
    }

    @Test func `Transport cancellation retains history without an Abgebrochen error`() async throws {
        var histories = 0
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try response(request, data: bootstrap()) }
            histories += 1
            if histories == 1 { return try response(request, data: history(text: "Bleibt sichtbar")) }
            throw URLError(.cancelled)
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        await store.loadMessages(for: conversation)
        await store.loadMessages(for: conversation)
        #expect(store.messages.map(\.content) == ["Bleibt sichtbar"])
        #expect(store.errorMessage == nil)
        #expect(!store.isLoadingMessages)
        store.signOut()
    }

    @Test func `A pending snapshot cannot resurrect a live deletion absent from the cache`() async throws {
        let gate = ReloadResponseGate()
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("bootstrap") == true { return try response(request, data: bootstrap()) }
            return try await gate.wait(request)
        })
        let store = try await signedIn(api)
        let conversation = try #require(store.conversations.first)
        let pending = Task { await store.loadMessages(for: conversation) }
        let request = await gate.entered()
        let deletion = try JSONDecoder().decode(RealtimeMutation.self, from: Data("""
        {"table":"messages","operation":"DELETE","old_record":{"id":"33333333-3333-4333-8333-333333333333","channel_id":"\(cid)"}}
        """.utf8))
        store.apply(deletion)
        gate.finish(.success(try response(request, data: history(text: "Bereits gelöscht"))))
        await pending.value
        #expect(store.messages.isEmpty)
        #expect(store.errorMessage == nil)
        store.signOut()
    }

    private func signedIn(_ api: NativeAPI) async throws -> NativeStore {
        let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: uid)
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedIn)
        return store
    }

    private func bootstrap() -> Data {
        Data("""
        {"profiles":[{"id":"\(uid)","username":"synthetic"}],"dm_channels":[{"id":"\(cid)","kind":"dm","server_id":null}],"dm_members":[["\(cid)","\(uid)"]]}
        """.utf8)
    }

    private func history(text: String) -> Data {
        Data("""
        {"messages":[{"id":"33333333-3333-4333-8333-333333333333","channel_id":"\(cid)","author_id":"\(uid)","content":"\(text)","created_at":"2026-11-01T12:00:00Z"}],"profiles":[]}
        """.utf8)
    }

    private func response(_ request: URLRequest, data: Data, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
}

@MainActor private final class ReloadResponseGate {
    private var pending: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var waiter: CheckedContinuation<URLRequest, Never>?
    private var request: URLRequest?

    func wait(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            waiter?.resume(returning: request); waiter = nil
        }
    }
    func entered() async -> URLRequest {
        if let request { return request }
        return await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        pending?.resume(with: result); pending = nil
    }
}
