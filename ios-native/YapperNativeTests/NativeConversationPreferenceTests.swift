import Foundation
import Testing
@testable import YapperNative

@MainActor struct NativeConversationPreferenceTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let channel = "22222222-2222-4222-8222-222222222222"
    private let other = "33333333-3333-4333-8333-333333333333"
    private let server = "44444444-4444-4444-8444-444444444444"
    private var session: NativeSession { NativeSession(accessToken: "synthetic-preferences-access", refreshToken: "synthetic-preferences-refresh", expiresAt: Date().addingTimeInterval(3600), userID: own) }
    private var flags: NativeJSON { .object(Dictionary(uniqueKeysWithValues: ["close_dms", "pin_dms", "quick_notify"].map { ($0, .object(["mode": .string("everyone")])) })) }

    private func response(_ request: URLRequest, _ value: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), http)
    }
    private func body(_ request: URLRequest) throws -> NativeJSON { try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) }
    private func query(_ request: URLRequest, _ name: String) throws -> String? {
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    @Test func `DM feature gates use upstream everyone test users and joined-server targeting`() {
        let targeted = NativeJSON.object([
            "close_dms": .object(["mode": .string("everyone")]),
            "pin_dms": .object(["mode": .string("test"), "users": .array([.string(own)])]),
            "quick_notify": .object(["mode": .string("test"), "servers": .array([.string(server)])])
        ])
        let scoped = NativeConversationPreferenceCapabilities(flags: targeted, userID: own, joinedServerIDs: [server])
        #expect(scoped.hide && scoped.pin && scoped.timedMute)
        let arrayFlags = NativeJSON.array((targeted.object ?? [:]).map { key, value in .object((value.object ?? [:]).merging(["key": .string(key)]) { _, new in new }) })
        #expect(NativeConversationPreferenceCapabilities(flags: arrayFlags, userID: own, joinedServerIDs: [server]) == scoped)
        let stranger = NativeConversationPreferenceCapabilities(flags: targeted, userID: other)
        #expect(stranger.hide && !stranger.pin && !stranger.timedMute)
        let absent = NativeConversationPreferenceCapabilities(flags: .object([:]), userID: own)
        #expect(!absent.hide && !absent.pin && !absent.timedMute)
    }

    @Test func `Preference loading revives hidden chats only after newer messages and honors lifted mutes`() async throws {
        let api = NativeAPI { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-preferences-access")
            switch request.url?.lastPathComponent {
            case "user_dm_pins":
                #expect(try query(request, "user_id") == "eq." + own)
                return try response(request, .array([.object(["pins": .array([.string(other), .string(channel), .string(other), .string("invalid")])])]))
            case "channel_members":
                #expect(try query(request, "user_id") == "eq." + own)
                return try response(request, .array([.object(["channel_id": .string(channel), "hidden_at": .string("2026-10-31T12:00:00Z")]), .object(["channel_id": .string(other), "hidden_at": .string("2026-10-31T12:00:00Z")])]))
            case "channels":
                return try response(request, .array([.object(["id": .string(channel), "kind": .string("dm"), "server_id": .null, "last_message_at": .string("2026-10-31T11:59:00Z")]), .object(["id": .string(other), "kind": .string("group"), "server_id": .null, "last_message_at": .string("2026-10-31T12:01:00Z")])]))
            case "unread_counts_v2": return try response(request, .array([.object(["channel_id": .string(channel), "muted": .bool(true)]), .object(["channel_id": .string(other), "muted": .bool(true)])]))
            case "my_notify_settings": return try response(request, .array([.object(["channel_id": .string(channel), "muted_until": .string("2026-10-31T13:00:00Z")]), .object(["channel_id": .string(other), "lifted": .bool(true)])]))
            default: throw URLError(.unsupportedURL)
            }
        }
        let result = try await api.nativeConversationPreferences(flags: flags, conversationIDs: [channel, other], session: session)
        #expect(result.pins == [other, channel])
        #expect(result.hidden == [channel])
        #expect(result.muted == [channel])
        #expect(result.muteUntil[channel] == (try NativeDate.parse("2026-10-31T13:00:00Z")))
    }

    @Test func `Disabled preference features only read the legacy mute state`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in paths.append(try #require(request.url?.lastPathComponent)); return try response(request, .array([])) }
        let result = try await api.nativeConversationPreferences(flags: .object([:]), conversationIDs: [channel], session: session)
        #expect(paths == ["unread_counts_v2"])
        #expect(result.pins.isEmpty && result.hidden.isEmpty)
    }

    @Test func `Pinning reads current ordered pins before the account-scoped upsert`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in
            paths.append(try #require(request.url?.lastPathComponent))
            if request.httpMethod == "GET" { return try response(request, .array([.object(["pins": .array([.string(other)])])])) }
            #expect(request.httpMethod == "POST")
            #expect(try query(request, "on_conflict") == "user_id")
            #expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal")
            #expect(try body(request) == .object(["user_id": .string(own), "pins": .array([.string(channel), .string(other)])]))
            return try response(request, .null)
        }
        #expect(try await api.nativeSetConversationPinned(channelID: channel, pinned: true, visibleConversationIDs: [channel, other], session: session) == [channel, other])
        #expect(paths == ["user_dm_pins", "user_dm_pins"])
    }

    @Test func `Pinning enforces the observed fifty-chat limit without a write`() async throws {
        let pins = (0..<50).map { String(format: "%08x-aaaa-4aaa-8aaa-aaaaaaaaaaaa", $0) }
        var calls = 0
        let api = NativeAPI { request in
            calls += 1; #expect(request.httpMethod == "GET")
            return try response(request, .array([.object(["pins": .array(pins.map(NativeJSON.string))])]))
        }
        await #expect(throws: (any Error).self) { try await api.nativeSetConversationPinned(channelID: channel, pinned: true, visibleConversationIDs: pins + [channel], session: session) }
        #expect(calls == 1)
    }

    @Test func `Hiding only updates the current membership and requires a returned matching row`() async throws {
        var writes: [NativeJSON] = []
        let api = NativeAPI { request in
            #expect(request.url?.lastPathComponent == "channel_members" && request.httpMethod == "PATCH")
            #expect(try query(request, "channel_id") == "eq." + channel)
            #expect(try query(request, "user_id") == "eq." + own)
            #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
            let value = try body(request); writes.append(value)
            return try response(request, .array([.object(["channel_id": .string(channel), "hidden_at": value["hidden_at"]])]))
        }
        try await api.nativeSetConversationHidden(channelID: channel, hidden: true, at: NativeDate.parse("2026-10-31T12:00:00Z"), session: session)
        try await api.nativeSetConversationHidden(channelID: channel, hidden: false, session: session)
        #expect(writes == [.object(["hidden_at": .string("2026-10-31T12:00:00Z")]), .object(["hidden_at": .null])])
    }

    @Test func `An RLS-filtered empty hide response cannot be reported as success`() async throws {
        let api = NativeAPI { request in try response(request, .array([])) }
        do { try await api.nativeSetConversationHidden(channelID: channel, hidden: true, session: session); Issue.record("Empty membership result must fail") }
        catch let NativeClientError.api(status, _) { #expect(status == 403) }
    }

    @Test func `Timed mute preserves the exact minute values null forever and zero unmute`() async throws {
        var values: [NativeJSON] = []
        let api = NativeAPI { request in
            #expect(request.url?.lastPathComponent == "set_notify_mute")
            let value = try body(request); values.append(value)
            if value["mins"].int == 15 { return try response(request, .string("2026-10-31T12:15:00Z")) }
            return try response(request, .null)
        }
        let until = try await api.nativeMuteConversation(channelID: channel, duration: .fifteenMinutes, timed: true, session: session)
        #expect(until == (try NativeDate.parse("2026-10-31T12:15:00Z")))
        try await api.nativeMuteConversation(channelID: channel, duration: .forever, timed: true, session: session)
        try await api.nativeMuteConversation(channelID: channel, duration: .off, timed: true, session: session)
        #expect(values == [.object(["cid": .string(channel), "mins": .number(15)]), .object(["cid": .string(channel), "mins": .null]), .object(["cid": .string(channel), "mins": .number(0)])])
    }

    @Test func `Legacy mute never invents timed values and uses set_muted Boolean`() async throws {
        var values: [NativeJSON] = []
        let api = NativeAPI { request in #expect(request.url?.lastPathComponent == "set_muted"); values.append(try body(request)); return try response(request, .null) }
        try await api.nativeMuteConversation(channelID: channel, duration: .forever, timed: false, session: session)
        try await api.nativeMuteConversation(channelID: channel, duration: .off, timed: false, session: session)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeMuteConversation(channelID: channel, duration: .oneHour, timed: false, session: session) }
        #expect(values == [.object(["cid": .string(channel), "mute": .bool(true)]), .object(["cid": .string(channel), "mute": .bool(false)])])
    }

    @Test func `Malformed identities and unrelated visibility rows fail before a misleading mutation`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSetConversationHidden(channelID: "../someone", hidden: true, session: session) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeMuteConversation(channelID: "not-a-channel", duration: .forever, timed: false, session: session) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSetConversationPinned(channelID: channel, pinned: true, visibleConversationIDs: [other], session: session) }
        #expect(calls == 0)
    }
}
