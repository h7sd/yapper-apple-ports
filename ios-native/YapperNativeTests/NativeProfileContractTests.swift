import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeProfileContractTests {
    private let userID = "11111111-1111-4111-8111-111111111111"
    private let channelID = "22222222-2222-4222-8222-222222222222"
    private let messageID = "33333333-3333-4333-8333-333333333333"
    private let replyID = "44444444-4444-4444-8444-444444444444"

    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-profile-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: userID)
    }

    private func response(_ request: URLRequest, _ value: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), http)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    private func profile(_ id: String) -> NativeJSON {
        .object(["id": .string(id), "username": .string("fixture"), "display_name": .string("Fixture Author"), "banner_path": .string("fixture/banner.png"), "avatar_path": .string("fixture/avatar.png")])
    }

    private func message(_ id: String) -> NativeJSON {
        .object(["id": .string(id), "channel_id": .string(channelID), "author_id": .string(userID), "content": .string("Hello"), "created_at": .string("2026-11-01T12:00:00Z")])
    }

    nonisolated enum MessageUse: CaseIterable, Sendable { case reply, pinned, search }

    @Test(arguments: MessageUse.allCases)
    func `Message author hydration works when wildcard profile reads are denied`(_ use: MessageUse) async throws {
        var profileRequests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-profile-token")
            #expect(request.url?.host == NativeConfiguration.apiHost)
            if request.url?.lastPathComponent == "profiles" {
                profileRequests.append(request)
                if query(request, "select") == "*" {
                    return try response(request, .object(["code": .string("42501"), "message": .string("permission denied for table profiles")]), status: 403)
                }
                #expect(query(request, "id") == "in.(\(userID))")
                let columns = Set((query(request, "select") ?? "").split(separator: ",").map(String.init))
                #expect(columns.isSuperset(of: ["id", "username", "display_name", "avatar_path", "banner_path"]))
                #expect(columns.isDisjoint(with: ["*", "server_order", "avatar_prev_path"]))
                return try response(request, .array([profile(userID)]))
            }
            if request.url?.lastPathComponent == "reactions" { return try response(request, .array([])) }
            if use == .reply, query(request, "select") != "*" {
                return try response(request, .array([.object(["id": .string(messageID), "reply_to_id": .string(replyID)])]))
            }
            return try response(request, .array([message(use == .reply ? replyID : messageID)]))
        })

        // This transport models the real column-grant failure, while public columns remain readable.
        let wildcard = try api.request(path: "rest/v1/profiles", query: [.init(name: "select", value: "*")], token: session.accessToken)
        await #expect(throws: NativeClientError.api(status: 403, message: "permission denied for table profiles")) {
            _ = try await api.dataResponse(request: wildcard)
        }
        profileRequests = []

        let author: YapperUser
        switch use {
        case .reply:
            let features = try await api.messageFeatures(ids: [messageID], channelID: channelID, session: session)
            author = try #require(features.replies[replyID]).author
        case .pinned:
            author = try #require(try await api.pinnedMessages(channelID: channelID, session: session).first).message.author
        case .search:
            author = try #require(try await api.searchMessages(NativeMessageSearch(query: "Hello"), channelID: channelID, session: session).first).message.author
        }
        #expect(author.id == userID)
        #expect(author.displayName == "Fixture Author")
        #expect(author.avatarURL?.path == "/avatars/fixture/avatar.png")
        #expect(profileRequests.count == 1)
        #expect(query(try #require(profileRequests.first), "select") != "*")
    }

    @Test func `Own and social profile reads preserve public banner fields and account filters`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-profile-token")
            #expect(query(request, "select")?.split(separator: ",").contains("banner_path") == true)
            #expect(query(request, "select")?.split(separator: ",").contains("*") == false)
            if request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json" {
                #expect(query(request, "id") == "eq.\(userID)")
                return try response(request, profile(userID))
            }
            #expect(query(request, "id") == "in.(\(userID))")
            return try response(request, .array([profile(userID)]))
        })
        #expect(try await api.profile(id: userID, session: session).id == userID)
        let social = try #require(try await api.socialProfiles(ids: [userID, userID], session: session).first)
        #expect(social.bannerPath == "fixture/banner.png")
        #expect(social.bannerURL?.path == "/banners/fixture/banner.png")
        #expect(requests.count == 2)
    }

    @Test func `Public profile reads reject foreign duplicate or unnamed rows`() async {
        for rows in [[profile(replyID)], [profile(userID), profile(userID)], [.object(["id": .string(userID), "username": .string("")])]] {
            let api = NativeAPI(transport: { request in try response(request, .array(rows)) })
            await #expect(throws: NativeClientError.invalidResponse) { _ = try await api.publicProfiles(ids: [userID], session: session) }
        }
    }

    @Test func `Profile batching requests only validated bounded identities`() async throws {
        let ids = (0..<101).map { String(format: "55555555-5555-4555-8555-%012d", $0) }
        var batches: [[String]] = []
        let api = NativeAPI(transport: { request in
            let filter = try #require(query(request, "id"))
            let batch = String(filter.dropFirst(4).dropLast()).split(separator: ",").map(String.init)
            batches.append(batch)
            return try response(request, .array(batch.map(profile)))
        })
        #expect(try await api.publicProfiles(ids: ids + [ids[0]], session: session).count == 101)
        #expect(batches.map(\.count) == [100, 1])
        #expect(Set(batches.flatMap { $0 }) == Set(ids))
        #expect(try await api.publicProfiles(ids: [], session: session).isEmpty)
        await #expect(throws: NativeClientError.invalidResponse) { _ = try await api.publicProfiles(ids: ["not-an-id"], session: session) }
        #expect(batches.count == 2)
    }

    @Test func `Public profile authorization errors remain visible and do not trigger another endpoint`() async {
        var count = 0
        let api = NativeAPI(transport: { request in
            count += 1
            return try response(request, .object(["message": .string("permission denied for table profiles")]), status: 403)
        })
        await #expect(throws: NativeClientError.api(status: 403, message: "permission denied for table profiles")) {
            _ = try await api.publicProfiles(ids: [userID], session: session)
        }
        #expect(count == 1)
    }

    @Test func `URLSession and Swift cancellation share the cancellation path`() async {
        for failure: any Error in [URLError(.cancelled), NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), CancellationError()] {
            let api = NativeAPI(transport: { _ in throw failure })
            await #expect(throws: CancellationError.self) { _ = try await api.bootstrap(session: session) }
        }
        let failed = NativeAPI(transport: { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError(.notConnectedToInternet)) { _ = try await failed.bootstrap(session: session) }
    }
}
