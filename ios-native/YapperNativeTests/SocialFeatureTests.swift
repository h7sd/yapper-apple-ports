import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct SocialFeatureTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let channel = "33333333-3333-4333-8333-333333333333"

    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-social-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: own)
    }

    private func reply(_ request: URLRequest, _ value: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), response)
    }

    private func profile(_ id: String) -> NativeJSON {
        .object(["id": .string(id), "username": .string(id == own ? "demo" : "nova"), "display_name": .string("Native test"), "bio": .string("Synthetic profile")])
    }

    private func requestBody(_ request: URLRequest) throws -> NativeJSON {
        let data = try #require(request.httpBody)
        return try JSONDecoder().decode(NativeJSON.self, from: data)
    }

    private func requestComponents(_ value: URL?) throws -> URLComponents {
        let url = try #require(value)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    }

    @Test func `Social snapshot preserves incoming outgoing and blocked relations`() async throws {
        let api = NativeAPI(transport: { request in
            switch request.url?.lastPathComponent {
            case "friendships":
                return try reply(request, .array([.object(["requester": .string(peer), "addressee": .string(own), "status": .string("pending"), "note": .string("Test")])]))
            case "blocks": return try reply(request, .array([.object(["blocked": .string(peer)])]))
            case "dm_requests": return try reply(request, .array([.object(["from_id": .string(peer)])]))
            case "profiles": return try reply(request, .array([profile(peer)]))
            default: throw URLError(.unsupportedURL)
            }
        })
        let result = try await api.socialSnapshot(session: session)
        #expect(result.friends.count == 1)
        #expect(result.friends.first?.relation == .incoming)
        #expect(result.friends.first?.requestNote == "Test")
        #expect(result.blocked.first?.id == peer)
        #expect(result.requests.first?.id == peer)
    }

    @Test func `Malformed social payload is an error rather than an empty friend list`() async throws {
        let api = NativeAPI(transport: { request in try reply(request, .object(["unexpected": .bool(true)])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.socialSnapshot(session: session) }
    }

    @Test func `Friend actions use observed RPC names and exact parameters`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .null) })
        try await api.friendAction(.request(username: "@nova", note: "hello"), session: session)
        try await api.friendAction(.respond(other: peer, accept: true), session: session)
        try await api.friendAction(.remove(peer), session: session)
        try await api.friendAction(.block(peer), session: session)
        try await api.friendAction(.unblock(peer), session: session)
        #expect(requests.compactMap { $0.url?.lastPathComponent } == ["send_friend_request", "respond_friend_request", "remove_friend", "block_user", "unblock_user"])
        let first = try requestBody(requests[0])
        #expect(first["target_username"].string == "nova")
        #expect(first["note"].string == "hello")
        let second = try requestBody(requests[1])
        #expect(second.object?.count == 2)
        #expect(second["other"].string == peer)
        #expect(second["accept"].bool == true)
    }

    @Test func `A malformed peer identifier cannot cause a friend mutation`() async throws {
        var calls = 0
        let api = NativeAPI(transport: { request in calls += 1; return try reply(request, .null) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.friendAction(.block("bad?id=other"), session: session) }
        #expect(calls == 0)
    }

    @Test func `Opening a DM validates the returned actual channel identifier`() async throws {
        let output = SocialTestResponseBox(.string(channel))
        let api = NativeAPI(transport: { request in
            if request.url?.lastPathComponent == "channel_members" {
                #expect(request.httpMethod == "PATCH")
                let body = try requestBody(request)
                #expect(body == .object(["hidden_at": .null]))
                let query = try requestComponents(request.url).queryItems ?? []
                #expect(query.contains(URLQueryItem(name: "channel_id", value: "eq." + channel)))
                #expect(query.contains(URLQueryItem(name: "user_id", value: "eq." + own)))
                return try reply(request, .array([.object(["channel_id": .string(channel), "hidden_at": .null])]))
            }
            #expect(request.url?.lastPathComponent == "get_or_create_dm")
            let body = try requestBody(request)
            #expect(body.object?.count == 1 && body["other"].string == peer)
            return try reply(request, output.value)
        })
        #expect(try await api.openSocialDM(userID: peer, session: session) == channel)
        output.value = .string("not-a-channel")
        await #expect(throws: NativeClientError.invalidResponse) { try await api.openSocialDM(userID: peer, session: session) }
    }

    @Test func `Profile update remains own-account scoped and carries crop and status fields`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .array([profile(own)])) })
        var draft = NativeProfileDraft(profile: try NativeProfileDetail(row: profile(own)))
        draft.bio = "Updated"
        draft.customStatus = "Working"
        draft.accentColor = "#FF6B4A"
        _ = try await api.saveSocialProfile(profileID: own, draft: draft, session: session)
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "PATCH")
        let components = try requestComponents(requests[0].url)
        #expect(components.queryItems?.contains(URLQueryItem(name: "id", value: "eq.\(own)")) == true)
        let body = try requestBody(requests[0])
        #expect(body["bio"].string == "Updated")
        #expect(body["custom_status"].string == "Working")
        #expect(body["avatar_zoom"].number == 1)
        #expect(body["accent_color"].string == "#FF6B4A")
        await #expect(throws: NativeClientError.invalidResponse) { try await api.saveSocialProfile(profileID: peer, draft: draft, session: session) }
        #expect(requests.count == 1)
    }

    @Test func `A successful profile HTTP response cannot replace the current account`() async throws {
        let api = NativeAPI(transport: { request in try reply(request, .array([profile(peer)])) })
        let draft = NativeProfileDraft(profile: try NativeProfileDetail(row: profile(own)))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.saveSocialProfile(profileID: own, draft: draft, session: session) }
    }

    @Test func `Inbox unread state obeys seen keys and read-before boundary`() throws {
        let before = try NativeDate.parse("2026-10-31T12:00:00Z")
        let row: NativeJSON = .object(["key": .string("friend:test"), "kind": .string("friend"), "at": .string("2026-10-31T12:05:00Z"), "user_id": .string(peer)])
        #expect(try NativeInboxItem(row: row, readBefore: before, readKeys: []).isUnread)
        #expect(try !NativeInboxItem(row: row, readBefore: before, readKeys: ["friend:test"]).isUnread)
        #expect(try !NativeInboxItem(row: row, readBefore: before.addingTimeInterval(600), readKeys: []).isUnread)
        var seen = try #require(row.object); seen["seen"] = .bool(true)
        #expect(try !NativeInboxItem(row: .object(seen), readBefore: before, readKeys: []).isUnread)
    }

    @Test func `Inbox marking sends only the intended keys and caps the batch`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .null) })
        try await api.markSocialInbox(keys: ["a", "b"], all: false, session: session)
        let body = try requestBody(requests[0])
        #expect(requests[0].url?.lastPathComponent == "inbox_mark")
        #expect(body["keys"].array.compactMap(\.string) == ["a", "b"])
        await #expect(throws: NativeClientError.invalidResponse) { try await api.markSocialInbox(keys: Array(repeating: "a", count: 51), all: false, session: session) }
        #expect(requests.count == 1)
    }

    @Test func `Private notes never target a different owner`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .null) })
        try await api.saveSocialUserNote(userID: peer, note: "Note", session: session)
        let body = try requestBody(requests[0])
        #expect(body["owner_id"].string == own)
        #expect(body["about_id"].string == peer)
        #expect(body["note"].string == "Note")
        try await api.saveSocialUserNote(userID: peer, note: "", session: session)
        #expect(requests[1].httpMethod == "DELETE")
        #expect(requests[1].url?.query?.contains(own) == true)
        #expect(requests[1].url?.query?.contains(peer) == true)
    }

    @Test func `Group creation deduplicates membership and requires a real channel response`() async throws {
        let api = NativeAPI(transport: { request in
            let body = try requestBody(request)
            #expect(request.url?.lastPathComponent == "create_group")
            #expect(body["member_ids"].array.compactMap(\.string) == [peer])
            #expect(body["group_name"].string == "Native")
            #expect(body["group_icon"] == .null)
            return try reply(request, .string(channel))
        })
        #expect(try await api.createSocialGroup(name: " Native ", members: [peer, peer], session: session) == channel)
    }

    @Test func `Status preference validates the exact allowed presence values`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .null) })
        try await api.setSocialPresence("dnd", session: session)
        #expect(requests[0].url?.lastPathComponent == "set_status_pref")
        let body = try requestBody(requests[0])
        #expect(body["p"].string == "dnd")
        await #expect(throws: NativeClientError.invalidResponse) { try await api.setSocialPresence("made-up", session: session) }
        #expect(requests.count == 1)
    }

    @Test func `Suggested people use the observed explicit refresh contract and shared interest fields`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.url?.lastPathComponent == "my_matches" {
                return try reply(request, .array([.object(["user_id": .string(peer), "items_n": .number(2), "items": .array([.object(["kind": .string("game"), "title": .string("Synthetic game")])]), "servers_n": .number(1), "servers": .array([.string("Synthetic server")])])]))
            }
            return try reply(request, .array([profile(peer)]))
        })
        let result = try await api.socialMatches(refresh: true, session: session)
        let body = try requestBody(requests[0])
        #expect(body == .object(["p_refresh": .bool(true)]))
        #expect(result.first?.id == peer && result.first?.interestCount == 2)
        #expect(result.first?.sharedInterests == ["Synthetic game"])
        #expect(result.first?.sharedServers == ["Synthetic server"])
    }

    @Test func `Interest matching visibility defaults only on an actual missing own setting and upserts the own identity`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, request.httpMethod == "GET" ? .array([]) : .null) })
        #expect(try await api.socialMatchVisibility(session: session))
        try await api.setSocialMatchVisibility(false, session: session)
        let body = try requestBody(requests[1])
        #expect(body["user_id"].string == own && body["suggest_me"].bool == false)
        #expect(requests[1].value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates")
        let malformed = NativeAPI(transport: { request in try reply(request, .object([:])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await malformed.socialMatchVisibility(session: session) }
    }

    @Test func `Server tag choices include only joined tagged active servers`() async throws {
        let api = NativeAPI(transport: { request in
            if request.url?.lastPathComponent == "server_members" { return try reply(request, .array([.object(["server_id": .string(channel)]), .object(["server_id": .string(peer)])])) }
            return try reply(request, .array([.object(["id": .string(channel), "name": .string("Active"), "tag": .string("TAG"), "tag_icon": .string("server")]), .object(["id": .string(peer), "name": .string("Closed"), "tag": .string("OLD"), "shut_down_at": .string("2026-01-01T00:00:00Z")])]))
        })
        let result = try await api.socialServerTags(session: session)
        #expect(result.count == 1 && result.first?.id == channel && result.first?.tag == "TAG")
    }

    @Test func `Wearing removing and hiding a tag call the actual server tag operations`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try reply(request, .null) })
        try await api.wearSocialServerTag(channel, session: session)
        try await api.wearSocialServerTag(nil, session: session)
        try await api.setSocialTagIconShown(false, session: session)
        #expect(requests[0].url?.lastPathComponent == "set_server_tag")
        #expect(try requestBody(requests[0]) == .object(["sid": .string(channel)]))
        #expect(try requestBody(requests[1]) == .object(["sid": .null]))
        #expect(requests[2].url?.lastPathComponent == "set_tag_icon_shown")
        #expect(try requestBody(requests[2]) == .object(["p_show": .bool(false)]))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.wearSocialServerTag("../other", session: session) }
        #expect(requests.count == 3)
    }

    @Test func `Temporary avatar scheduling retains the original image and sends the actual revert timestamp`() async throws {
        var original = try NativeProfileDetail(row: profile(own)); original.avatarPath = own + "/original.png"
        let until = Date().addingTimeInterval(3_600)
        let replacement = own + "/r2-replacement.png"
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            return try reply(request, .array([.object(["id": .string(own), "username": .string("demo"), "avatar_path": .string(replacement), "avatar_revert_at": .string(ISO8601DateFormatter().string(from: until))])]))
        })
        let result = try await api.saveSocialProfile(profileID: own, draft: NativeProfileDraft(profile: original), avatarPath: replacement, avatarRevertAt: until, previousProfile: original, session: session)
        let body = try requestBody(requests[0])
        #expect(body["avatar_path"].string == replacement && body["avatar_revert_at"].string != nil)
        #expect(result.avatarRevertAt != nil)
        #expect(requests.count == 1) // The retained permanent avatar must not be removed.
    }

    @Test func `Keeping a temporary avatar clears the schedule before cleaning only the acknowledged previous own image`() async throws {
        let previous = own + "/original.png", current = own + "/r2-current.png"
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.url?.lastPathComponent == "my_avatar_prev_path" { return try reply(request, .string(previous)) }
            if request.url?.lastPathComponent == "profiles" { return try reply(request, .array([.object(["id": .string(own), "username": .string("demo"), "avatar_path": .string(current), "avatar_revert_at": .null])])) }
            return try reply(request, .object(["ok": .bool(true)]))
        })
        let result = try await api.keepSocialTemporaryAvatar(session: session)
        #expect(result.avatarPath == current && result.avatarRevertAt == nil)
        #expect(requests.count == 3)
        #expect(requests[1].httpMethod == "PATCH")
        #expect(try requestBody(requests[1]) == .object(["avatar_revert_at": .null]))
        #expect(requests[2].url?.absoluteString == "https://www.yapin.gg/api/media/remove")
        #expect(try requestBody(requests[2]) == .object(["bucket": .string("avatars"), "path": .string(previous)]))
    }

    @Test func `Crop dragging applies cover overflow inverse rotation and bounded source positions`() {
        let start = NativeImageCrop.centered
        let shifted = start.translated(start: start, dx: 25, dy: 10, width: 100, height: 100, imageWidth: 200, imageHeight: 100)
        #expect(shifted.x == 25 && shifted.y == 50)
        let rotated = NativeImageCrop(zoom: 2, rotation: 90)
        let drag = rotated.translated(start: rotated, dx: 30, dy: 0, width: 100, height: 100, imageWidth: 200, imageHeight: 100)
        #expect(abs(drag.x - 50) < 0.0001 && abs(drag.y - 80) < 0.0001)
        let bounded = start.translated(start: start, dx: -1_000, dy: 0, width: 100, height: 100, imageWidth: 200, imageHeight: 100)
        #expect(bounded.x == 100)
    }

    @Test func `Expired statuses are not resurrected by editing another profile field`() throws {
        var original = try NativeProfileDetail(row: profile(own))
        original.customStatus = "Expired"; original.customStatusUntil = Date(timeIntervalSince1970: 1)
        original.avatarZoom = 3.5 // Preserve valid existing metadata when a text field changes.
        let draft = NativeProfileDraft(profile: original)
        let values = try draft.values()
        #expect(values["custom_status"] == .null && values["custom_status_until"] == .null)
        #expect(values["avatar_zoom"]?.number == 3.5)
    }
}

@MainActor private final class SocialTestResponseBox {
    var value: NativeJSON
    init(_ value: NativeJSON) { self.value = value }
}
