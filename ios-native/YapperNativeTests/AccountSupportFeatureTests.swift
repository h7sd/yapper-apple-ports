import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct AccountSupportFeatureTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let channel = "33333333-3333-4333-8333-333333333333"
    private let message = "44444444-4444-4444-8444-444444444444"
    private var session: NativeSession { NativeSession(accessToken: "synthetic-support-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: own) }
    private func reply(_ request: URLRequest, _ row: NativeJSON) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(row), response)
    }
    private func body(_ request: URLRequest) throws -> NativeJSON { let data = try #require(request.httpBody); return try JSONDecoder().decode(NativeJSON.self, from: data) }
    private func query(_ request: URLRequest) throws -> [URLQueryItem] { let url = try #require(request.url); return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
    private func suggestion(owner: String? = nil) throws -> NativeSuggestion {
        try NativeSuggestion(.object(["id": .string(other), "user_id": .string(owner ?? own), "title": .string("Synthetic idea"), "body": .string("Synthetic details"), "channel_id": .string(channel), "message_id": .string(message)]))
    }

    @Test func `Email change sends normalized email only in the own authenticated PUT body with an official confirmation target`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .object(["id": .string(own), "email": .string("old@example.invalid"), "new_email": .string("new@example.invalid")])) })
        try await api.requestSecurityEmailChange(" New@Example.Invalid ", session: session)
        #expect(requests.count == 1 && requests[0].httpMethod == "PUT")
        #expect(requests[0].url?.host == NativeConfiguration.apiHost && requests[0].url?.path == "/auth/v1/user")
        #expect(try query(requests[0]) == [URLQueryItem(name: "redirect_to", value: "https://www.yapin.gg")])
        #expect(try body(requests[0]) == .object(["email": .string("new@example.invalid")]))
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-support-token")
    }

    @Test func `Invalid email causes no request and email update response cannot cross the own account boundary`() async throws {
        var calls = 0
        let api = NativeAPI(transport: { request in calls += 1; return try reply(request, .object(["user": .object(["id": .string(other)])])) })
        await #expect(throws: (any Error).self) { try await api.requestSecurityEmailChange("not an email", session: session) }
        #expect(calls == 0)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.requestSecurityEmailChange("new@example.invalid", session: session) }
        #expect(calls == 1)
    }

    @Test func `Pending email is displayed from authenticated user data without treating it as the confirmed address`() async throws {
        let api = NativeAPI(transport: { request in try reply(request, .object(["id": .string(own), "email": .string("old@example.invalid"), "new_email": .string("pending@example.invalid"), "factors": .array([])])) })
        let account = try await api.securityAccount(session: session)
        #expect(account.email == "old@example.invalid" && account.pendingEmail == "pending@example.invalid")
    }

    @Test func `Suggestion channels use the observed official HQ and accessible channel names`() async throws {
        let api = NativeAPI(transport: { request in
            #expect(request.url?.lastPathComponent == "visible_server_channels")
            #expect(try body(request) == .object(["sids": .array([.string(NativeAPI.suggestionServerID)])]))
            return try reply(request, .array([
                .object(["id": .string(channel), "server_id": .string(NativeAPI.suggestionServerID), "name": .string("suggestions-new"), "kind": .string("text")]),
                .object(["id": .string(message), "server_id": .string(NativeAPI.suggestionServerID), "name": .string("general"), "kind": .string("text")])
            ]))
        })
        let channels = try await api.nativeSuggestionChannels(session: session)
        #expect(channels.count == 1 && channels[0].id == channel)
    }

    @Test func `Own suggestion history is current-account scoped and rejects a foreign owner in the response`() async throws {
        let api = NativeAPI(transport: { request in
            let items = try query(request)
            #expect(items.contains(URLQueryItem(name: "user_id", value: "eq.\(own)")))
            #expect(items.contains(URLQueryItem(name: "limit", value: "20")))
            return try reply(request, .array([.object(["id": .string(other), "user_id": .string(other), "title": .string("Foreign"), "body": .string("Not ours")])]))
        })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeMySuggestions(session: session) }
    }

    @Test func `Suggestion submission uses exact source form boundaries and channel scoped RPC arguments`() async throws {
        let valid = try NativeServerChannel(.object(["id": .string(channel), "server_id": .string(NativeAPI.suggestionServerID), "name": .string("suggestions"), "kind": .string("text")]), serverID: NativeAPI.suggestionServerID)
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .string(other)) })
        try await api.nativeSubmitSuggestion(channel: valid, title: " Synthetic title ", area: .mobile, body: " More details here ", session: session)
        #expect(requests[0].url?.lastPathComponent == "submit_suggestion")
        #expect(try body(requests[0]) == .object(["cid": .string(channel), "p_title": .string("Synthetic title"), "p_area": .string("mobile"), "p_body": .string("More details here")]))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSubmitSuggestion(channel: valid, title: "Tiny", area: .chat, body: "Long enough body", session: session) }
        #expect(requests.count == 1)
    }

    @Test func `A same named channel on another server cannot become an official suggestion target`() async throws {
        let wrong = try NativeServerChannel(.object(["id": .string(channel), "server_id": .string(other), "name": .string("suggestions"), "kind": .string("text")]), serverID: other)
        var calls = 0
        let api = NativeAPI(transport: { request in calls += 1; return try reply(request, .null) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSubmitSuggestion(channel: wrong, title: "Synthetic", area: .other, body: "Long enough details", session: session) }
        #expect(calls == 0)
    }

    @Test func `Suggestion vote totals remain bound to the requested posted message IDs`() async throws {
        var wrong = false
        let api = NativeAPI(transport: { request in
            #expect(try body(request) == .object(["ids": .array([.string(message)])]))
            return try reply(request, .array([.object(["message_id": .string(wrong ? other : message), "up": .number(5), "down": .number(2), "total": .number(8)])]))
        })
        let votes = try await api.nativeSuggestionVotes(messageIDs: [message], session: session)
        #expect(votes[message]?.up == 5 && votes[message]?.down == 2)
        wrong = true
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSuggestionVotes(messageIDs: [message], session: session) }
    }

    @Test func `Voting removes only the own existing thumb reaction after verifying the message channel`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.url?.lastPathComponent == "messages" { return try reply(request, .array([.object(["id": .string(message), "channel_id": .string(channel)])])) }
            if request.httpMethod == "GET" { return try reply(request, .array([.object(["id": .string(other), "message_id": .string(message), "user_id": .string(own), "emoji": .string("👍")])])) }
            return try reply(request, .array([]))
        })
        try await api.nativeVoteSuggestion(suggestion(), emoji: "👍", session: session)
        #expect(requests.count == 3 && requests[2].httpMethod == "DELETE")
        let items = try query(requests[2])
        #expect(items.contains(URLQueryItem(name: "user_id", value: "eq.\(own)")))
        #expect(items.contains(URLQueryItem(name: "message_id", value: "eq.\(message)")))
        #expect(items.contains(URLQueryItem(name: "emoji", value: "eq.👍")))
    }

    @Test func `An inaccessible or moved suggestion message cannot receive an unverified reaction mutation`() async throws {
        var count = 0
        let api = NativeAPI(transport: { request in count += 1; return try reply(request, .array([])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeVoteSuggestion(suggestion(), emoji: "👎", session: session) }
        #expect(count == 1)
    }
}
