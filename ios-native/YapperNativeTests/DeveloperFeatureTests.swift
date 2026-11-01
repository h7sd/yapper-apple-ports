import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct DeveloperFeatureTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let botID = "22222222-2222-4222-8222-222222222222"
    private let serverID = "33333333-3333-4333-8333-333333333333"
    private var session: NativeSession { NativeSession(accessToken: "synthetic-developer-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: own) }
    private func reply(_ request: URLRequest, _ value: NativeJSON) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), response)
    }
    private func body(_ request: URLRequest) throws -> NativeJSON {
        let data = try #require(request.httpBody); return try JSONDecoder().decode(NativeJSON.self, from: data)
    }
    private var app: NativeJSON { .object(["id": .string(botID), "name": .string("Synthetic app"), "description": .string("Example"), "redirect_uris": .array([.string("https://example.invalid/callback")])]) }

    @Test func `Bot directory uses exact search category and sort parameters and actual profile rows`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            calls.append(request)
            if request.url?.lastPathComponent == "bot_directory" { return try reply(request, .array([.object(["id": .string(botID), "name": .string("Synthetic"), "category": .string("utility"), "command_list": .array([.object(["name": .string("ping"), "description": .string("Check")])]), "commands": .number(1)])])) }
            return try reply(request, .array([.object(["id": .string(botID), "username": .string("synthetic")])]))
        })
        let result = try await api.developerBotDirectory(query: " ping ", category: "utility", sort: "name", session: session)
        #expect(try body(calls[0]) == .object(["q": .string("ping"), "cat": .string("utility"), "sort": .string("name")]))
        #expect(result.first?.commands.first?.name == "ping" && result.first?.profile?.username == "synthetic")
    }

    @Test func `Installation cannot target a server absent from freshly authorized targets`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .array([])) })
        await #expect(throws: (any Error).self) { try await api.developerInstallBot(botID: botID, serverID: serverID, session: session) }
        #expect(calls.count == 1 && calls[0].url?.lastPathComponent == "bot_add_targets")
        #expect(try body(calls[0]) == .object(["bid": .string(botID)]))
    }

    @Test func `Installation rechecks Manage Server targets and sends only selected bot and server`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            calls.append(request)
            if request.url?.lastPathComponent == "bot_add_targets" { return try reply(request, .array([.object(["id": .string(serverID), "name": .string("Managed"), "added": .bool(false)])])) }
            return try reply(request, .null)
        })
        try await api.developerInstallBot(botID: botID, serverID: serverID, session: session)
        #expect(calls.count == 2 && calls[1].url?.lastPathComponent == "bot_add_to_server")
        #expect(try body(calls[1]) == .object(["bid": .string(botID), "sid": .string(serverID)]))
    }

    @Test func `An already installed target causes no duplicate installation`() async throws {
        var count = 0
        let api = NativeAPI(transport: { request in count += 1; return try reply(request, .array([.object(["id": .string(serverID), "name": .string("Managed"), "added": .bool(true)])])) })
        try await api.developerInstallBot(botID: botID, serverID: serverID, session: session)
        #expect(count == 1)
    }

    @Test func `Owned bot listing remains own-account scoped and merges only existing hook IDs`() async throws {
        let api = NativeAPI(transport: { request in
            if request.url?.lastPathComponent == "bots" {
                let url = try #require(request.url); let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.contains(URLQueryItem(name: "owner_id", value: "eq.\(own)")) == true)
                return try reply(request, .array([.object(["id": .string(botID), "name": .string("synthetic")])]))
            }
            return try reply(request, .array([.object(["id": .string(botID), "webhook_url": .string("https://example.invalid/hook")])]))
        })
        let result = try await api.developerOwnedBots(flags: [], session: session)
        #expect(result.first?.webhookURL == "https://example.invalid/hook")
    }

    @Test func `Bot description edits cannot accidentally trigger the weekly username change flow`() async throws {
        let original = try NativeOwnedBot(.object(["id": .string(botID), "name": .string("synthetic"), "description": .string("Original"), "category": .string("utility")]))
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["ok": .bool(true)])) })
        try await api.developerUpdateBot(bot: original, name: original.name, description: "Updated", category: .utility, supportInvite: nil, webhookURL: nil, session: session)
        #expect(try body(calls[0]) == .object(["id": .string(botID), "description": .string("Updated")]))
        #expect(calls[0].url?.absoluteString == "https://www.yapin.gg/api/bots")
    }

    @Test func `Bot token rotation uses the official POST-body authorization contract without URL secrets`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["token": .string("synthetic-new-token")])) })
        #expect(try await api.developerRotateBotToken(id: botID, session: session) == "synthetic-new-token")
        #expect(calls[0].httpMethod == "PATCH" && calls[0].url?.query == nil)
        #expect(try body(calls[0]) == .object(["id": .string(botID), "rotate": .bool(true)]))
        #expect(calls[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-developer-token")
    }

    @Test func `OAuth redirects match the observed HTTPS and local development exceptions`() {
        for value in ["https://example.invalid/callback", "http://localhost:3000/callback", "http://127.0.0.1/a", "http://[::1]:3000/callback"] { #expect(NativeDeveloperInput.redirectURI(value)) }
        for value in ["http://example.invalid/callback", "https://secret@example.invalid/a", "https://example.invalid/#fragment", "https://example.invalid/a b", "javascript:alert(1)"] { #expect(!NativeDeveloperInput.redirectURI(value)) }
    }

    @Test func `OAuth app creation and secret reset use their exact endpoints and response fields`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["app": app, "secret": .string("synthetic-secret")])) })
        let created = try await api.developerCreateOAuthApplication(name: " Synthetic app ", session: session)
        #expect(created.app.id == botID && created.secret == "synthetic-secret")
        #expect(try body(calls[0]) == .object(["name": .string("Synthetic app")]))
        _ = try await api.developerRotateOAuthSecret(id: botID, session: session)
        #expect(calls[1].url?.absoluteString == "https://www.yapin.gg/api/oauth/apps" && calls[1].httpMethod == "PATCH")
        #expect(try body(calls[1]) == .object(["id": .string(botID), "reset_secret": .bool(true)]))
    }

    @Test func `OAuth icon changes cannot save unrelated unsaved name or redirect drafts`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, app) })
        _ = try await api.developerUpdateOAuthIcon(id: botID, path: own + "/icon.webp", session: session)
        #expect(try body(calls[0]) == .object(["p_id": .string(botID), "p_icon_path": .string(own + "/icon.webp")]))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.developerUpdateOAuthIcon(id: botID, path: serverID + "/other.webp", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `OAuth update refuses a different returned application and malformed redirects before transport`() async throws {
        var count = 0
        let api = NativeAPI(transport: { request in count += 1; return try reply(request, .object(["id": .string(serverID), "name": .string("Different"), "redirect_uris": .array([])])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.developerUpdateOAuthApplication(id: botID, name: "Synthetic app", description: "", redirectURIs: ["https://example.invalid/callback"], session: session) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.developerUpdateOAuthApplication(id: botID, name: "Synthetic app", description: "", redirectURIs: ["http://example.invalid/callback"], session: session) }
        #expect(count == 1)
    }

    @Test func `Bot profile multipart upload stays on the official host and cannot exceed the observed cap`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .object(["path": .string(botID + "/avatar.png")])) })
        _ = try await api.developerUploadBotProfileImage(id: botID, kind: "avatar", data: Data([1, 2, 3]), contentType: "image/png", session: session)
        #expect(calls[0].url?.absoluteString == "https://www.yapin.gg/api/bots/profile")
        #expect(calls[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let data = try #require(calls[0].httpBody); let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("name=\"id\"") && text.contains(botID) && text.contains("name=\"kind\"") && text.contains("avatar"))
        await #expect(throws: (any Error).self) { try await api.developerUploadBotProfileImage(id: botID, kind: "avatar", data: Data(count: 4 * 1_024 * 1_024 + 1), contentType: "image/png", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `Bot activities preserve ID ownership and the documented save arguments`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.developerSaveActivity(botID: botID, activityID: nil, name: "Synthetic game", url: "https://example.invalid/activity", emoji: "🎲", description: "Example", session: session)
        #expect(calls[0].url?.lastPathComponent == "bot_activity_save")
        #expect(try body(calls[0]) == .object(["bid": .string(botID), "p_id": .null, "p_name": .string("Synthetic game"), "p_url": .string("https://example.invalid/activity"), "p_emoji": .string("🎲"), "p_description": .string("Example")]))
    }
}
