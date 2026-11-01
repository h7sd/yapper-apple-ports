import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeServiceTests {
    private let uid = "11111111-1111-4111-8111-111111111111"
    private func session() -> NativeSession { NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: uid) }
    private func http(_ request: URLRequest, data: Data = Data(), status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, response)
    }
    private func bootstrap() -> Data {
        Data("{\"profiles\":[{\"id\":\"\(uid)\",\"username\":\"synthetic\"}],\"dm_channels\":[],\"dm_members\":[]}".utf8)
    }

    @Test func `Void RPC responses remain successful without accepting malformed JSON`() async throws {
        let api = NativeAPI(transport: { request in
            #expect(request.url?.path == "/rest/v1/rpc/mark_read")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            return try http(request, status: 204)
        })
        #expect(try await api.rpc("mark_read", arguments: ["cid": .string(uid)], session: session()) == .null)
        let broken = NativeAPI(transport: { request in try http(request, data: Data("not-json".utf8)) })
        await #expect(throws: (any Error).self) { try await broken.rpc("mark_read", session: session()) }
    }

    @Test func `Website service calls use the canonical HTTPS origin with no anonymous auth key`() async throws {
        let api = NativeAPI(transport: { request in
            #expect(request.url?.absoluteString == "https://www.yapin.gg/api/livekit-token")
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            let body = try #require(request.httpBody)
            let value = try JSONDecoder().decode(NativeJSON.self, from: body)
            #expect(value["e2ee"] == .bool(true))
            return try http(request, data: Data("{\"token\":\"synthetic-ticket\"}".utf8))
        })
        _ = try await api.webAPI(path: "api/livekit-token", method: "POST", body: .object(["e2ee": .bool(true)]), session: session())
        await #expect(throws: NativeClientError.invalidEndpoint) { try await api.webAPI(path: "api/../outside", session: session()) }
        await #expect(throws: NativeClientError.invalidEndpoint) { try await api.rpc("../../private", session: session()) }
    }

    @Test func `A completed feature request cannot restore data after logout`() async throws {
        let gate = NativeFeatureGate()
        let api = NativeAPI(transport: { request in try http(request, data: bootstrap()) })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        #expect(store.authState == .signedIn)
        let pending = Task { try await store.withAuthenticatedSession { _, _ in await gate.wait() } }
        await gate.started()
        store.signOut()
        gate.finish()
        switch await pending.result {
        case .success: Issue.record("Stale data escaped the logout boundary")
        case let .failure(error): #expect(error is CancellationError)
        }
        #expect(store.authState == .signedOut)
    }

    @Test func `TOTP security changes save the returned same-account rotated session`() async throws {
        let vault = MemorySessionVault(session: session())
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("/challenge") == true { return try http(request, data: Data("{\"id\":\"synthetic-challenge\"}".utf8)) }
            if request.url?.path.hasSuffix("/verify") == true {
                return try http(request, data: Data("{\"access_token\":\"rotated-access\",\"refresh_token\":\"rotated-refresh\",\"expires_in\":3600,\"user\":{\"id\":\"\(uid)\"}}".utf8))
            }
            return try http(request, data: bootstrap())
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        await store.restoreSession()
        try await store.verifyNativeSecurityFactor(factorID: uid, code: "123456")
        #expect(vault.session?.refreshToken == "rotated-refresh")
        let bearer = try await store.withAuthenticatedSession { _, session in session.accessToken }
        #expect(bearer == "rotated-access")
    }

    @Test func `Logout during account reauthentication prevents subsequent media cleanup and deletion`() async throws {
        let gate = NativeFeatureGate(), log = NativeFeatureRequestLog()
        let api = NativeAPI(transport: { request in
            log.paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/reauth_check") {
                _ = await gate.wait()
                return try http(request, data: Data("null".utf8))
            }
            return try http(request, data: bootstrap())
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session()), realtime: nil)
        await store.restoreSession()
        let pending = Task {
            try await store.withAuthenticatedSession { api, session in
                try await NativeAccountDataService(api: api).deleteAccount(password: "synthetic-password", gdprDelete: true, session: session)
            }
        }
        await gate.started()
        store.signOut()
        gate.finish()
        switch await pending.result {
        case .success: Issue.record("A signed-out account operation must stop")
        case let .failure(error): #expect(error is CancellationError)
        }
        #expect(!log.paths.contains { $0.hasPrefix("/api/") || $0.hasPrefix("/storage/") || $0.hasSuffix("/delete_my_account") })
    }
}

@MainActor private final class NativeFeatureRequestLog { var paths: [String] = [] }

@MainActor private final class NativeFeatureGate {
    private var continuation: CheckedContinuation<String, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func wait() async -> String {
        startedContinuation?.resume(); startedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func finish() { continuation?.resume(returning: "synthetic-result"); continuation = nil }
}
