import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct SecurityFeatureTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let factor = "33333333-3333-4333-8333-333333333333"
    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-security-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: own)
    }

    private func reply(_ request: URLRequest, _ value: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), response)
    }

    private func requestBody(_ request: URLRequest) throws -> NativeJSON {
        let data = try #require(request.httpBody)
        return try JSONDecoder().decode(NativeJSON.self, from: data)
    }

    private func requestComponents(_ value: URL?) throws -> URLComponents {
        let url = try #require(value)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }

    @Test func `Passkey rename preserves opaque IDs and enforces the observed 40 character form limit`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.renameSecurityPasskey(id: "opaque-passkey_id", name: " iPhone ", session: session)
        let body = try requestBody(calls[0])
        #expect(calls[0].url?.lastPathComponent == "rename_passkey")
        #expect(body.object?.count == 2)
        #expect(body["p_id"].string == "opaque-passkey_id")
        #expect(body["p_name"].string == "iPhone")
        await #expect(throws: (any Error).self) { try await api.renameSecurityPasskey(id: "opaque-passkey_id", name: String(repeating: "x", count: 41), session: session) }
        #expect(calls.count == 1)
    }

    @Test func `OAuth revoke targets the selected existing application grant`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.revokeSecurityOAuthGrant(id: other, session: session)
        let body = try requestBody(calls[0])
        #expect(calls[0].url?.lastPathComponent == "oauth_revoke")
        #expect(body.object?.count == 1 && body["p_app_id"].string == other)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.revokeSecurityOAuthGrant(id: "", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `Security account and factor listing refuses a different authenticated account`() async throws {
        let identity = SecurityTestIdentity(own)
        let api = NativeAPI(transport: { request in
            #expect(request.url?.path == "/auth/v1/user")
            return try reply(request, .object(["id": .string(identity.value), "email": .string("synthetic@example.invalid"), "factors": .array([.object(["id": .string(factor), "factor_type": .string("totp"), "status": .string("verified"), "friendly_name": .string("Authenticator")])])]))
        })
        let account = try await api.securityAccount(session: session)
        #expect(account.factors.count == 1)
        #expect(account.factors.first?.isVerified == true)
        identity.value = other
        await #expect(throws: NativeClientError.invalidResponse) { try await api.securityAccount(session: session) }
    }

    @Test func `TOTP enrollment uses the exact SDK contract and a validated matching native QR URI`() async throws {
        let secret = "JBSWY3DPEHPK3PXP"
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            return try reply(request, .object(["id": .string(factor), "type": .string("totp"), "totp": .object(["secret": .string(secret), "uri": .string("otpauth://totp/Yapper:synthetic?secret=\(secret)&issuer=Yapper"), "qr_code": .string("<svg>Not rendered as browser content</svg>")])]))
        })
        let setup = try await api.enrollSecurityTOTP(name: "Authenticator", session: session)
        #expect(setup.id == factor && setup.secret == secret)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/auth/v1/factors")
        let body = try requestBody(requests[0])
        #expect(body.object?.count == 2)
        #expect(body["factor_type"].string == "totp")
        #expect(body["friendly_name"].string == "Authenticator")
        let wrongURI: NativeJSON = .object(["id": .string(factor), "type": .string("totp"), "totp": .object(["secret": .string(secret), "uri": .string("https://untrusted.invalid/?secret=\(secret)")])])
        #expect(throws: NativeClientError.invalidResponse) { try NativeTOTPEnrollment(row: wrongURI) }
    }

    @Test func `TOTP QR and manual secret cannot disagree`() throws {
        let row: NativeJSON = .object(["id": .string(factor), "type": .string("totp"), "totp": .object(["secret": .string("JBSWY3DPEHPK3PXP"), "uri": .string("otpauth://totp/Yapper?secret=AAAAAAAAAAAAAAAA")])])
        #expect(throws: NativeClientError.invalidResponse) { try NativeTOTPEnrollment(row: row) }
        #expect(NativeSecurityInput.code("１２ ٣٤-56") == "123456")
    }

    @Test func `Factor removal cannot escape its UUID-bound HTTPS auth route`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["id": .string(factor)])) })
        try await api.removeSecurityFactor(id: factor, session: session)
        #expect(calls[0].httpMethod == "DELETE")
        #expect(calls[0].url?.path == "/auth/v1/factors/\(factor)")
        #expect(calls[0].url?.host == NativeConfiguration.apiHost)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.removeSecurityFactor(id: "../user", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `DM privacy update is own-account scoped and requires a confirmed matching row`() async throws {
        let target = SecurityTestIdentity(own)
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .array([.object(["id": .string(target.value), "dms_from": .string("friends")])])) })
        try await api.saveSecurityDMPrivacy(.friends, session: session)
        #expect(calls[0].httpMethod == "PATCH")
        let query = try requestComponents(calls[0].url).queryItems
        #expect(query?.contains(URLQueryItem(name: "id", value: "eq.\(own)")) == true)
        let body = try requestBody(calls[0])
        #expect(body.object?.count == 1 && body["dms_from"].string == "friends")
        target.value = other
        await #expect(throws: NativeClientError.invalidResponse) { try await api.saveSecurityDMPrivacy(.friends, session: session) }
    }

    @Test func `Password change sends secrets in the official POST body rather than URL parameters`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["ok": .bool(true)])) })
        try await api.changeSecurityPassword(current: "synthetic-old", replacement: "synthetic-new", session: session)
        #expect(calls[0].httpMethod == "POST")
        #expect(calls[0].url?.absoluteString == "https://www.yapin.gg/api/account/password")
        #expect(calls[0].url?.query == nil)
        let body = try requestBody(calls[0])
        #expect(body.object?.count == 2)
        #expect(body["current"].string == "synthetic-old")
        #expect(body["password"].string == "synthetic-new")
    }

    @Test func `Global logout signals the service and uses auth global scope`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.securityLogoutEverywhere(session: session)
        #expect(calls.count == 2)
        #expect(calls[0].url?.lastPathComponent == "logout_everywhere_signal")
        #expect(calls[1].url?.path == "/auth/v1/logout")
        #expect(calls[1].url?.query == "scope=global")
        #expect(calls[1].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-security-token")
    }
}

@MainActor private final class SecurityTestIdentity {
    var value: String
    init(_ value: String) { self.value = value }
}
