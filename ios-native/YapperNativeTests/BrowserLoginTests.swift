import Foundation
import Testing
@testable import YapperNative

@MainActor
struct BrowserLoginTests {
    private let userID = "11111111-1111-4111-8111-111111111111"
    private let factorID = "22222222-2222-4222-8222-222222222222"

    private func token(aal: String = "aal1", issuer: String = NativeConfiguration.apiURL.absoluteString + "/auth/v1") throws -> BrowserLoginTokens {
        let data = try JSONSerialization.data(withJSONObject: ["sub": userID, "iss": issuer, "role": "authenticated", "exp": Date().addingTimeInterval(3600).timeIntervalSince1970, "aal": aal])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try BrowserLoginTokens(accessToken: "eyJhbGciOiJIUzI1NiJ9." + payload + ".synthetic-signature-only-for-tests", refreshToken: "synthetic-refresh-token-only-for-tests")
    }

    private func http(_ request: URLRequest, json: String, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(json.utf8), response)
    }

    private func authUser(factorType: String? = nil) -> String {
        let factors = factorType.map { "[{\"id\":\"\(factorID)\",\"factor_type\":\"\($0)\",\"status\":\"verified\"}]" } ?? "[]"
        return "{\"id\":\"\(userID)\",\"factors\":\(factors)}"
    }

    private func bootstrap() -> String {
        "{\"dm_channels\":[],\"dm_members\":[],\"profiles\":[{\"id\":\"\(userID)\",\"username\":\"synthetic-account\"}],\"unread\":[]}"
    }

    @Test func `Only observed fresh auth response routes are accepted`() {
        let samples: [(String, String, Bool)] = [
            ("https://yapin.gg/api/login", "POST", true),
            ("https://www.yapin.gg/api/login", "POST", true),
            ("https://yapin.gg/api/login?next=other", "POST", false),
            ("https://yapin.gg/api/login/", "POST", false),
            ("https://yapin.gg/api/login", "GET", false),
            ("http://yapin.gg/api/login", "POST", false),
            ("https://yapin.gg.evil.test/api/login", "POST", false),
            ("https://user:password@yapin.gg/api/login", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/token?grant_type=password", "POST", true),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/token?grant_type=id_token", "POST", true),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/token/?grant_type=password", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/token?grant_type=refresh_token", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/token?grant_type=password&extra=1", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/factors/22222222-2222-4222-8222-222222222222/verify", "POST", true),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/factors/22222222-2222-4222-8222-222222222222/verify/", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth//v1/factors/22222222-2222-4222-8222-222222222222/verify", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/auth/v1/factors/not-an-id/verify", "POST", false),
            ("https://api.yapper.website/auth/v1/token?grant_type=password", "POST", false),
            ("https://dnfkuqzddwvtdojzgmdm.supabase.co/rest/v1/messages", "POST", false)
        ]
        for (value, method, expected) in samples {
            #expect(BrowserLoginPolicy.isAuthResponse(URL(string: value)!, method: method) == expected)
        }
    }

    @Test func `Main-frame security origin and both page URLs must agree`() {
        let root = URL(string: "https://yapin.gg/")!
        #expect(BrowserLoginPolicy.startURL.absoluteString == "https://yapin.gg/?auth=in")
        #expect(BrowserLoginPolicy.isLoginPage(BrowserLoginPolicy.startURL))
        #expect(BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "https", host: "yapin.gg", port: 443, frameURL: root, currentURL: root))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: false, scheme: "https", host: "yapin.gg", port: 443, frameURL: root, currentURL: root))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "https", host: "challenges.cloudflare.com", port: 443, frameURL: root, currentURL: root))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "http", host: "yapin.gg", port: 80, frameURL: root, currentURL: root))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "https", host: "yapin.gg", port: 444, frameURL: root, currentURL: root))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "https", host: "yapin.gg", port: 443, frameURL: root, currentURL: URL(string: "https://yapin.gg/terms")))
        #expect(!BrowserLoginPolicy.acceptsFrame(isMainFrame: true, scheme: "https", host: "www.yapin.gg", port: 443, frameURL: root, currentURL: root))
    }

    @Test func `Bridge payload is bounded and belongs to the current flow`() throws {
        let flow = UUID()
        let page = URL(string: "https://yapin.gg/")!
        let tokens = try token()
        var body: [String: Any] = ["flow": flow.uuidString, "responseURL": "https://yapin.gg/api/login", "method": "POST", "accessToken": tokens.accessToken, "refreshToken": tokens.refreshToken]
        #expect(try BrowserLoginPolicy.tokens(from: body, flowID: flow, pageURL: page) == tokens)
        #expect(throws: NativeClientError.invalidResponse) { try BrowserLoginPolicy.tokens(from: body, flowID: UUID(), pageURL: page) }
        #expect(throws: NativeClientError.invalidResponse) { try BrowserLoginPolicy.tokens(from: body, flowID: flow, pageURL: URL(string: "https://www.yapin.gg/")!) }
        body["password"] = "not-a-bridge-field"
        #expect(throws: NativeClientError.invalidResponse) { try BrowserLoginPolicy.tokens(from: body, flowID: flow, pageURL: page) }
        body["password"] = nil
        body["accessToken"] = String(repeating: "x", count: 16_385)
        #expect(throws: NativeClientError.invalidResponse) { try BrowserLoginPolicy.tokens(from: body, flowID: flow, pageURL: page) }
    }

    @Test func `A different JWT issuer is rejected before network access`() async throws {
        var requests = 0
        let api = NativeAPI(transport: { _ in requests += 1; throw NativeClientError.invalidEndpoint })
        let foreign = try token(issuer: "https://foreign.example/auth/v1")
        await #expect(throws: NativeClientError.invalidResponse) { try await api.validateBrowserLogin(foreign) }
        #expect(requests == 0)
    }

    @Test func `Decoded metadata is not trusted without HTTPS auth validation`() async throws {
        let api = NativeAPI(transport: { request in try http(request, json: "{\"error\":\"invalid token\"}", status: 401) })
        let candidate = try token()
        await #expect(throws: NativeClientError.api(status: 401, message: "invalid token")) { try await api.validateBrowserLogin(candidate) }
    }

    @Test func `Every verified MFA factor requires an elevated token`() async throws {
        let api = NativeAPI(transport: { request in try http(request, json: authUser(factorType: "phone")) })
        let lower = try token(aal: "aal1")
        let higher = try token(aal: "aal2")
        #expect(try await api.validateBrowserLogin(lower).requiresTwoFactor)
        #expect(try await !api.validateBrowserLogin(higher).requiresTwoFactor)
    }

    @Test func `Browser login saves only after native identity and bootstrap validation`() async throws {
        let gate = BrowserReplyGate()
        let vault = MemorySessionVault()
        let api = NativeAPI(transport: { request in
            if request.url?.path == "/auth/v1/user" { return try http(request, json: authUser()) }
            return await gate.wait()
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        let flow = try #require(store.beginBrowserSignIn())
        let candidate = try token()
        let task = Task { await store.completeBrowserSignIn(tokens: candidate, flowID: flow) }
        await gate.waitUntilWaiting()
        #expect(vault.session == nil)
        #expect(store.authState == .signingIn)
        let request = try api.request(path: "rest/v1/rpc/bootstrap", method: "POST")
        gate.finish(try http(request, json: bootstrap()))
        #expect(await task.value == .signedIn)
        #expect(vault.session?.userID == userID)
        #expect(store.user?.id == userID)
    }

    @Test func `Lower assurance remains in the official verification window without Keychain write`() async throws {
        let vault = MemorySessionVault()
        var bootstraps = 0
        let api = NativeAPI(transport: { request in
            if request.url?.path == "/auth/v1/user" { return try http(request, json: authUser(factorType: "totp")) }
            bootstraps += 1
            return try http(request, json: bootstrap())
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        let flow = try #require(store.beginBrowserSignIn())
        let lower = try token(aal: "aal1")
        let higher = try token(aal: "aal2")
        #expect(await store.completeBrowserSignIn(tokens: lower, flowID: flow) == .requiresTwoFactor)
        #expect(vault.session == nil)
        #expect(bootstraps == 0)
        #expect(await store.completeBrowserSignIn(tokens: higher, flowID: flow) == .signedIn)
        #expect(vault.session?.userID == userID)
    }

    @Test(arguments: [false, true]) func `Cancel or pause invalidates an in-flight handoff`(pause: Bool) async throws {
        let gate = BrowserReplyGate()
        let vault = MemorySessionVault()
        let api = NativeAPI(transport: { request in
            if request.url?.path == "/auth/v1/user" { return try http(request, json: authUser()) }
            return await gate.wait()
        })
        let store = NativeStore(api: api, vault: vault, realtime: nil)
        let flow = try #require(store.beginBrowserSignIn())
        let candidate = try token()
        let task = Task { await store.completeBrowserSignIn(tokens: candidate, flowID: flow) }
        await gate.waitUntilWaiting()
        if pause { store.pauseBrowserSignIn(flowID: flow) }
        else { store.cancelBrowserSignIn(flowID: flow) }
        let request = try api.request(path: "rest/v1/rpc/bootstrap", method: "POST")
        gate.finish(try http(request, json: bootstrap()))
        #expect(await task.value == .rejected)
        #expect(vault.session == nil)
        #expect(store.authState == .signedOut)
    }

    @Test func `A canceled or replaced nonce never starts a request`() async throws {
        var requests = 0
        let api = NativeAPI(transport: { _ in requests += 1; throw NativeClientError.invalidEndpoint })
        let store = NativeStore(api: api, vault: MemorySessionVault(), realtime: nil)
        let old = try #require(store.beginBrowserSignIn())
        let new = try #require(store.beginBrowserSignIn())
        let candidate = try token()
        #expect(await store.completeBrowserSignIn(tokens: candidate, flowID: old) == .rejected)
        store.cancelBrowserSignIn(flowID: new)
        #expect(await store.completeBrowserSignIn(tokens: candidate, flowID: new) == .rejected)
        #expect(requests == 0)
    }

    @Test func `Concurrent duplicate responses do not create a second validation`() async throws {
        let gate = BrowserReplyGate()
        var requests = 0
        let api = NativeAPI(transport: { request in
            requests += 1
            if request.url?.path == "/auth/v1/user" { return await gate.wait() }
            return try http(request, json: bootstrap())
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(), realtime: nil)
        let flow = try #require(store.beginBrowserSignIn())
        let candidate = try token()
        let first = Task { await store.completeBrowserSignIn(tokens: candidate, flowID: flow) }
        await gate.waitUntilWaiting()
        #expect(await store.completeBrowserSignIn(tokens: candidate, flowID: flow) == .rejected)
        #expect(requests == 1)
        let request = try api.request(path: "auth/v1/user")
        gate.finish(try http(request, json: authUser()))
        #expect(await first.value == .signedIn)
    }

    @Test func `Background validation is refused until the app is active`() async throws {
        var requests = 0
        let api = NativeAPI(transport: { _ in requests += 1; throw NativeClientError.invalidEndpoint })
        let store = NativeStore(api: api, vault: MemorySessionVault(), realtime: nil)
        let flow = try #require(store.beginBrowserSignIn())
        store.setActive(false)
        let candidate = try token()
        #expect(await store.completeBrowserSignIn(tokens: candidate, flowID: flow) == .rejected)
        #expect(requests == 0)
    }
}

@MainActor private final class BrowserReplyGate {
    private var waiting: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var ready: CheckedContinuation<Void, Never>?

    func wait() async -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation in
            waiting = continuation
            ready?.resume()
            ready = nil
        }
    }

    func waitUntilWaiting() async {
        if waiting != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func finish(_ value: (Data, HTTPURLResponse)) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: value)
    }
}
