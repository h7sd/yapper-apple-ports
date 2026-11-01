import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeMessageAdvancedTests {
    @MainActor private final class ReplyFixture { var foreign = false }
    private let user = "11111111-1111-4111-8111-111111111111"
    private let channel = "22222222-2222-4222-8222-222222222222"
    private let message = "33333333-3333-4333-8333-333333333333"
    private let interaction = "44444444-4444-4444-8444-444444444444"
    private let server = "55555555-5555-4555-8555-555555555555"
    private var session: NativeSession { NativeSession(accessToken: "synthetic", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: user) }
    private func response(_ request: URLRequest, _ json: NativeJSON) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try JSONEncoder().encode(json), http)
    }
    private func body(_ request: URLRequest) throws -> NativeJSON { try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) }
    private func button(disabled: Bool = false) throws -> NativeMessageButton { try #require(NativeMessageButton(.object(["style": .string("primary"), "label": .string("Bestätigen"), "custom_id": .string("confirm:1"), "disabled": .bool(disabled)]))) }
    private func poll(anonymous: Bool = false) throws -> NativePoll { try NativePoll(.object(["id": .string(interaction), "message_id": .string(message), "question": .string("Welche Option?"), "options": .array([.object(["id": .string("1"), "text": .string("A")]), .object(["id": .string("2"), "text": .string("B")])]), "anonymous": .bool(anonymous)])) }
    private func state(anonymous: Bool = false, visible: Bool = true) throws -> NativePollViewState { NativePollViewState(poll: try poll(anonymous: anonymous), results: [], visible: visible, voted: false, total: 0, correct: [], youRight: nil) }

    @Test func `Incoming buttons keep source bounds and reject credential or executable links`() throws {
        #expect(NativeMessageButton(.object(["style": .string("link"), "label": .string("Unsafe"), "url": .string("https://user:secret@example.com/")])) == nil)
        #expect(NativeMessageButton(.object(["style": .string("link"), "label": .string("Unsafe"), "url": .string("javascript:alert(1)")])) == nil)
        let item = NativeJSON.object(["style": .string("secondary"), "label": .string("A"), "custom_id": .string("a")])
        let row = NativeJSON.object(["type": .string("row"), "components": .array(Array(repeating: item, count: 9))])
        let parsed = NativeMessageComponent.parse(Array(repeating: row, count: 9))
        #expect(parsed.count == 5)
        for value in parsed { if case let .buttons(buttons) = value { #expect(buttons.count == 5) } else { Issue.record("Expected native button row") } }
        #expect(!NativeMessageComponent.isV2([row]))
        #expect(NativeMessageComponent.isV2([.object(["type": .number(17)])]))
        #expect(NativeMessageComponent.parse([.object(["type": .number(999)])]).isEmpty)
    }

    @Test func `Press uses observed custom ID and refuses disabled or link controls before transport`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try response(request, .string(interaction)) })
        #expect(try await api.pressMessageButton(messageID: message, button: button(), session: session) == interaction)
        #expect(requests.count == 1)
        #expect(requests[0].url?.path.hasSuffix("/press_button") == true)
        #expect(try body(requests[0]) == .object(["mid": .string(message), "button": .string("confirm:1")]))
        await #expect(throws: NativeClientError.invalidResponse) { _ = try await api.pressMessageButton(messageID: message, button: button(disabled: true), session: session) }
        let link = try #require(NativeMessageButton(.object(["style": .string("link"), "label": .string("Website"), "url": .string("https://example.com/")])))
        await #expect(throws: NativeClientError.invalidResponse) { _ = try await api.pressMessageButton(messageID: message, button: link, session: session) }
        #expect(requests.count == 1)
    }

    @Test func `Ephemeral replies require own interaction and channel but not an invented message ID binding`() async throws {
        let fixture = ReplyFixture()
        var captured: URLRequest?
        let api = NativeAPI(transport: { request in
            captured = request
            return try response(request, .array([.object(["id": .string(server), "interaction_id": .string(interaction), "user_id": .string(fixture.foreign ? message : user), "channel_id": .string(channel), "message_id": .null, "kind": .string("ephemeral"), "content": .string("Nur für dich"), "embeds": .array([])])]))
        })
        let rows = try await api.messageButtonReplies(interactionID: interaction, messageID: message, channelID: channel, session: session)
        #expect(rows.map(\.content) == ["Nur für dich"])
        let url = try #require(captured?.url)
        #expect(url.path.hasSuffix("/bot_interaction_replies"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "interaction_id", value: "eq.\(interaction)")) == true)
        fixture.foreign = true
        await #expect(throws: NativeClientError.invalidResponse) { _ = try await api.messageButtonReplies(interactionID: interaction, messageID: message, channelID: channel, session: session) }
    }

    @Test func `Anonymous hidden and wrong-server voter rosters never reach transport`() async throws {
        var calls = 0
        let api = NativeAPI(transport: { request in calls += 1; return try response(request, .array([])) })
        let capabilities = NativeCapabilities(flags: .object(["quiz_polls": .object(["mode": .string("test"), "servers": .array([.string(server)])])]), joinedServerIDs: [server])
        await #expect(throws: (any Error).self) { _ = try await api.pollVoters(state: state(anonymous: true), optionID: "1", capabilities: capabilities, serverID: server, session: session) }
        await #expect(throws: (any Error).self) { _ = try await api.pollVoters(state: state(visible: false), optionID: "1", capabilities: capabilities, serverID: server, session: session) }
        await #expect(throws: (any Error).self) { _ = try await api.pollVoters(state: state(), optionID: "1", capabilities: capabilities, serverID: channel, session: session) }
        #expect(calls == 0)
    }

    @Test func `Voter pagination sends the exact timestamp-user cursor and enriches native profiles`() async throws {
        var rosterRequest: URLRequest?
        let cursor = try NativePollVoter(.object(["user_id": .string(message), "voted_at": .string("2026-10-30T12:00:00Z")]))
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("/poll_voters") == true {
                rosterRequest = request
                return try response(request, .array([.object(["user_id": .string(user), "voted_at": .string("2026-10-30T11:00:00Z")])]))
            }
            if request.url?.path.hasSuffix("/profiles") == true { return try response(request, .array([.object(["id": .string(user), "username": .string("demo"), "display_name": .string("Demo")])])) }
            return try response(request, .array([]))
        })
        let capabilities = NativeCapabilities(flags: .array([.object(["key": .string("quiz_polls"), "mode": .string("everyone")])]))
        let rows = try await api.pollVoters(state: state(), optionID: "1", before: cursor, capabilities: capabilities, serverID: nil, session: session)
        #expect(rows.first?.profile?.displayName == "Demo")
        #expect(try body(#require(rosterRequest)) == .object(["pid": .string(interaction), "opt": .string("1"), "before_at": .string(cursor.votedAt), "before_uid": .string(cursor.userID), "lim": .number(50)]))
    }

    @Test func `Global search transmits null channel with real date author mention and server scopes`() async throws {
        var captured: [NativeJSON] = []
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("/search_messages_v4") == true {
                captured.append(try body(request))
                return try response(request, .array([.object(["id": .string(message), "channel_id": .string(interaction), "author_id": .string(user), "created_at": .string("2026-10-31T02:30:00+02:00"), "content": .string("Hallo <@\(user)>")])]))
            }
            return try response(request, .array([.object(["id": .string(user), "username": .string("demo")])]))
        })
        let search = NativeMessageSearch(query: "Hallo", author: user, before: "2026-10-31T01:00:00Z", since: "2026-10-31T00:00:00Z", mention: user)
        #expect(try await api.searchMessages(search, channelID: nil, session: session).count == 1)
        #expect(captured[0]["cid"] == .null && captured[0]["sid"] == .null)
        #expect(captured[0]["mention"].string == user)
        #expect(captured[0]["before"].string == search.before)
        _ = try await api.searchMessages(search, channelID: nil, serverID: server, session: session)
        #expect(captured[1]["sid"].string == server)
        #expect(!search.matches(.object(["created_at": .string("2026-10-30T23:59:59Z"), "author_id": .string(user), "content": .string("<@\(user)>")])))
    }
}
