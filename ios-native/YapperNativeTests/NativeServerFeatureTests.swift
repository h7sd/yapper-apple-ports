import Foundation
import Testing
@testable import YapperNative

@MainActor struct NativeServerFeatureTests {
    private let serverID = "11111111-1111-4111-8111-111111111111"
    private let userID = "22222222-2222-4222-8222-222222222222"
    private let channelID = "33333333-3333-4333-8333-333333333333"
    private let categoryID = "44444444-4444-4444-8444-444444444444"
    private let otherID = "55555555-5555-4555-8555-555555555555"
    private let roleID = "66666666-6666-4666-8666-666666666666"

    private var session: NativeSession { NativeSession(accessToken: "synthetic-native-server-access", refreshToken: "synthetic-native-server-refresh", expiresAt: Date().addingTimeInterval(3600), userID: userID) }

    private func response(_ request: URLRequest, _ body: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(body), http)
    }

    private func server(owner: String? = nil, everyone: [String: NativeJSON] = [:]) -> NativeJSON {
        .object(["id": .string(serverID), "name": .string("Synthetic server"), "owner_id": .string(owner ?? userID), "everyone_perms": .object(everyone)])
    }

    private func role(auto: String = "none", permissions: [String: NativeJSON] = [:], position: Int = 5) throws -> NativeServerRole {
        try NativeServerRole(.object(["id": .string(roleID), "server_id": .string(serverID), "name": .string("Synthetic role"), "auto": .string(auto), "position": .number(Double(position)), "perms": .object(permissions)]), serverID: serverID)
    }

    private func serverLoadResponse(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        switch request.url?.lastPathComponent {
        case "bootstrap":
            return try response(request, .object(["profiles": .array([.object(["id": .string(userID), "username": .string("synthetic")])]), "dm_channels": .array([]), "dm_members": .array([])]))
        case "server_members": return try response(request, .array([.object(["server_id": .string(serverID)])]))
        case "servers": return try response(request, .array([server()]))
        case "profiles": return try response(request, .array([.object(["id": .string(userID), "server_order": .array([.string(serverID)])])]))
        case "visible_server_channels", "channel_roles", "channel_post_roles", "channel_categories", "roles", "server_role_assignments", "server_members_slice":
            return try response(request, .array([]))
        default: throw URLError(.unsupportedURL)
        }
    }

    @Test(arguments: [false, true]) func `A canceled server request stays quiet and a retry loads content`(detail: Bool) async throws {
        var cancelRequest = true
        let route = detail ? "servers" : "server_members"
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == route, cancelRequest { throw URLError(.cancelled) }
            return try serverLoadResponse(request)
        }
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        let model = NativeServerLoadProbe(store: store, serverID: serverID, detail: detail)
        await model.refresh()
        #expect(model.error == nil)
        #expect(!model.isLoading && !model.hasContent)
        #expect(store.authState == .signedIn)
        cancelRequest = false
        await model.refresh()
        #expect(model.hasContent && !model.isLoading)
        #expect(model.error == nil)
    }

    @Test func `Canceling server organization leaves the loaded library available for a retry`() async throws {
        var cancelOrganization = true
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == "profiles", cancelOrganization { throw URLError(.cancelled) }
            return try serverLoadResponse(request)
        }
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        let model = NativeServerLibraryModel(store: store)
        await model.refresh()
        #expect(model.servers.map(\.id) == [serverID])
        #expect(!model.isLoading && !model.organization.isLoaded)
        #expect(model.error == nil && model.organization.error == nil)
        cancelOrganization = false
        await model.refresh()
        #expect(model.organization.isLoaded)
        #expect(model.organization.value.order == [serverID])
        #expect(model.error == nil && model.organization.error == nil)
    }

    @Test(arguments: [false, true]) func `An already canceled view task cannot supersede an active server load`(detail: Bool) async throws {
        let gate = NativeServerLoadGate()
        var shouldWait = true
        let route = detail ? "servers" : "server_members"
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == route, shouldWait {
                shouldWait = false
                await gate.wait()
            }
            return try serverLoadResponse(request)
        }
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        let model = NativeServerLoadProbe(store: store, serverID: serverID, detail: detail)
        let pending = Task { await model.refresh() }
        await gate.started()
        let obsoleteViewTask = Task { await model.refresh() }
        obsoleteViewTask.cancel()
        await obsoleteViewTask.value
        #expect(model.isLoading)
        gate.finish()
        await pending.value
        #expect(model.hasContent && !model.isLoading)
        #expect(model.error == nil)
    }

    @Test(arguments: [false, true], [false, true]) func `A failed server refresh preserves content and reports network or permission failures`(detail: Bool, forbidden: Bool) async throws {
        var failRequest = false
        let route = detail ? "servers" : "server_members"
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == route, failRequest {
                if forbidden { return try response(request, .object(["message": .string("Serverzugriff verweigert")]), status: 403) }
                throw URLError(.notConnectedToInternet)
            }
            return try serverLoadResponse(request)
        }
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        let model = NativeServerLoadProbe(store: store, serverID: serverID, detail: detail)
        await model.refresh()
        #expect(model.hasContent)
        failRequest = true
        await model.refresh()
        #expect(model.hasContent && !model.isLoading)
        #expect(model.error == (forbidden ? "Serverzugriff verweigert" : URLError(.notConnectedToInternet).localizedDescription))
        #expect(store.authState == .signedIn)
    }

    @Test(arguments: [false, true]) func `A server request completing after logout cannot publish its content`(detail: Bool) async throws {
        let gate = NativeServerLoadGate()
        let route = detail ? "servers" : "server_members"
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == route { await gate.wait() }
            return try serverLoadResponse(request)
        }
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        let model = NativeServerLoadProbe(store: store, serverID: serverID, detail: detail)
        let pending = Task { await model.refresh() }
        await gate.started()
        store.signOut()
        gate.finish()
        await pending.value
        #expect(!model.hasContent && !model.isLoading)
        #expect(model.error == nil)
        #expect(store.authState == .signedOut)
    }

    @Test func `Invite links accept only the official service and a bounded code`() throws {
        #expect(try NativeServerInput.inviteCode(" Abc12345 ") == "Abc12345")
        #expect(try NativeServerInput.inviteCode("https://yapin.gg/invite/Abc12345") == "Abc12345")
        #expect(try NativeServerInput.inviteCode("https://www.yapper.website/invite/a-b_c") == "a-b_c")
        for text in ["https://yapin.gg.evil.invalid/invite/code", "https://name:secret@yapin.gg/invite/code", "http://yapin.gg/invite/code", "https://yapin.gg:8443/invite/code", "https://yapin.gg/invite/code?token=secret", "../code", "file:///invite/code", "https://yapin.gg/invite/a/b"] {
            #expect(throws: (any Error).self) { try NativeServerInput.inviteCode(text) }
        }
    }

    @Test func `Owner and manual roles match the observed server permission boundary`() throws {
        let ownerServer = try NativeServer(server())
        let owner = NativeServerSnapshot(server: ownerServer, channels: [], categories: [], members: [], roles: [], memberRoles: [:])
        #expect(owner.hasPermission("manage_channels", userID: userID))
        #expect(!owner.hasPermission("manage_channels", userID: nil))
        let managed = try NativeServer(server(owner: otherID, everyone: ["send_messages": .bool(false)]))
        let manual = try role(permissions: ["manage_channels": .bool(true)])
        let snapshot = NativeServerSnapshot(server: managed, channels: [], categories: [], members: [], roles: [manual], memberRoles: [userID: [roleID]])
        #expect(snapshot.hasPermission("manage_channels", userID: userID))
        #expect(!snapshot.hasPermission("ban_members", userID: userID))
        #expect(!snapshot.hasPermission("send_messages", userID: userID))
        #expect(snapshot.hasPermission("create_invite", userID: userID))
    }

    @Test func `Automatic decorative roles cannot grant administrator privileges`() throws {
        let automatic = try role(auto: "all", permissions: ["administrator": .bool(true)])
        let snapshot = NativeServerSnapshot(server: try NativeServer(server(owner: otherID)), channels: [], categories: [], members: [], roles: [automatic], memberRoles: [userID: [roleID]])
        #expect(!snapshot.hasPermission("manage_server", userID: userID))
        #expect(snapshot.topPosition(userID) == -1)
        #expect(!snapshot.outranks(otherID, userID: userID))
        #expect(!snapshot.outranks(userID, userID: userID))
    }

    @Test func `Unknown categories preserve their visible channels instead of dropping them`() throws {
        let channel = try NativeServerChannel(.object(["id": .string(channelID), "server_id": .string(serverID), "name": .string("general"), "kind": .string("text"), "category_id": .string(categoryID)]), serverID: serverID)
        let snapshot = NativeServerSnapshot(server: try NativeServer(server()), channels: [channel], categories: [], members: [], roles: [], memberRoles: [:])
        #expect(snapshot.uncategorized.map(\.id) == [channelID])
        #expect(channel.conversation.serverID == serverID)
    }

    @Test func `Membership loading rejects an unrelated server response`() async throws {
        var calls = 0
        let api = NativeAPI { request in
            calls += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-native-server-access")
            if request.url?.path.hasSuffix("server_members") == true { return try response(request, .array([.object(["server_id": .string(serverID)])])) }
            return try response(request, .array([.object(["id": .string(otherID), "name": .string("Unrelated server")])]))
        }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeServers(session: session) }
        #expect(calls == 2)
    }

    @Test func `Channel creation uses the observed kind and category RPC without guessing a table insert`() async throws {
        var routes: [String] = []
        let api = NativeAPI { request in
            let path = try #require(request.url?.path); routes.append(path)
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            if path.hasSuffix("create_channel") {
                #expect(body["sid"].string == serverID)
                #expect(body["channel_name"].string == "discussion")
                #expect(body["channel_kind"].string == "forum")
                return try response(request, .string(channelID))
            }
            #expect(body["chid"].string == channelID)
            #expect(body["cid"].string == categoryID)
            #expect(body["ids"] == .null)
            return try response(request, .null)
        }
        let created = try await api.nativeCreateChannel(serverID: serverID, name: " discussion ", kind: "forum", categoryID: categoryID, session: session)
        #expect(created == channelID)
        #expect(routes.map { URL(fileURLWithPath: $0).lastPathComponent } == ["create_channel", "set_channel_category"])
    }

    @Test func `A denied channel deletion cannot be reported as success`() async throws {
        let api = NativeAPI { request in
            #expect(request.httpMethod == "DELETE")
            #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
            return try response(request, .array([]))
        }
        do { try await api.nativeDeleteChannel(id: channelID, session: session); Issue.record("Deletion with no returned row must fail") }
        catch let NativeClientError.api(status, _) { #expect(status == 403) }
    }

    @Test func `Invalid local server identities never initiate an authenticated request`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeServerSnapshot(id: "../messages", session: session) }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeCreateChannel(serverID: "not-an-id", name: "general", kind: "text", categoryID: nil, session: session) }
        #expect(calls == 0)
    }

    @Test func `Forum pagination keeps the stable tie-breaking ID and requested filters`() async throws {
        let previous = try NativeForumPost(.object(["id": .string(channelID), "name": .string("Old post"), "created_at": .string("2026-01-01T00:00:00Z"), "last_message_at": .string("2026-02-01T00:00:00Z")]))
        let api = NativeAPI { request in
            #expect(request.url?.path.hasSuffix("list_forum_posts") == true)
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            #expect(body["p_before_id"].string == channelID)
            #expect(body["p_before"].string == previous.lastMessageAt)
            #expect(body["p_tags"] == .array([.string(roleID)]))
            #expect(body["p_q"].string == "query")
            #expect(body["p_following"].bool == true)
            #expect(body["p_limit"].int == 25)
            return try response(request, .array([]))
        }
        let result = try await api.nativeForumPosts(channelID: otherID, query: " query ", tags: [roleID], following: true, before: previous, session: session)
        #expect(result.isEmpty)
    }

    @Test func `Malformed server and cross-server channel records fail visibly`() {
        #expect(throws: (any Error).self) { try NativeServer(.object(["id": .string(serverID)])) }
        #expect(throws: (any Error).self) { try NativeServerChannel(.object(["id": .string(channelID), "server_id": .string(otherID), "kind": .string("text"), "name": .string("general")]), serverID: serverID) }
    }

    @Test func `Audit filtering and pagination use the observed server RPC arguments`() async throws {
        let snapshot = NativeServerSnapshot(server: try NativeServer(server()), channels: [], categories: [], members: [], roles: [], memberRoles: [:])
        let api = NativeAPI { request in
            #expect(request.url?.path.hasSuffix("server_audit_list") == true)
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            #expect(body["sid"].string == serverID)
            #expect(body["before"].string == "2026-01-01T00:00:00Z")
            #expect(body["act"].string == "channel_create")
            #expect(body["who"].string == userID)
            #expect(body["lim"].int == 50)
            return try response(request, .array([]))
        }
        let result = try await api.nativeServerTool(.audit, snapshot: snapshot, before: "2026-01-01T00:00:00Z", auditAction: "channel_create", auditActor: userID, session: session)
        #expect(result.isEmpty)
    }

    @Test func `Invalid event timing fails before sending an authenticated mutation`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        let start = Date()
        do {
            try await api.nativeEventSave(serverID: serverID, eventID: nil, title: "Event", description: "", starts: start, ends: start.addingTimeInterval(-1), channelID: channelID, location: nil, announceID: nil, repeatRule: "none", coverPath: nil, session: session)
            Issue.record("An event ending before it starts must be refused")
        } catch let NativeClientError.api(status, _) { #expect(status == 400) }
        #expect(calls == 0)
    }

    @Test func `Emoji names are checked before acquiring any upload URL`() async throws {
        var calls = 0
        let api = NativeAPI { request in calls += 1; return try response(request, .null) }
        do {
            try await api.nativeAddServerEmoji(serverID: serverID, name: "bad emoji name", data: Data([0]), contentType: "image/png", animated: false, session: session)
            Issue.record("Invalid emoji name must be rejected before upload")
        } catch let NativeClientError.api(status, _) { #expect(status == 400) }
        #expect(calls == 0)
    }

    @Test func `Application questions and declined retry state decode without changing server state`() throws {
        let value = NativeJSON.object(["apply": .bool(true), "questions": .array([.string("Why this community?")]), "request": .object(["status": .string("declined"), "note": .string("Try later"), "retry_at": .string("2030-01-01T00:00:00Z")])])
        let application = try NativeServerApplication(value)
        #expect(application.apply)
        #expect(application.questions == ["Why this community?"])
        #expect(application.requestStatus == "declined")
        #expect(application.note == "Try later")
        #expect(application.retryAt != nil)
    }

    @Test func `Applying preserves ordered answers and treats joined false as pending`() async throws {
        let api = NativeAPI { request in
            #expect(request.url?.path.hasSuffix("apply_to_server") == true)
            let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
            #expect(body["invite_code"].string == "Abc12345")
            #expect(body["p_answers"] == .array([.string("First answer"), .string("Second answer")]))
            #expect(body["p_message"].string == "Hello")
            return try response(request, .object(["joined": .bool(false), "server_id": .string(serverID)]))
        }
        let joined = try await api.nativeApplyToServer(code: "https://yapin.gg/invite/Abc12345", message: "Hello", answers: ["First answer", "Second answer"], session: session)
        #expect(joined == nil)
    }

    @Test func `Invitation preview does not mistake an ID from another response field for server identity`() {
        #expect(throws: (any Error).self) { try NativeServerInvitation(.object(["id": .string(serverID), "name": .string("Not an invitation response")])) }
    }
}

@MainActor private final class NativeServerLoadProbe {
    private let library: NativeServerLibraryModel
    private let server: NativeServerDetailModel
    private let detail: Bool

    init(store: NativeStore, serverID: String, detail: Bool) {
        library = NativeServerLibraryModel(store: store)
        server = NativeServerDetailModel(store: store, id: serverID)
        self.detail = detail
    }

    var isLoading: Bool { detail ? server.isLoading : library.isLoading }
    var hasContent: Bool { detail ? server.snapshot != nil : !library.servers.isEmpty }
    var error: String? { detail ? server.error : library.error ?? library.organization.error }
    func refresh() async {
        if detail { await server.refresh() }
        else { await library.refresh() }
    }
}

@MainActor private final class NativeServerLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0; startedContinuation?.resume(); startedContinuation = nil }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
