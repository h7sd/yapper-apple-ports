import Foundation

nonisolated struct NativeChannelUnread: Equatable, Sendable {
    var unread: Int
    var mentions: Int
    var muted: Bool

    init(unread: Int = 0, mentions: Int = 0, muted: Bool = false) {
        self.unread = max(0, unread)
        self.mentions = min(max(0, mentions), self.unread)
        self.muted = muted
    }
}

nonisolated struct NativeMessageMentions: Hashable, Sendable {
    let userIDs: Set<String>
    let roleIDs: Set<String>
    let channelIDs: Set<String>
    let hereRecipientIDs: Set<String>
    let mentionsEveryone: Bool
    let mentionsHere: Bool
    let isForwarded: Bool

    init(content: String, hereRecipientIDs: [String] = []) {
        let uuid = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        func ids(_ prefix: String) -> Set<String> {
            guard let regex = try? NSRegularExpression(pattern: "<" + prefix + "(" + uuid + ")>") else { return [] }
            let text = content as NSString
            return Set(regex.matches(in: content, range: NSRange(location: 0, length: text.length)).compactMap {
                UUID(uuidString: text.substring(with: $0.range(at: 1)))?.uuidString.lowercased()
            })
        }
        userIDs = ids("@")
        roleIDs = ids("@&")
        channelIDs = ids("#")
        self.hereRecipientIDs = Set(hereRecipientIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })
        mentionsEveryone = content.range(of: #"(?<![\w@])@everyone\b"#, options: .regularExpression) != nil
        mentionsHere = content.range(of: #"(?<![\w@])@here\b"#, options: .regularExpression) != nil
        isForwarded = content.hasPrefix("↪ Forwarded\n")
    }

    /// `@here` alone is not proof: the server provides its eligible recipient IDs.
    func includes(userID: String, roleIDs: Set<String> = []) -> Bool {
        guard !isForwarded, let id = UUID(uuidString: userID)?.uuidString.lowercased() else { return false }
        return userIDs.contains(id) || mentionsEveryone || hereRecipientIDs.contains(id)
            || !self.roleIDs.isDisjoint(with: roleIDs.map { $0.lowercased() })
    }
}

nonisolated struct NativeIncomingMention: Identifiable, Equatable, Sendable {
    let id: String
    let channelID: String
    let serverID: String?
    let author: YapperUser
    let content: String
    let createdAt: Date
}

nonisolated struct NativeVoiceMember: Identifiable, Hashable, Sendable {
    let userID: String
    let muted: Bool
    let deafened: Bool
    let sharing: Bool
    var id: String { userID }
}

nonisolated struct NativePeerPresenceSnapshot: Sendable {
    let statuses: [String: String]
    let full: Bool
    let serverID: String?

    init(rows: NativeJSON, full: Bool, serverID: String?) throws {
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        var statuses: [String: String] = [:]
        for row in rows.array {
            let values = row.array
            guard values.count >= 2, let rawID = values[0].string,
                  let id = UUID(uuidString: rawID)?.uuidString.lowercased(), let status = values[1].string else {
                throw NativeClientError.invalidResponse
            }
            switch status {
            case "off", "invisible", "offline": statuses[id] = "offline"
            case "online", "idle", "dnd": statuses[id] = status
            default: throw NativeClientError.invalidResponse
            }
        }
        self.statuses = statuses
        self.full = full
        self.serverID = serverID
    }
}

extension NativeAPI {
    func nativeMentionMessage(id: String, channelID: String, authorID: String, session: NativeSession) async throws -> MessageRow? {
        guard [id, channelID, authorID].allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NativeClientError.invalidResponse }
        let result = try await table("messages", query: [URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "author_id", value: "eq.\(authorID)"),
            URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "limit", value: "1")], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        let rows = try JSONDecoder().decode([MessageRow].self, from: JSONEncoder().encode(result))
        guard rows.count <= 1 else { throw NativeClientError.invalidResponse }
        guard let row = rows.first else { return nil }
        guard row.confirmsSend(id: id, channelID: channelID, authorID: authorID), (try? NativeDate.parse(row.created_at)) != nil else {
            throw NativeClientError.invalidResponse
        }
        return row
    }

    /// Exact supported base route used by the current web client's version fallback.
    func nativeUnreadCounts(session: NativeSession) async throws -> [String: NativeChannelUnread] {
        let result = try await rpc("unread_counts_v2", session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        var values: [String: NativeChannelUnread] = [:]
        for row in result.array {
            guard let rawID = row["channel_id"].string, let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                  let unread = row["unread"].int, unread >= 0,
                  let mentions = row["mentions"].int, mentions >= 0,
                  row["unread"].number == Double(unread), row["mentions"].number == Double(mentions),
                  let muted = row["muted"].bool, values[id] == nil else { throw NativeClientError.invalidResponse }
            values[id] = NativeChannelUnread(unread: unread, mentions: mentions, muted: muted)
        }
        return values
    }

    func nativePeerPresence(serverID: String?, extraIDs: [String], session: NativeSession) async throws -> NativePeerPresenceSnapshot {
        let ids = Array(Set(extraIDs.compactMap { UUID(uuidString: $0)?.uuidString.lowercased() })).sorted().prefix(500)
        if let serverID, UUID(uuidString: serverID) == nil { throw NativeClientError.invalidResponse }
        let result = try await rpc("who_online", arguments: ["sid": serverID.map(NativeJSON.string) ?? .null,
            "extra": .array(ids.map(NativeJSON.string)), "since": .null], session: session)
        let hasCursor = result["now"].string.map { !$0.isEmpty } ?? result["now"].number.map { $0 != 0 } ?? false
        guard result.object != nil, hasCursor else { throw NativeClientError.invalidResponse }
        return try NativePeerPresenceSnapshot(rows: result["rows"], full: true, serverID: serverID)
    }

    func nativeChannelServerMap(serverIDs: Set<String>, session: NativeSession) async throws -> [String: String] {
        guard serverIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NativeClientError.invalidResponse }
        guard !serverIDs.isEmpty else { return [:] }
        let result = try await rpc("visible_server_channels", arguments: ["sids": .array(serverIDs.sorted().map(NativeJSON.string))], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        var mapping: [String: String] = [:]
        for row in result.array {
            guard let rawID = row["id"].string, let id = UUID(uuidString: rawID)?.uuidString.lowercased(),
                  let serverID = row["server_id"].string, serverIDs.contains(serverID), mapping[id] == nil else {
                throw NativeClientError.invalidResponse
            }
            mapping[id] = serverID
        }
        return mapping
    }

    func nativeMentionMessages(useV2: Bool, session: NativeSession) async throws -> [MessageRow] {
        let result = try await rpc(useV2 ? "my_mentions_v2" : "my_mentions", arguments: ["lim": .number(40)], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        return try JSONDecoder().decode([MessageRow].self, from: JSONEncoder().encode(result))
    }
}
