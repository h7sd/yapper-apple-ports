import Foundation

// Current official frontend sources: 33-dglfmrlo2q.js, 27f4py65oe_v9.js,
// 2nt-wynvu65uw.js, 0sn16tkxmqvqh.js and 1qzukk8lvnp02.js.
nonisolated enum NativeServerTool: String, CaseIterable, Identifiable, Sendable {
    case events, emojis, webhooks, templates, requests, bans, audit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .events: "Ereignisse"
        case .emojis: "Server-Emojis"
        case .webhooks: "Webhooks"
        case .templates: "Servervorlagen"
        case .requests: "Beitrittsanfragen"
        case .bans: "Gesperrte Mitglieder"
        case .audit: "Audit-Protokoll"
        }
    }
    var icon: String {
        switch self {
        case .events: "calendar"
        case .emojis: "face.smiling"
        case .webhooks: "link"
        case .templates: "square.on.square"
        case .requests: "person.badge.plus"
        case .bans: "person.crop.circle.badge.xmark"
        case .audit: "clock.arrow.circlepath"
        }
    }
    var permission: String? {
        switch self {
        case .events: nil
        case .emojis: "manage_emojis"
        case .webhooks: "manage_webhooks"
        case .templates: "manage_server"
        case .requests: "kick_members"
        case .bans: "ban_members"
        case .audit: "view_audit_log"
        }
    }
}

nonisolated struct NativeServerToolRecord: Identifiable, Sendable {
    let id: String
    let row: NativeJSON
    let tool: NativeServerTool
    init(_ row: NativeJSON, tool: NativeServerTool) throws {
        let key = tool == .templates ? "code" : tool == .bans ? "user_id" : "id"
        guard let id = row[key].string, !id.isEmpty, row.object != nil else { throw NativeClientError.malformedResponse("Server tool item") }
        self.id = id; self.row = row; self.tool = tool
    }
    var title: String {
        if tool == .audit { return Self.auditLabels[row["action"].string ?? ""] ?? (row["action"].string ?? "Änderung").replacingOccurrences(of: "_", with: " ") }
        return row["title"].string ?? row["name"].string ?? row["username"].string ?? (tool == .requests || tool == .bans ? "Mitglied" : id)
    }
    static let auditLabels: [String: String] = ["channel_create": "Kanal erstellt", "channel_update": "Kanal geändert", "channel_delete": "Kanal gelöscht", "role_create": "Rolle erstellt", "role_update": "Rolle geändert", "role_delete": "Rolle gelöscht", "member_kick": "Mitglied entfernt", "member_ban": "Mitglied gesperrt", "member_unban": "Sperre aufgehoben", "server_update": "Server geändert", "webhook_create": "Webhook erstellt", "webhook_delete": "Webhook gelöscht", "member_role_add": "Rolle vergeben", "member_role_remove": "Rolle entfernt"]
}

extension NativeAPI {
    func nativeServerTool(_ tool: NativeServerTool, snapshot: NativeServerSnapshot, channelID: String? = nil, before: String? = nil, auditAction: String? = nil, auditActor: String? = nil, session: NativeSession) async throws -> [NativeServerToolRecord] {
        let sid = snapshot.server.id
        let value: NativeJSON
        switch tool {
        case .events: value = try await rpc("server_events_list", arguments: ["sid": .string(sid)], session: session)
        case .emojis: value = try await table("emojis", query: [URLQueryItem(name: "server_id", value: "eq.\(sid)"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "name.asc")], session: session)
        case .webhooks:
            guard let channelID, snapshot.channels.contains(where: { $0.id == channelID && $0.kind == "text" }) else { return [] }
            value = try await rpc("webhook_list", arguments: ["cid": .string(channelID)], session: session)
        case .templates: value = try await table("server_templates", query: [URLQueryItem(name: "created_by", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "code,name,uses,data"), URLQueryItem(name: "order", value: "updated_at.desc"), URLQueryItem(name: "limit", value: "20")], session: session)
        case .requests: value = try await rpc("join_requests", arguments: ["sid": .string(sid)], session: session)
        case .bans: value = try await table("server_bans", query: [URLQueryItem(name: "server_id", value: "eq.\(sid)"), URLQueryItem(name: "select", value: "user_id,created_at"), URLQueryItem(name: "order", value: "created_at.desc")], session: session)
        case .audit: value = try await rpc("server_audit_list", arguments: ["sid": .string(sid), "before": before.map(NativeJSON.string) ?? .null, "act": auditAction.map(NativeJSON.string) ?? .null, "who": auditActor.map(NativeJSON.string) ?? .null, "lim": .number(50)], session: session)
        }
        return try value.rows.map { row in
            guard row["server_id"].string == nil || row["server_id"].string == sid || tool == .templates else { throw NativeClientError.invalidResponse }
            return try NativeServerToolRecord(row, tool: tool)
        }
    }

    func nativeWebhookCreate(channelID: String, name: String, session: NativeSession) async throws -> NativeJSON {
        try await rpc("webhook_create", arguments: ["cid": .string(channelID), "p_name": .string(try NativeServerInput.name(name))], session: session)
    }

    func nativeWebhookRename(id: String, name: String, session: NativeSession) async throws {
        _ = try await rpc("webhook_rename", arguments: ["wid": .string(id), "p_name": .string(try NativeServerInput.name(name))], session: session)
    }

    func nativeWebhookRotate(id: String, session: NativeSession) async throws -> NativeJSON {
        try await rpc("webhook_rotate", arguments: ["wid": .string(id)], session: session)
    }

    func nativeWebhookDelete(id: String, session: NativeSession) async throws { _ = try await rpc("webhook_delete", arguments: ["wid": .string(id)], session: session) }

    func nativeWebhookPost(id: String, text: String, title: String, description: String, session: NativeSession) async throws {
        guard text.utf16.count <= 2000, !text.isEmpty || !title.isEmpty || !description.isEmpty else { throw NativeClientError.emptyMessage }
        var body: [String: NativeJSON] = ["id": .string(id), "content": .string(text)]
        if !title.isEmpty || !description.isEmpty { body["embeds"] = .array([.object(["title": .string(title), "description": .string(description), "color": .number(5793266)])]) }
        _ = try await webAPI(path: "api/webhooks/post", method: "POST", body: .object(body), session: session)
    }

    func nativeEventSave(serverID: String, eventID: String?, title: String, description: String, starts: Date, ends: Date?, channelID: String?, location: String?, announceID: String?, repeatRule: String, coverPath: String?, session: NativeSession) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ends == nil || ends! > starts, channelID != nil || !(location ?? "").isEmpty,
              ["none", "weekly"].contains(repeatRule) else { throw NativeClientError.api(status: 400, message: "Prüfe den Namen, Ort und die Zeit des Ereignisses.") }
        let format = ISO8601DateFormatter()
        let fields: [String: NativeJSON] = ["title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)), "description": .string(description), "cover_path": coverPath.map(NativeJSON.string) ?? .null, "starts_at": .string(format.string(from: starts)), "ends_at": ends.map { .string(format.string(from: $0)) } ?? .null, "tz": .string(TimeZone.current.identifier), "channel_id": channelID.map(NativeJSON.string) ?? .null, "location": location.map(NativeJSON.string) ?? .null, "announce_channel_id": announceID.map(NativeJSON.string) ?? .null, "repeat": .string(repeatRule)]
        _ = try await rpc("event_save", arguments: ["eid": eventID.map(NativeJSON.string) ?? .null, "sid": .string(serverID), "p": .object(fields)], session: session)
    }

    func nativeEventAction(id: String, action: String, session: NativeSession) async throws {
        guard ["start", "end", "cancel"].contains(action) else { throw NativeClientError.invalidEndpoint }
        _ = try await rpc("event_action", arguments: ["eid": .string(id), "what": .string(action)], session: session)
    }

    func nativeEventInterest(id: String, interested: Bool, session: NativeSession) async throws {
        _ = try await rpc("event_interest_set", arguments: ["eid": .string(id), "want": .bool(interested)], session: session)
    }

    func nativeCreateTemplate(serverID: String, session: NativeSession) async throws -> String {
        let value = try await rpc("make_server_template", arguments: ["sid": .string(serverID)], session: session)
        guard let code = value.string, !code.isEmpty else { throw NativeClientError.invalidResponse }
        return code
    }

    func nativeServerFromTemplate(code: String, name: String, session: NativeSession) async throws -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.utf8.count <= 100 else { throw NativeClientError.invalidResponse }
        let value = try await rpc("create_server_from_template", arguments: ["tcode": .string(trimmed), "server_name": .string(try NativeServerInput.name(name)), "server_icon": .null], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func nativeAddServerEmoji(serverID: String, name: String, data: Data, contentType: String, animated: Bool, session: NativeSession) async throws {
        guard name.range(of: "^[A-Za-z0-9_]{2,32}$", options: .regularExpression) != nil else { throw NativeClientError.api(status: 400, message: "Emoji-Namen bestehen aus 2–32 Buchstaben, Ziffern oder Unterstrichen.") }
        let id = UUID().uuidString.lowercased()
        let path = try await uploadMedia(bucket: "emojis", data: data, filename: "emoji." + NativeMediaUploadPolicy.suffix(filename: "", contentType: contentType), contentType: contentType, serverID: serverID, objectID: id, session: session)
        do {
            _ = try await table("emojis", method: "POST", values: .object(["id": .string(id), "owner_id": .string(session.userID), "server_id": .string(serverID), "name": .string(name), "path": .string(path), "animated": .bool(animated)]), session: session)
        } catch {
            _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string("emojis"), "path": .string(path)]), session: session)
            throw error
        }
    }

    func nativeRenameServerEmoji(id: String, name: String, session: NativeSession) async throws {
        guard name.range(of: "^[A-Za-z0-9_]{2,32}$", options: .regularExpression) != nil else { throw NativeClientError.invalidResponse }
        let rows = try await table("emojis", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: "id")], method: "PATCH", values: .object(["name": .string(name)]), session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.api(status: 403, message: "Dieses Emoji konnte nicht umbenannt werden.") }
    }

    func nativeDeleteServerEmoji(_ record: NativeServerToolRecord, session: NativeSession) async throws {
        let result = try await table("emojis", query: [URLQueryItem(name: "id", value: "eq.\(record.id)"), URLQueryItem(name: "select", value: "id")], method: "DELETE", session: session, prefer: "return=representation").rows
        guard result.contains(where: { $0["id"].string == record.id }) else { throw NativeClientError.api(status: 403, message: "Dieses Emoji konnte nicht gelöscht werden.") }
        if record.row["owner_id"].string == session.userID, let path = record.row["path"].string { _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string("emojis"), "path": .string(path)]), session: session) }
    }

    func nativeDecideJoinRequest(id: String, accept: Bool, note: String, session: NativeSession) async throws {
        _ = try await rpc("decide_join_request", arguments: ["rid": .string(id), "p_accept": .bool(accept), "p_note": .string(String(note.prefix(300)))], session: session)
    }

    func nativeOpenTicket(serverID: String, topic: String, session: NativeSession) async throws -> String {
        let value = try await rpc("open_ticket", arguments: ["sid": .string(serverID), "topic": .string(topic)], session: session)
        guard let id = value.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func nativeServerBranding(server: NativeServer, image: Data?, contentType: String = "image/png", banner: Bool, remove: Bool = false, session: NativeSession) async throws {
        let bucket = banner ? "banners" : "icons"
        let path: String?
        if remove { path = nil }
        else if let image { path = try await uploadMedia(bucket: bucket, data: image, filename: "server-image.png", contentType: contentType, session: session) }
        else { throw NativeClientError.invalidResponse }
        do {
            if banner { _ = try await rpc("set_server_banner", arguments: ["sid": .string(server.id), "p": path.map(NativeJSON.string) ?? .null, "bx": server.raw["banner_x"].number.map(NativeJSON.number) ?? .number(50), "by": server.raw["banner_y"].number.map(NativeJSON.number) ?? .number(50), "bz": server.raw["banner_zoom"].number.map(NativeJSON.number) ?? .number(1)], session: session) }
            else { _ = try await rpc("update_server", arguments: ["sid": .string(server.id), "server_name": .string(server.name), "server_icon": path.map(NativeJSON.string) ?? .null], session: session) }
        } catch {
            if let path { _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string(bucket), "path": .string(path)]), session: session) }
            throw error
        }
    }
}
