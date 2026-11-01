import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct CommunityFeatureTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let server = "33333333-3333-4333-8333-333333333333"
    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-community-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3_600), userID: own)
    }
    private let balance: NativeJSON = .object(["balance": .number(25), "earned": .number(100), "level": .number(2), "next_cost": .number(50)])

    private func reply(_ request: URLRequest, _ value: NativeJSON) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
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

    @Test func `Community flags require public rollout or an actual allowed user or joined server`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            calls.append(request)
            if request.url?.lastPathComponent == "my_flags" {
                return try reply(request, .array([
                    .object(["key": .string("shards"), "mode": .string("everyone")]),
                    .object(["key": .string("verification"), "mode": .string("test"), "users": .array([.string(own)])]),
                    .object(["key": .string("community_decos"), "mode": .string("test"), "servers": .array([.string(server)])]),
                    .object(["key": .string("disabled"), "mode": .string("off"), "users": .array([.string(own)])]),
                    .object(["key": .string("other_user_only"), "mode": .string("test"), "users": .array([.string(other)])])
                ]))
            }
            let query = try requestComponents(request.url).queryItems
            #expect(query?.contains(URLQueryItem(name: "user_id", value: "eq.\(own)")) == true)
            #expect(query?.contains(URLQueryItem(name: "server_id", value: "in.(\(server))")) == true)
            return try reply(request, .array([.object(["server_id": .string(server)])]))
        })
        let flags = try await api.communityFlags(session: session)
        #expect(flags == ["shards", "verification", "community_decos"])
        #expect(calls.count == 2)
    }

    @Test func `Malformed rollout data is an error rather than enabling hidden features`() async throws {
        let api = NativeAPI(transport: { request in try reply(request, .object(["key": .string("shards")])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.communityFlags(session: session) }
    }

    @Test func `Quest reward claim sends only the observed key and trusts the returned balance`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, balance) })
        let result = try await api.claimCommunityQuest(key: "daily_messages", session: session)
        #expect(calls[0].url?.lastPathComponent == "claim_shard_quest")
        #expect(try requestBody(calls[0]) == .object(["p_key": .string("daily_messages")]))
        #expect(result.balance == 25 && result.level == 2)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.claimCommunityQuest(key: "", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `Ledger pagination preserves the server cursor while rejecting filter injection`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .array([])) })
        _ = try await api.communityLedger(before: "120", session: session)
        let query = try requestComponents(calls[0].url).queryItems
        #expect(query?.contains(URLQueryItem(name: "id", value: "lt.120")) == true)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.communityLedger(before: "120,other.eq.1", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `Leaderboards resolve actual profiles and distinguish message scores from levels`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            calls.append(request)
            if request.url?.lastPathComponent == "leaderboard_page" {
                return try reply(request, .object(["top": .array([.object(["id": .string(other), "pos": .number(1), "score": .number(200)])]), "me": .object(["pos": .number(8), "score": .number(30)]), "hidden": .bool(true)]))
            }
            return try reply(request, .array([.object(["id": .string(other), "username": .string("synthetic"), "display_name": .string("Synthetic")])]))
        })
        let result = try await api.communityLeaderboard(.messagesWeek, session: session)
        #expect(try requestBody(calls[0]) == .object(["p_board": .string("messages_week")]))
        #expect(result.rows.first?.profile?.displayName == "Synthetic")
        #expect(result.rows.first?.score == 200 && result.ownPosition == 8 && result.hidden)
    }

    @Test func `Decoration purchase uses the visible price and equips the exact kind field on the own profile`() async throws {
        let decoration = try NativeCommunityDecoration(row: .object(["id": .string(other), "name": .string("Synthetic effect"), "path": .string("community/effect.webp")]), kind: .profile, price: 75, owned: false)
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            calls.append(request)
            if request.url?.lastPathComponent == "buy_community_deco" { return try reply(request, balance) }
            return try reply(request, .array([.object(["id": .string(own), "profile_effect": .string("p:community/effect.webp")])]))
        })
        _ = try await api.buyCommunityDecoration(decoration, session: session)
        try await api.equipCommunityDecoration(decoration, kind: .profile, session: session)
        #expect(try requestBody(calls[0]) == .object(["p_id": .string(other), "p_price": .number(75)]))
        #expect(try requestBody(calls[1]) == .object(["profile_effect": .string("p:community/effect.webp")]))
        let query = try requestComponents(calls[1].url).queryItems
        #expect(query?.contains(URLQueryItem(name: "id", value: "eq.\(own)")) == true)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.equipCommunityDecoration(decoration, kind: .avatar, session: session) }
        #expect(calls.count == 2)
    }

    @Test func `An absent or different updated profile cannot be reported as a successful preference change`() async throws {
        let api = NativeAPI(transport: { request in try reply(request, .array([.object(["id": .string(other), "leaderboard_hidden": .bool(true)])])) })
        await #expect(throws: NativeClientError.invalidResponse) { try await api.setCommunityLeaderboardHidden(true, session: session) }
    }

    @Test func `Reports target the selected message with the web reason contract`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.reportCommunityTarget(.message(other), reason: .minorSafety, details: " Context ", session: session)
        #expect(calls[0].url?.lastPathComponent == "report_message")
        #expect(try requestBody(calls[0]) == .object(["mid": .string(other), "why": .string("minor_safety"), "more": .string("Context")]))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.reportCommunityTarget(.message("../other"), reason: .spam, details: "", session: session) }
        #expect(calls.count == 1)
    }

    @Test func `Bug submission binds ownership and preserves private proofs without accepting external or foreign paths`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        let proof = own + "/proof.webp"
        try await api.saveCommunityBugReport(title: "Synthetic title", body: "A synthetic report describing a reproducible issue.", severity: "normal", images: [proof], session: session)
        #expect(calls[0].httpMethod == "POST" && calls[0].url?.lastPathComponent == "bug_reports")
        #expect(try requestBody(calls[0])["user_id"].string == own)
        #expect(try requestBody(calls[0])["images"] == .array([.string(proof)]))
        for invalid in [other + "/proof.webp", own + "/../secret.png", "https://external.invalid/image.png"] {
            await #expect(throws: NativeClientError.invalidResponse) { try await api.saveCommunityBugReport(title: "Synthetic title", body: "A synthetic report describing a reproducible issue.", severity: "normal", images: [invalid], session: session) }
        }
        #expect(calls.count == 1)
    }

    @Test func `Bug editing preserves attachments and uses the observed edit and withdraw RPCs`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        let proof = own + "/original.png"
        try await api.saveCommunityBugReport(id: other, title: "Updated synthetic", body: "An updated reproducible synthetic report body.", severity: "security", images: [proof], session: session)
        try await api.withdrawCommunityBugReport(id: other, session: session)
        #expect(calls[0].url?.lastPathComponent == "edit_bug_report")
        #expect(try requestBody(calls[0])["bid"].string == other)
        #expect(try requestBody(calls[0])["p_images"] == .array([.string(proof)]))
        #expect(calls[1].url?.lastPathComponent == "withdraw_bug_report")
        #expect(try requestBody(calls[1]) == .object(["bid": .string(other)]))
    }

    @Test func `Malformed stored proof attachments cannot silently become an empty editable list`() throws {
        let row: NativeJSON = .object(["id": .string(other), "title": .string("Synthetic"), "body": .string("Synthetic report"), "images": .array([.number(1)])])
        #expect(throws: NativeClientError.invalidResponse) { try NativeBugReport(row: row) }
    }

    @Test func `Verification application sends the private path and rejects credential-bearing proof links`() async throws {
        var calls: [URLRequest] = []
        let api = NativeAPI(transport: { request in calls.append(request); return try reply(request, .null) })
        try await api.submitCommunityVerification(platform: "youtube", handle: " synthetic ", link: "https://example.invalid/synthetic", note: "Context", proofPath: own + "/proof.jpg", session: session)
        #expect(calls[0].url?.lastPathComponent == "apply_verification")
        #expect(try requestBody(calls[0]) == .object(["p_platform": .string("youtube"), "p_handle": .string("synthetic"), "p_link": .string("https://example.invalid/synthetic"), "p_note": .string("Context"), "p_proof_path": .string(own + "/proof.jpg")]))
        await #expect(throws: NativeClientError.invalidResponse) { try await api.submitCommunityVerification(platform: "youtube", handle: "synthetic", link: "https://secret@example.invalid/", note: "", proofPath: nil, session: session) }
        #expect(calls.count == 1)
    }
}
