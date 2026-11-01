import Foundation
import Testing
@testable import YapperNative

@MainActor struct NativeServerOrganizationTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let first = "22222222-2222-4222-8222-222222222222"
    private let second = "33333333-3333-4333-8333-333333333333"
    private let category = "44444444-4444-4444-8444-444444444444"
    private var session: NativeSession { NativeSession(accessToken: "synthetic-server-organization-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: own) }
    private func response(_ request: URLRequest, _ value: NativeJSON) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), http)
    }
    private func body(_ request: URLRequest) throws -> NativeJSON { try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) }
    private var group: NativeServerFolder { NativeServerFolder(id: "fexample", name: "Freunde", color: "#5865f2", servers: [second, first]) }

    @Test func `Folder decoding bounds names and preserves the first unique server assignment`() {
        let rows: NativeJSON = .array([.object(["id": .string("one"), "name": .string(String(repeating: "a", count: 40)), "color": .string("#5865f2"), "servers": .array([.string(first), .string(second), .string(first), .string("bad")])]), .object(["id": .string("two"), "color": .string("bad"), "servers": .array([.string(second)])])])
        let folders = NativeServerOrganization.decodeFolders(rows)
        #expect(folders.count == 1 && folders[0].servers == [first, second])
        #expect(folders[0].name?.count == 32 && folders[0].color == "#5865f2")
    }

    @Test func `Rail ordering uses saved order and collapses folders with only one joined server`() {
        let value = NativeServerOrganization(folders: [group], order: [second, first])
        #expect(value.items(serverIDs: [first, second]).map(\.id) == ["f:fexample"])
        #expect(value.items(serverIDs: [first]).map(\.id) == [first])
        #expect(value.items(serverIDs: [first, second]).first?.serverIDs == [second, first])
    }

    @Test func `Organization loading filters the current account and skips folders when disabled`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in
            paths.append(try #require(request.url?.lastPathComponent))
            let url = try #require(request.url), components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.contains(.init(name: "id", value: "eq." + own)) == true)
            return try response(request, .array([.object(["id": .string(own), "server_order": .array([.string(second), .string(first)])])]))
        }
        let value = try await api.nativeServerOrganization(foldersEnabled: false, session: session)
        #expect(value.order == [second, first] && value.folders.isEmpty)
        #expect(paths == ["profiles"])
    }

    @Test func `Folder and order save uses observed upsert then own-profile patch`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in
            paths.append(try #require(request.url?.lastPathComponent))
            let value = try body(request)
            if request.httpMethod == "POST" {
                #expect(value == .object(["user_id": .string(own), "folders": .array([group.wire])]))
                #expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=minimal")
                return try response(request, .null)
            }
            #expect(request.httpMethod == "PATCH" && value == .object(["server_order": .array([.string(second), .string(first)])]))
            let url = try #require(request.url), components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.queryItems?.contains(.init(name: "id", value: "eq." + own)) == true)
            return try response(request, .array([.object(["id": .string(own)])]))
        }
        let value = try await api.nativeSaveServerOrganization([.group(group)], knownServerIDs: [first, second], previous: .init(folders: [], order: [first, second]), foldersEnabled: true, session: session)
        #expect(value.folders == [group] && value.order == [second, first])
        #expect(paths == ["user_server_folders", "profiles"])
    }

    @Test func `An RLS-denied order save restores previous folders and throws`() async throws {
        var folderWrites: [NativeJSON] = []
        let api = NativeAPI { request in
            if request.httpMethod == "POST" { folderWrites.append(try body(request)); return try response(request, .null) }
            return try response(request, .array([]))
        }
        do { _ = try await api.nativeSaveServerOrganization([.group(group)], knownServerIDs: [first, second], previous: .init(folders: [], order: [first, second]), foldersEnabled: true, session: session); Issue.record("Denied profile write must throw") }
        catch let NativeClientError.api(status, _) { #expect(status == 403) }
        #expect(folderWrites.count == 2)
        #expect(folderWrites.last?["folders"] == .array([]))
    }

    @Test func `Missing duplicate and unauthorized folder members fail without writes`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        for items in [[NativeServerOrganizationItem.server(first)], [.server(first), .server(first)], [.group(group)]] {
            await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSaveServerOrganization(items, knownServerIDs: [first, second], previous: .init(folders: [], order: []), foldersEnabled: false, session: session) }
        }
        #expect(calls == 0)
    }

    @Test func `Server channel and category notification levels preserve exact null and none contracts`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI { request in requests.append(request); return try response(request, .null) }
        try await api.nativeSetServerNotificationLevel(.all, target: .server(first), session: session)
        try await api.nativeSetServerNotificationLevel(.some(.none), target: .channel(serverID: first, channelID: second), session: session)
        try await api.nativeSetServerNotificationLevel(nil, target: .channel(serverID: first, channelID: second), session: session)
        try await api.nativeSetServerNotificationLevel(.mentions, target: .category(serverID: first, categoryID: category), session: session)
        #expect(try body(requests[0]) == .object(["sid": .string(first), "cid": .null, "lvl": .string("all")]))
        #expect(try body(requests[1]) == .object(["sid": .string(first), "cid": .string(second), "lvl": .string("none")]))
        #expect(try body(requests[2])["lvl"] == .null)
        #expect(requests[3].url?.lastPathComponent == "set_category_level")
        #expect(try body(requests[3]) == .object(["cat": .string(category), "lvl": .string("mentions")]))
    }

    @Test func `Server channel and category mutes use the observed target-specific RPCs`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI { request in requests.append(request); return try response(request, .null) }
        try await api.nativeMuteServerNotifications(.forever, target: .server(first), session: session)
        try await api.nativeMuteServerNotifications(.fifteenMinutes, target: .channel(serverID: first, channelID: second), session: session)
        try await api.nativeMuteServerNotifications(.off, target: .category(serverID: first, categoryID: category), session: session)
        #expect(requests.map { $0.url?.lastPathComponent } == ["set_server_mute", "set_notify_mute", "set_category_mute"])
        #expect(try body(requests[0]) == .object(["sid": .string(first), "mins": .null]))
        #expect(try body(requests[1]) == .object(["cid": .string(second), "mins": .number(15)]))
        #expect(try body(requests[2]) == .object(["cat": .string(category), "mins": .number(0)]))
    }

    @Test func `Notification state preserves levels expiry and lifted mute state`() async throws {
        let api = NativeAPI { request in
            switch request.url?.lastPathComponent {
            case "my_notify_settings": return try response(request, .array([.object(["server_id": .string(first), "level": .string("all")]), .object(["channel_id": .string(second), "level": .string("none"), "lifted": .bool(true)])]))
            case "server_mutes": return try response(request, .array([.object(["server_id": .string(first), "muted_until": .string("2026-10-31T13:00:00Z")])]))
            default: return try response(request, .array([.object(["channel_id": .string(second), "muted": .bool(true)])]))
            }
        }
        let state = try await api.nativeServerNotificationState(session: session)
        #expect(state.levels[first] == .all && state.levels[second] == .some(.none))
        #expect(!state.muted.contains(second))
        #expect(state.isMuted(first, now: try NativeDate.parse("2026-10-31T12:59:00Z")))
        #expect(!state.isMuted(first, now: try NativeDate.parse("2026-10-31T13:01:00Z")))
    }

    @Test func `Invalid notification target and server-default reset cannot send writes`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeSetServerNotificationLevel(nil, target: .server(first), session: session) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeMuteServerNotifications(.off, target: .channel(serverID: first, channelID: "bad"), session: session) }
        #expect(calls == 0)
    }

    @Test func `Ticket close uses the observed RPC and cannot close an ordinary channel`() async throws {
        var calls = 0
        let api = NativeAPI { request in
            calls += 1
            #expect(request.url?.lastPathComponent == "close_ticket")
            #expect(try body(request) == .object(["cid": .string(second)]))
            return try response(request, .null)
        }
        let ticket = try NativeServerChannel(.object(["id": .string(second), "server_id": .string(first), "kind": .string("text"), "name": .string("ticket"), "ticket_by": .string(own)]), serverID: first)
        try await api.nativeCloseServerTicket(channel: ticket, session: session)
        let ordinary = try NativeServerChannel(.object(["id": .string(second), "server_id": .string(first), "kind": .string("text"), "name": .string("general")]), serverID: first)
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeCloseServerTicket(channel: ordinary, session: session) }
        #expect(calls == 1)
    }
}
