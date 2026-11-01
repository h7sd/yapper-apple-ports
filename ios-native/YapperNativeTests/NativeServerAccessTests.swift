import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeServerAccessTests {
    private let sid = "11111111-1111-4111-8111-111111111111"
    private let uid = "22222222-2222-4222-8222-222222222222"
    private let owner = "33333333-3333-4333-8333-333333333333"
    private let cid = "44444444-4444-4444-8444-444444444444"
    private let category = "55555555-5555-4555-8555-555555555555"
    private let rid = "66666666-6666-4666-8666-666666666666"
    private let child = "77777777-7777-4777-8777-777777777777"
    private var session: NativeSession { NativeSession(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: .distantFuture, userID: uid) }
    private func flags(_ names: [String] = []) -> NativeCapabilities {
        var value = NativeCapabilities()
        value.flags = .object(Dictionary(uniqueKeysWithValues: names.map { ($0, .object(["mode": .string("everyone")])) }))
        return value
    }
    private func channel(_ extra: [String: NativeJSON] = [:], id: String? = nil, kind: String = "text") throws -> NativeServerChannel {
        var row: [String: NativeJSON] = ["id": .string(id ?? cid), "server_id": .string(sid), "kind": .string(kind), "name": .string("synthetic"), "category_id": .string(category)]
        row.merge(extra) { _, value in value }
        return try NativeServerChannel(.object(row), serverID: sid)
    }
    private func role(_ extra: [String: NativeJSON] = [:], id: String? = nil) throws -> NativeServerRole {
        var row: [String: NativeJSON] = ["id": .string(id ?? rid), "server_id": .string(sid), "name": .string("Role"), "position": .number(1), "auto": .string("none")]
        row.merge(extra) { _, value in value }
        return try NativeServerRole(.object(row), serverID: sid)
    }
    private func snapshot(channels: [NativeServerChannel], roles: [NativeServerRole] = [], assigned: Set<String> = [], rules: [NativeChannelOverride] = [], loaded: Bool = true, server extra: [String: NativeJSON] = [:]) throws -> NativeServerSnapshot {
        var row: [String: NativeJSON] = ["id": .string(sid), "name": .string("Server"), "owner_id": .string(owner)]
        row.merge(extra) { _, value in value }
        return NativeServerSnapshot(server: try NativeServer(.object(row)), channels: channels, categories: [],
                                    members: [NativeServerMember(user: YapperUser(id: uid, username: "synthetic"), nickname: nil, joinedAt: "2026-01-01T00:00:00Z")],
                                    roles: roles, memberRoles: [uid: assigned], channelOverrides: rules, overridesLoaded: loaded)
    }
    private func rule(channel targetChannel: String? = nil, category targetCategory: String? = nil, role: String? = nil, allow: [String] = [], deny: [String] = []) throws -> NativeChannelOverride {
        try NativeChannelOverride(.object(["server_id": .string(sid), "channel_id": targetChannel.map(NativeJSON.string) ?? .null,
                                          "category_id": targetCategory.map(NativeJSON.string) ?? .null, "role_id": role.map(NativeJSON.string) ?? .null,
                                          "allow": .array(allow.map(NativeJSON.string)), "deny": .array(deny.map(NativeJSON.string))]), serverID: sid)
    }

    @Test func `Read only channels reject an ordinary writer but accept their permitted posting role`() throws {
        let c = try channel(["read_only": .bool(true), "postRoles": .array([.string(rid)])])
        let denied = try snapshot(channels: [c])
        #expect(!denied.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        let allowed = try snapshot(channels: [c], roles: [role()], assigned: [rid])
        #expect(allowed.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        #expect(!denied.postingAccess(channelID: cid, userID: nil, capabilities: flags()).canSend)
    }

    @Test func `Owners and manual administrators retain their channel exemptions`() throws {
        let c = try channel(["read_only": .bool(true), "private": .bool(true)])
        let s = try snapshot(channels: [c], roles: [role(["perms": .object(["administrator": .bool(true)])])], assigned: [rid])
        #expect(s.postingAccess(channelID: cid, userID: owner, capabilities: flags(["channel_perms"])).canSend)
        #expect(s.postingAccess(channelID: cid, userID: uid, capabilities: flags(["channel_perms"])).canSend)
    }

    @Test func `Unknown enabled channel permissions fail closed instead of offering a composer`() throws {
        let s = try snapshot(channels: [channel()], loaded: false)
        let access = s.postingAccess(channelID: cid, userID: uid, capabilities: flags(["channel_perms"]))
        #expect(!access.canSend && access.reason != nil)
        #expect(s.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
    }

    @Test func `Category everyone deny is overridden by a matching channel role allow`() throws {
        let deny = try rule(category: category, deny: ["send_messages"])
        let allow = try rule(channel: cid, role: rid, allow: ["send_messages"])
        let s = try snapshot(channels: [channel()], roles: [role()], assigned: [rid], rules: [deny, allow])
        #expect(s.postingAccess(channelID: cid, userID: uid, capabilities: flags(["channel_perms"])).canSend)
        let other = try snapshot(channels: [channel()], roles: [role()], rules: [deny, allow])
        #expect(!other.postingAccess(channelID: cid, userID: uid, capabilities: flags(["channel_perms"])).canSend)
    }

    @Test func `Matching role allow wins over matching role deny within the same scope`() throws {
        let second = "88888888-8888-4888-8888-888888888888"
        let rules = try [rule(channel: cid, role: rid, deny: ["send_messages"]), rule(channel: cid, role: second, allow: ["send_messages"])]
        let s = try snapshot(channels: [channel()], roles: [role(), role(id: second)], assigned: [rid, second], rules: rules)
        #expect(s.postingAccess(channelID: cid, userID: uid, capabilities: flags(["channel_perms"])).canSend)
    }

    @Test func `Base server denial and private channel access are respected`() throws {
        let s = try snapshot(channels: [channel()], server: ["everyone_perms": .object(["send_messages": .bool(false)])])
        #expect(!s.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        let hidden = try snapshot(channels: [channel(["private": .bool(true), "allowedRoles": .array([.string(rid)])])])
        #expect(!hidden.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
    }

    @Test func `Rules and timed server locks leave ordinary channels readable without offering sends`() throws {
        let s = try snapshot(channels: [channel()], server: ["rules_channel_id": .string(cid)])
        #expect(!s.postingAccess(channelID: cid, userID: uid, capabilities: flags(["rules_channel"])).canSend)
        #expect(s.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        let locked = try snapshot(channels: [channel()], server: ["locked_until": .string("2026-02-01T00:00:00Z")])
        let before = try NativeDate.parse("2026-01-01T00:00:00Z"), after = try NativeDate.parse("2026-03-01T00:00:00Z")
        #expect(!locked.postingAccess(channelID: cid, userID: uid, capabilities: flags(), now: before).canSend)
        #expect(locked.postingAccess(channelID: cid, userID: uid, capabilities: flags(), now: after).canSend)
    }

    @Test func `Threads inherit their real parent restrictions and locked state`() throws {
        let parent = try channel(["read_only": .bool(true)])
        let thread = try channel(["parent_id": .string(cid)], id: child, kind: "thread")
        let s = try snapshot(channels: [parent, thread])
        #expect(!s.postingAccess(channelID: child, userID: uid, capabilities: flags()).canSend)
        let unknownParent = try snapshot(channels: [thread])
        #expect(!unknownParent.postingAccess(channelID: child, userID: uid, capabilities: flags()).canSend)
        let locked = try channel(["parent_id": .string(cid), "locked": .bool(true)], id: child, kind: "thread")
        let t = try snapshot(channels: [channel(), locked])
        #expect(!t.postingAccess(channelID: child, userID: uid, capabilities: flags()).canSend)
        let noThreadSend = try snapshot(channels: [channel(), thread], server: ["everyone_perms": .object(["send_in_threads": .bool(false)])])
        #expect(!noThreadSend.postingAccess(channelID: child, userID: uid, capabilities: flags()).canSend)
    }

    @Test func `Forum and voice entry require their native feature path`() throws {
        let forum = try snapshot(channels: [channel(kind: "forum")])
        #expect(!forum.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        #expect(forum.canCreateForumPost(channelID: cid, userID: uid, capabilities: flags()))
        let voice = try snapshot(channels: [channel(kind: "voice")])
        #expect(!voice.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
        #expect(voice.postingAccess(channelID: cid, userID: uid, capabilities: flags(["voice_chat"])).canSend)
    }

    @Test func `Decorative automatic role colors do not grant management`() throws {
        let automatic = try role(["auto": .string("all"), "color": .string("#AABBCC"), "perms": .object(["administrator": .bool(true)])])
        let s = try snapshot(channels: [channel(["read_only": .bool(true)])], roles: [automatic])
        #expect(s.nameColor(userID: uid) == "#AABBCC")
        #expect(s.colorRole(userID: uid)?.id == rid)
        #expect(!s.hasPermission("manage_server", userID: uid))
        #expect(!s.postingAccess(channelID: cid, userID: uid, capabilities: flags()).canSend)
    }

    @Test func `Highest colored role skips plain black but retains a second color gradient`() throws {
        let second = "88888888-8888-4888-8888-888888888888"
        let black = try role(["color": .string("#000000"), "position": .number(100)])
        let blue = try role(["color": .string("#1122FF"), "position": .number(1)], id: second)
        let s = try snapshot(channels: [], roles: [black, blue], assigned: [rid, second])
        #expect(s.nameColor(userID: uid) == "#1122FF")
        let gradient = try role(["color": .string("#000000"), "color2": .string("#FF22AA"), "position": .number(100)])
        let g = try snapshot(channels: [], roles: [blue, gradient], assigned: [rid, second])
        #expect(g.colorRole(userID: uid)?.color2 == "#FF22AA")
    }

    @Test func `Before automatic roles use real join dates and equal rank colors use stable IDs`() throws {
        let old = try role(["auto": .string("before"), "auto_before": .string("2026-02-01T00:00:00Z"), "color": .string("#AABBCC")])
        let late = try role(["auto": .string("before"), "auto_before": .string("2025-12-01T00:00:00Z"), "color": .string("#FF0000"), "position": .number(100)], id: child)
        let s = try snapshot(channels: [], roles: [late, old])
        #expect(s.nameColor(userID: uid) == "#AABBCC")
        #expect(s.nameColor(userID: owner) == nil)
        let tied = try role(["color": .string("#FF0000")], id: child)
        let stable = try snapshot(channels: [], roles: [tied, old], assigned: [child])
        #expect(stable.colorRole(userID: uid)?.id == rid)
    }

    @Test(arguments: ["text", "voice", "forum", "thread"]) func `Channel glyph identity retains wire kind`(_ kind: String) throws {
        let c = try channel(kind: kind)
        #expect(!c.symbol.isEmpty)
        #expect(c.kind == kind)
        if kind != "text" { #expect(c.symbol != "number") }
        #expect(try channel(["read_only": .bool(true)]).symbol == "megaphone")
        #expect(try channel(["stage": .bool(true)], kind: "voice").symbol == "person.wave.2")
    }

    @Test func `Member pages are scoped cursor ordered and hydrate only public profiles plus roles`() async throws {
        var queries: [String: [URLQueryItem]] = [:]
        let api = NativeAPI { request in
            let path = try #require(request.url?.lastPathComponent)
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            queries[path] = query
            if path == "server_members" {
                #expect(query.contains(URLQueryItem(name: "server_id", value: "eq.\(sid)")))
                #expect(query.contains(URLQueryItem(name: "user_id", value: "gt.\(owner)")))
                return try response(request, .array([.object(["user_id": .string(child), "nickname": .string("Nick"), "joined_at": .string("2026-01-01T00:00:00Z")])]))
            }
            if path == "profiles" {
                #expect(query.contains(URLQueryItem(name: "select", value: NativeAPI.publicProfileColumns)))
                return try response(request, .array([.object(["id": .string(child), "username": .string("synthetic")])]))
            }
            #expect(path == "server_role_assignments")
            return try response(request, .array([.array([.string(sid), .string(child), .string(rid)])]))
        }
        let page = try await api.nativeServerMembersPage(serverID: sid, afterUserID: owner, session: session)
        #expect(page.members.map(\.id) == [child])
        #expect(page.members.first?.displayName == "Nick")
        #expect(page.memberRoles[child] == [rid])
        #expect(page.nextUserID == nil)
        #expect(queries.keys.count == 3)
    }

    @Test func `A full member page returns a continuation while a denied roster read stays an error`() async throws {
        let ids = (1...100).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == "server_members" {
                return try response(request, .array(ids.map { .object(["user_id": .string($0)]) }))
            }
            if request.url?.lastPathComponent == "profiles" { return try response(request, .array(ids.map { .object(["id": .string($0), "username": .string("synthetic")]) })) }
            return try response(request, .array([]))
        }
        let page = try await api.nativeServerMembersPage(serverID: sid, session: session)
        #expect(page.members.count == 100 && page.nextUserID == ids.last)
        let denied = NativeAPI { request in try response(request, .object(["message": .string("Denied")]), status: 403) }
        await #expect(throws: (any Error).self) { try await denied.nativeServerMembersPage(serverID: sid, session: session) }
    }

    @Test func `Scoped role assignment loading continues beyond one thousand rows`() async throws {
        let roleIDs = (1...1001).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        var requests = 0
        let api = NativeAPI { request in
            if request.url?.lastPathComponent == "server_role_assignments" {
                return try response(request, .object(["message": .string("Could not find the function public.server_role_assignments in the schema cache"), "code": .string("PGRST202")]), status: 404)
            }
            requests += 1
            let requestURL = try #require(request.url)
            let q = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(q.contains(URLQueryItem(name: "user_id", value: "in.(\(uid))")))
            if requests == 2 { #expect(q.contains { $0.name == "or" && $0.value?.contains(roleIDs[999]) == true }) }
            let batch = requests == 1 ? Array(roleIDs.prefix(1000)) : [roleIDs[1000]]
            return try response(request, .array(batch.map { .object(["server_id": .string(sid), "user_id": .string(uid), "role_id": .string($0)]) }))
        }
        let roles = try await api.nativeServerMemberRoles(serverID: sid, userIDs: [uid], session: session)
        #expect(roles[uid]?.count == 1001)
        #expect(requests == 2)
    }

    @Test func `A foreign member or repeated paging identity cannot contaminate a roster`() async throws {
        let api = NativeAPI { request in try response(request, .array([.object(["server_id": .string(owner), "user_id": .string(uid)])])) }
        await #expect(throws: (any Error).self) { try await api.nativeServerMembersPage(serverID: sid, session: session) }
        let repeated = NativeAPI { request in try response(request, .array([.object(["user_id": .string(uid)])])) }
        await #expect(throws: (any Error).self) { try await repeated.nativeServerMembersPage(serverID: sid, afterUserID: uid, session: session) }
        let unrelatedRole = NativeAPI { request in try response(request, .array([.array([.string(owner), .string(uid), .string(rid)])])) }
        await #expect(throws: (any Error).self) { try await unrelatedRole.nativeServerMemberRoles(serverID: sid, userIDs: [uid], session: session) }
    }

    @Test func `Preferred JSON tuple role RPC avoids restricted legacy tables and filters requested users`() async throws {
        var requests = 0
        let api = NativeAPI { request in
            requests += 1
            #expect(request.url?.lastPathComponent == "server_role_assignments")
            return try response(request, .array([.array([.string(sid), .string(uid), .string(rid)]), .array([.string(sid), .string(owner), .string(child)])]))
        }
        let roles = try await api.nativeServerMemberRoles(serverID: sid, userIDs: [uid], session: session)
        #expect(roles == [uid: [rid]])
        #expect(requests == 1)
    }

    @Test(arguments: [403, 404]) func `Permission and ordinary missing responses never fall back to legacy role reads`(_ status: Int) async throws {
        var requests = 0
        let api = NativeAPI { request in
            requests += 1
            #expect(request.url?.lastPathComponent == "server_role_assignments")
            let text = status == 403 ? "Permission denied for function server_role_assignments" : "Server not found"
            return try response(request, .object(["message": .string(text)]), status: status)
        }
        await #expect(throws: (any Error).self) { try await api.nativeServerMemberRoles(serverID: sid, userIDs: [uid], session: session) }
        #expect(requests == 1)
    }

    private func response(_ request: URLRequest, _ body: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let requestURL = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: requestURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(body), http)
    }
}
