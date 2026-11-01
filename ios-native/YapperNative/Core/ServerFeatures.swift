import Foundation

// Wire fields and permission rules observed in the official current web client:
// 33-dglfmrlo2q.js (servers), 1wdb3w49bvmss.js (hasPerm/role hierarchy).
nonisolated struct NativeServer: Identifiable, Hashable, Sendable {
    let raw: NativeJSON
    let id: String
    var name: String
    let ownerID: String?
    let iconPath: String?
    let description: String
    let discoverable: Bool
    let tags: [String]
    let memberCount: Int?
    let everyonePermissions: [String: Bool]

    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              let name = row["name"].string, !name.isEmpty else { throw NativeClientError.malformedResponse("Server") }
        raw = row; self.id = id; self.name = name
        ownerID = row["owner_id"].string
        iconPath = row["icon_path"].string
        description = row["description"].string ?? ""
        discoverable = row["discoverable"].bool ?? true
        tags = row["tags"].array.compactMap(\.string)
        memberCount = row["member_count"].int ?? row["members"].int ?? row["n"].int
        everyonePermissions = (row["everyone_perms"].object ?? [:]).compactMapValues(\.bool)
    }

    var iconURL: URL? { NativeConfiguration.publicAsset(bucket: "icons", path: iconPath) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated struct NativeServerChannel: Identifiable, Hashable, Sendable {
    let id: String
    let serverID: String
    let name: String
    let kind: String
    let categoryID: String?
    let parentID: String?
    let position: Int
    let createdAt: String
    let readOnly: Bool
    let isPrivate: Bool
    let slowmode: Int
    let stage: Bool
    let noGIFs: Bool
    let noImages: Bool
    let ticketBy: String?
    let forumTags: [NativeForumTag]
    let requireTag: Bool
    let guidelines: String
    let allowedRoles: Set<String>
    let postRoles: Set<String>

    init(_ row: NativeJSON, serverID expectedServer: String) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              row["server_id"].string == expectedServer,
              let kind = row["kind"].string, ["text", "voice", "forum", "thread"].contains(kind),
              let name = row["name"].string, !name.isEmpty else { throw NativeClientError.malformedResponse("Server channel") }
        self.id = id; serverID = expectedServer; self.name = name; self.kind = kind
        categoryID = row["category_id"].string; parentID = row["parent_id"].string
        position = row["position"].int ?? 0; createdAt = row["created_at"].string ?? ""
        readOnly = row["read_only"].bool ?? false; isPrivate = row["private"].bool ?? false
        slowmode = row["slowmode"].int ?? 0; stage = row["stage"].bool ?? false
        noGIFs = row["no_gifs"].bool ?? false; noImages = row["no_images"].bool ?? false
        ticketBy = row["ticket_by"].string
        forumTags = try row["forum_tags"].array.map(NativeForumTag.init)
        requireTag = row["require_tag"].bool ?? false; guidelines = row["guidelines"].string ?? ""
        allowedRoles = Set(row["allowedRoles"].array.compactMap(\.string))
        postRoles = Set(row["postRoles"].array.compactMap(\.string))
    }

    var symbol: String { kind == "voice" ? "speaker.wave.2" : kind == "forum" ? "text.bubble" : "number" }
    var conversation: Conversation { Conversation(id: id, title: kind == "text" ? "#" + name : name, participants: [], serverID: serverID) }
}

nonisolated struct NativeServerCategory: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let position: Int
    init(_ row: NativeJSON, serverID: String) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              row["server_id"].string == serverID, let name = row["name"].string else { throw NativeClientError.malformedResponse("Channel category") }
        self.id = id; self.name = name; position = row["position"].int ?? 0
    }
}

nonisolated struct NativeServerRole: Identifiable, Hashable, Sendable {
    let id: String
    let serverID: String
    var name: String
    var color: String?
    let position: Int
    let auto: String
    var manageServer: Bool
    var manageMessages: Bool
    var permissions: [String: Bool]
    let autoBefore: String?

    init(_ row: NativeJSON, serverID: String) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              row["server_id"].string == serverID, let name = row["name"].string else { throw NativeClientError.malformedResponse("Server role") }
        self.id = id; self.serverID = serverID; self.name = name
        color = row["color"].string; position = row["position"].int ?? 0
        auto = row["auto"].string ?? "none"; autoBefore = row["auto_before"].string
        manageServer = row["manage_server"].bool ?? false; manageMessages = row["manage_messages"].bool ?? false
        permissions = (row["perms"].object ?? [:]).compactMapValues(\.bool)
    }

    func grants(_ permission: String) -> Bool {
        permissions["administrator"] == true || permissions[permission] == true
            || (manageServer && Self.legacyManagement.contains(permission))
            || (manageMessages && Self.legacyModeration.contains(permission))
    }

    static let legacyManagement: Set<String> = ["manage_server", "manage_channels", "manage_roles", "manage_emojis", "kick_members", "ban_members", "timeout_members", "manage_nicknames", "manage_messages", "mention_everyone", "mute_members", "move_members"]
    static let legacyModeration: Set<String> = ["manage_messages", "timeout_members", "manage_nicknames", "mention_everyone", "mute_members"]
}

nonisolated struct NativeServerMember: Identifiable, Hashable, Sendable {
    let user: YapperUser
    let nickname: String?
    let joinedAt: String?
    var id: String { user.id }
    var displayName: String { nickname.flatMap { $0.isEmpty ? nil : $0 } ?? user.displayName }
}

nonisolated struct NativeServerSnapshot: Sendable {
    var server: NativeServer
    let channels: [NativeServerChannel]
    let categories: [NativeServerCategory]
    let members: [NativeServerMember]
    let roles: [NativeServerRole]
    let memberRoles: [String: Set<String>]

    var uncategorized: [NativeServerChannel] {
        let known = Set(categories.map(\.id))
        return channels.filter { $0.kind != "thread" && ($0.categoryID.map { known.contains($0) } != true) }
    }

    func channels(in category: NativeServerCategory) -> [NativeServerChannel] {
        channels.filter { $0.kind != "thread" && $0.categoryID == category.id }
    }

    func hasPermission(_ permission: String, userID: String?) -> Bool {
        guard let userID else { return false }
        if server.ownerID == userID { return true }
        let assigned = memberRoles[userID] ?? []
        return roles.contains { assigned.contains($0.id) && $0.auto == "none" && $0.grants(permission) }
            || (Self.defaultPermissions.contains(permission) && server.everyonePermissions[permission] != false)
    }

    func outranks(_ target: String, userID: String?) -> Bool {
        guard let userID, userID != target, server.ownerID != target else { return false }
        if server.ownerID == userID { return true }
        return topPosition(userID) > topPosition(target)
    }

    func topPosition(_ userID: String) -> Int {
        roles.filter { ($0.auto == "none") && (memberRoles[userID]?.contains($0.id) == true) }.map(\.position).max() ?? -1
    }

    static let defaultPermissions: Set<String> = ["send_messages", "add_reactions", "attach_files", "embed_links", "use_external_emojis", "create_invite", "change_nickname", "connect", "speak", "create_polls", "read_history", "send_voice_messages", "use_headings", "create_threads", "send_in_threads"]
}

nonisolated struct NativeForumTag: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let moderatorOnly: Bool
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, let name = row["name"].string else { throw NativeClientError.malformedResponse("Forum tag") }
        self.id = id; self.name = name; moderatorOnly = row["mod_only"].bool ?? false
    }
}

nonisolated struct NativeForumPost: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let authorID: String?
    let content: String
    let createdAt: String
    let lastMessageAt: String
    let messages: Int
    let tags: [String]
    let isClosed: Bool

    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let title = row["name"].string else { throw NativeClientError.malformedResponse("Forum post") }
        self.id = id; self.title = title; authorID = row["created_by"].string
        content = row["first"]["content"].string ?? ""; createdAt = row["created_at"].string ?? ""
        lastMessageAt = row["last_message_at"].string ?? createdAt
        messages = row["messages"].int ?? 0; tags = row["tags"].array.compactMap(\.string)
        isClosed = row["closed_at"].string != nil
    }
}

nonisolated enum NativeServerInput {
    static func inviteCode(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = text
        if text.contains("://") {
            guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
                  ["yapin.gg", "www.yapin.gg", "yapper.website", "www.yapper.website"].contains(url.host ?? ""),
                  url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { throw NativeClientError.invalidResponse }
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, parts[0] == "invite" else { throw NativeClientError.invalidResponse }
            code = String(parts[1])
        }
        guard !code.isEmpty, code.utf8.count <= 80,
              code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw NativeClientError.api(status: 400, message: "Gib einen gültigen Yapper-Einladungslink oder Code ein.") }
        return code
    }

    static func name(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw NativeClientError.api(status: 400, message: "Der Name muss zwischen 1 und 100 Zeichen lang sein.") }
        return name
    }
}
