import Foundation

// Exact client operations from current server module 33-dglfmrlo2q.js and
// thread/forum module 26uoqp3al_bay.js. Server authorization remains authoritative.
extension NativeAPI {
    func nativeJoinedServerIDs(session: NativeSession) async throws -> [String] {
        let memberships = try await table("server_members", query: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "server_id")], session: session).rows
        let ids = try memberships.map { row -> String in
            guard let id = row["server_id"].string, UUID(uuidString: id) != nil else { throw NativeClientError.malformedResponse("Server membership") }
            return id
        }
        return Array(Set(ids)).sorted()
    }

    func nativeServers(session: NativeSession) async throws -> [NativeServer] {
        let ids = try await nativeJoinedServerIDs(session: session)
        guard !ids.isEmpty else { return [] }
        let rows = try await table("servers", query: [URLQueryItem(name: "id", value: "in.(\(Array(Set(ids)).sorted().joined(separator: ",")))"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "created_at.asc")], session: session).rows
        let servers = try rows.map(NativeServer.init)
        guard servers.allSatisfy({ ids.contains($0.id) }), Set(servers.map(\.id)).count == servers.count else { throw NativeClientError.invalidResponse }
        return servers
    }

    func nativeServerSnapshot(id: String, session: NativeSession) async throws -> NativeServerSnapshot {
        try Self.validateServerID(id)
        let serverRows = try await table("servers", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "*")], session: session).rows
        guard serverRows.count == 1, serverRows[0]["id"].string == id else { throw NativeClientError.api(status: 404, message: "Dieser Server ist nicht mehr verfügbar.") }
        let server = try NativeServer(serverRows[0])
        let channelRows = try await rpc("visible_server_channels", arguments: ["sids": .array([.string(id)])], session: session).rows
        let allowed = try await table("channel_roles", query: [URLQueryItem(name: "server_id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "channel_id,role_id")], session: session).rows
        let posting = try await table("channel_post_roles", query: [URLQueryItem(name: "server_id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "channel_id,role_id")], session: session).rows
        var channels: [NativeServerChannel] = []
        for row in channelRows {
            var object = row.object ?? [:]
            let channelID = row["id"].string
            let visibility: [NativeJSON] = allowed.filter { $0["channel_id"].string == channelID }.map { $0["role_id"] }
            let writing: [NativeJSON] = posting.filter { $0["channel_id"].string == channelID }.map { $0["role_id"] }
            object["allowedRoles"] = .array(visibility)
            object["postRoles"] = .array(writing)
            channels.append(try NativeServerChannel(.object(object), serverID: id))
        }
        channels.sort { $0.position == $1.position ? $0.createdAt < $1.createdAt : $0.position < $1.position }
        let categoryRows = try await table("channel_categories", query: [URLQueryItem(name: "server_id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "*")], session: session).rows
        let categories = try categoryRows.map { try NativeServerCategory($0, serverID: id) }.sorted { $0.position < $1.position }
        let roleRows = try await table("roles", query: [URLQueryItem(name: "server_id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "*")], session: session).rows
        let roles = try roleRows.map { try NativeServerRole($0, serverID: id) }.sorted { $0.position > $1.position }
        guard Set(channels.map(\.id)).count == channels.count,
              Set(categories.map(\.id)).count == categories.count,
              Set(roles.map(\.id)).count == roles.count else { throw NativeClientError.malformedResponse("Duplicate server content identity") }
        let assignments = try await rpc("server_role_assignments", arguments: ["sids": .array([.string(id)])], session: session).array
        var memberRoles: [String: Set<String>] = [:]
        for tuple in assignments {
            let values = tuple.array
            guard values.count == 3, values[0].string == id,
                  let uid = values[1].string, UUID(uuidString: uid) != nil,
                  let rid = values[2].string, roles.contains(where: { $0.id == rid }) else { throw NativeClientError.malformedResponse("Server role assignment") }
            memberRoles[uid, default: []].insert(rid)
        }
        let memberRows = try await rpc("server_members_slice", arguments: ["sids": .array([.string(id)])], session: session).rows
        let members = try await nativeServerMembers(rows: memberRows, serverID: id, session: session)
        return NativeServerSnapshot(server: server, channels: channels, categories: categories, members: members, roles: roles, memberRoles: memberRoles)
    }

    func nativeFindServerMembers(serverID: String, query: String, session: NativeSession) async throws -> [NativeServerMember] {
        try Self.validateServerID(serverID)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text.count <= 80 else { return [] }
        let rows = try await rpc("find_server_members", arguments: ["sid": .string(serverID), "q": .string(text), "with_display": .bool(true), "lim": .number(10)], session: session).rows
        return try await nativeServerMembers(rows: rows, serverID: serverID, session: session)
    }

    private func nativeServerMembers(rows: [NativeJSON], serverID: String, session: NativeSession) async throws -> [NativeServerMember] {
        let ids = try rows.map { row -> String in
            guard row["server_id"].string == nil || row["server_id"].string == serverID,
                  let id = row["user_id"].string, UUID(uuidString: id) != nil else { throw NativeClientError.malformedResponse("Server member") }
            return id
        }
        guard !ids.isEmpty else { return [] }
        var profiles: [String: YapperUser] = [:]
        // The website requests profiles for a slice; bound each request to avoid an unbounded URL.
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(Set(ids[offset..<min(offset + 100, ids.count)])).sorted()
            let records = try await table("profiles", query: [URLQueryItem(name: "id", value: "in.(\(batch.joined(separator: ",")))"), URLQueryItem(name: "select", value: "id,username,display_name,avatar_path,bio")], session: session).rows
            for record in records {
                guard let id = record["id"].string, batch.contains(id), let username = record["username"].string else { throw NativeClientError.malformedResponse("Server member profile") }
                profiles[id] = YapperUser(id: id, username: username, displayName: record["display_name"].string, avatarURL: NativeConfiguration.publicAsset(bucket: "avatars", path: record["avatar_path"].string), bio: record["bio"].string)
            }
        }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["user_id"].string, seen.insert(id).inserted else { return nil }
            let user = profiles[id] ?? YapperUser(id: id, username: "Unbekannt")
            return NativeServerMember(user: user, nickname: row["nickname"].string, joinedAt: row["joined_at"].string)
        }
    }

    func nativeDiscoverServers(query: String, offset: Int = 0, session: NativeSession) async throws -> [NativeServer] {
        let rows = try await rpc("discover_servers_page", arguments: ["q": .string(String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))), "lim": .number(48), "off": .number(Double(max(0, offset)))], session: session).rows
        return try rows.map(NativeServer.init)
    }

    func nativeCreateServer(name: String, session: NativeSession) async throws -> String {
        let value = try await rpc("create_server", arguments: ["server_name": .string(try NativeServerInput.name(name)), "server_icon": .null], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func nativeJoinServer(invite: String, session: NativeSession) async throws -> String {
        let code = try NativeServerInput.inviteCode(invite)
        let value = try await rpc("join_server", arguments: ["invite_code": .string(code)], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func nativeJoinPublicServer(id: String, session: NativeSession) async throws {
        try Self.validateServerID(id)
        _ = try await rpc("join_public_server", arguments: ["sid": .string(id)], session: session)
    }

    func nativeInvite(serverID: String, session: NativeSession) async throws -> URL {
        try Self.validateServerID(serverID)
        let vanity = try await table("invites", query: [URLQueryItem(name: "server_id", value: "eq.\(serverID)"), URLQueryItem(name: "vanity", value: "eq.true"), URLQueryItem(name: "select", value: "code"), URLQueryItem(name: "limit", value: "1")], session: session).rows
        var code = vanity.first?["code"].string
        if code == nil {
            let own = try await table("invites", query: [URLQueryItem(name: "server_id", value: "eq.\(serverID)"), URLQueryItem(name: "created_by", value: "eq.\(session.userID)"), URLQueryItem(name: "skip_apply", value: "eq.false"), URLQueryItem(name: "select", value: "code"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "1")], session: session).rows
            code = own.first?["code"].string
        }
        if code == nil {
            let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
            for attempt in 0..<3 {
                let candidate = String((0..<8).map { _ in alphabet.randomElement()! })
                do {
                    let result = try await table("invites", query: [URLQueryItem(name: "select", value: "code")], method: "POST", values: .object(["code": .string(candidate), "server_id": .string(serverID), "created_by": .string(session.userID)]), session: session, prefer: "return=representation").rows
                    guard let created = result.first?["code"].string else { throw NativeClientError.invalidResponse }
                    code = created; break
                } catch let NativeClientError.api(status, _) where status == 409 && attempt < 2 { continue }
            }
        }
        guard let code, let url = URL(string: "https://yapin.gg/invite/" + (try NativeServerInput.inviteCode(code))) else { throw NativeClientError.invalidResponse }
        return url
    }

    func nativeUpdateServer(_ server: NativeServer, name: String, description: String, discoverable: Bool, tags: [String], session: NativeSession) async throws {
        _ = try await rpc("update_server", arguments: ["sid": .string(server.id), "server_name": .string(try NativeServerInput.name(name)), "server_icon": server.iconPath.map(NativeJSON.string) ?? .null], session: session)
        _ = try await rpc("set_server_discovery", arguments: ["sid": .string(server.id), "p_on": .bool(discoverable), "p_description": .string(description), "p_tags": .array(tags.map(NativeJSON.string))], session: session)
    }

    func nativeLeaveServer(id: String, delete: Bool = false, session: NativeSession) async throws {
        try Self.validateServerID(id)
        _ = try await rpc(delete ? "delete_server" : "leave_server", arguments: ["sid": .string(id)], session: session)
    }

    func nativeCreateChannel(serverID: String, name: String, kind: String, categoryID: String?, session: NativeSession) async throws -> String {
        try Self.validateServerID(serverID)
        guard ["text", "voice", "forum"].contains(kind) else { throw NativeClientError.invalidResponse }
        let value = try await rpc("create_channel", arguments: ["sid": .string(serverID), "channel_name": .string(try NativeServerInput.name(name)), "channel_kind": .string(kind)], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        if let categoryID {
            try Self.validateServerID(categoryID)
            _ = try await rpc("set_channel_category", arguments: ["chid": .string(id), "cid": .string(categoryID), "ids": .null], session: session)
        }
        return id
    }

    func nativeRenameChannel(id: String, name: String, session: NativeSession) async throws {
        try Self.validateServerID(id)
        let rows = try await table("channels", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "id")], method: "PATCH", values: .object(["name": .string(try NativeServerInput.name(name))]), session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.api(status: 403, message: "Du kannst diesen Kanal nicht bearbeiten.") }
    }

    func nativeDeleteChannel(id: String, session: NativeSession) async throws {
        try Self.validateServerID(id)
        let rows = try await table("channels", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "id")], method: "DELETE", session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.api(status: 403, message: "Du kannst diesen Kanal nicht löschen.") }
    }

    func nativeSetChannelPosting(id: String, readOnly: Bool, roles: [String], slowmode: Int, session: NativeSession) async throws {
        try Self.validateServerID(id)
        _ = try await rpc("set_channel_posting", arguments: ["cid": .string(id), "make_read_only": .bool(readOnly), "post_role_ids": .array(readOnly ? roles.map(NativeJSON.string) : []), "slow": .number(Double(max(0, slowmode)))], session: session)
    }

    func nativeSetChannelAccess(id: String, isPrivate: Bool, roles: [String], session: NativeSession) async throws {
        try Self.validateServerID(id)
        _ = try await rpc("set_channel_access", arguments: ["cid": .string(id), "make_private": .bool(isPrivate), "role_ids": .array(isPrivate ? roles.map(NativeJSON.string) : [])], session: session)
    }

    func nativeSetChannelCategory(id: String, categoryID: String?, session: NativeSession) async throws {
        _ = try await rpc("set_channel_category", arguments: ["chid": .string(id), "cid": categoryID.map(NativeJSON.string) ?? .null, "ids": .null], session: session)
    }

    func nativeReorderChannels(serverID: String, ids: [String], session: NativeSession) async throws {
        _ = try await rpc("reorder_channels", arguments: ["sid": .string(serverID), "ids": .array(ids.map(NativeJSON.string))], session: session)
    }

    func nativeCreateRole(snapshot: NativeServerSnapshot, name: String, session: NativeSession) async throws {
        let position = snapshot.server.ownerID == session.userID ? (snapshot.roles.map(\.position).max() ?? 0) + 1 : max(0, snapshot.topPosition(session.userID) - 1)
        let rows = try await table("roles", query: [URLQueryItem(name: "select", value: "id")], method: "POST", values: .object(["server_id": .string(snapshot.server.id), "name": .string(try NativeServerInput.name(name)), "color": .null, "position": .number(Double(position)), "manage_server": .bool(false), "manage_messages": .bool(false)]), session: session, prefer: "return=representation").rows
        guard rows.first?["id"].string != nil else { throw NativeClientError.invalidResponse }
    }

    func nativeUpdateRole(_ role: NativeServerRole, name: String, permissions: [String: Bool], session: NativeSession) async throws {
        let values: NativeJSON = .object(["name": .string(try NativeServerInput.name(name)), "color": role.color.map(NativeJSON.string) ?? .null, "manage_server": .bool(false), "manage_messages": .bool(false), "perms": .object(permissions.mapValues(NativeJSON.bool)), "auto": .string(role.auto), "auto_before": role.autoBefore.map(NativeJSON.string) ?? .null])
        let rows = try await table("roles", query: [URLQueryItem(name: "id", value: "eq.\(role.id)"), URLQueryItem(name: "select", value: "id")], method: "PATCH", values: values, session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == role.id }) else { throw NativeClientError.api(status: 403, message: "Du kannst diese Rolle nicht bearbeiten.") }
    }

    func nativeDeleteRole(id: String, session: NativeSession) async throws {
        let rows = try await table("roles", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "id")], method: "DELETE", session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.api(status: 403, message: "Du kannst diese Rolle nicht löschen.") }
    }

    func nativeAssignRole(serverID: String, userID: String, roleID: String, enabled: Bool, session: NativeSession) async throws {
        if enabled {
            do { _ = try await table("member_roles", method: "POST", values: .object(["server_id": .string(serverID), "user_id": .string(userID), "role_id": .string(roleID)]), session: session) }
            catch let NativeClientError.api(status, _) where status == 409 { return }
        } else {
            let rows = try await table("member_roles", query: [URLQueryItem(name: "server_id", value: "eq.\(serverID)"), URLQueryItem(name: "user_id", value: "eq.\(userID)"), URLQueryItem(name: "role_id", value: "eq.\(roleID)"), URLQueryItem(name: "select", value: "role_id")], method: "DELETE", session: session, prefer: "return=representation").rows
            guard !rows.isEmpty else { throw NativeClientError.api(status: 403, message: "Diese Rolle konnte nicht entfernt werden. Automatische Rollen werden in den Rolleneinstellungen verwaltet.") }
        }
    }

    func nativeSetNickname(serverID: String, userID: String, nickname: String, session: NativeSession) async throws {
        _ = try await rpc("set_nickname", arguments: ["sid": .string(serverID), "target": .string(userID), "nick": .string(nickname)], session: session)
    }

    func nativeModerateMember(serverID: String, userID: String, action: String, minutes: Int = 0, reason: String = "", session: NativeSession) async throws {
        guard ["kick_member", "ban_member", "unban_member", "server_timeout"].contains(action) else { throw NativeClientError.invalidEndpoint }
        var args: [String: NativeJSON] = ["sid": .string(serverID), "target": .string(userID)]
        if action == "server_timeout" { args["minutes"] = .number(Double(max(0, minutes))); args["why"] = .string(reason) }
        _ = try await rpc(action, arguments: args, session: session)
    }

    func nativeCreateCategory(serverID: String, name: String, session: NativeSession) async throws {
        _ = try await rpc("create_category", arguments: ["sid": .string(serverID), "p_name": .string(try NativeServerInput.name(name))], session: session)
    }

    func nativeRenameCategory(id: String, name: String, session: NativeSession) async throws {
        _ = try await rpc("rename_category", arguments: ["cid": .string(id), "p_name": .string(try NativeServerInput.name(name))], session: session)
    }

    func nativeDeleteCategory(id: String, session: NativeSession) async throws {
        _ = try await table("channel_categories", query: [URLQueryItem(name: "id", value: "eq.\(id)")], method: "DELETE", session: session)
    }

    func nativeForumPosts(channelID: String, sort: String = "activity", query: String = "", tags: [String] = [], following: Bool = false, before: NativeForumPost? = nil, session: NativeSession) async throws -> [NativeForumPost] {
        let rows = try await rpc("list_forum_posts", arguments: ["p_forum": .string(channelID), "p_sort": .string(sort), "p_tags": tags.isEmpty ? .null : .array(tags.map(NativeJSON.string)), "p_q": query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .null : .string(query.trimmingCharacters(in: .whitespacesAndNewlines)), "p_following": .bool(following), "p_before": before.map { .string(sort == "new" ? $0.createdAt : $0.lastMessageAt) } ?? .null, "p_before_id": before.map { .string($0.id) } ?? .null, "p_limit": .number(25)], session: session).rows
        return try rows.map(NativeForumPost.init)
    }

    func nativeCreateForumPost(channelID: String, title: String, content: String, tags: [String], session: NativeSession) async throws -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf16.count <= 2000 else { throw NativeClientError.emptyMessage }
        let value = try await rpc("create_thread", arguments: ["p_parent": .string(channelID), "p_title": .string(try NativeServerInput.name(title)), "p_tags": .array(tags.map(NativeJSON.string)), "p_message": .null, "p_content": .string(content)], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func nativeThreadState(id: String, action: String, enabled: Bool, session: NativeSession) async throws {
        if action == "closed" { _ = try await rpc("close_thread", arguments: ["p_thread": .string(id), "p_closed": .bool(enabled)], session: session) }
        else if action == "following" { _ = try await rpc("follow_thread", arguments: ["p_thread": .string(id), "p_on": .bool(enabled)], session: session) }
        else {
            guard ["pinned", "locked"].contains(action) else { throw NativeClientError.invalidEndpoint }
            _ = try await rpc("set_thread_state", arguments: ["p_thread": .string(id), "p_state": .string(action), "p_on": .bool(enabled)], session: session)
        }
    }

    private static func validateServerID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
    }
}
