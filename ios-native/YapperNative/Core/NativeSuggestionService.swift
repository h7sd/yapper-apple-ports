import Foundation

nonisolated enum NativeSuggestionArea: String, CaseIterable, Identifiable, Sendable {
    case chat, voice, servers, profile, bots, mobile, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .chat: "Chat"
        case .voice: "Sprachanrufe"
        case .servers: "Server"
        case .profile: "Profil"
        case .bots: "Bots"
        case .mobile: "Mobile App"
        case .other: "Sonstiges"
        }
    }
}

nonisolated struct NativeSuggestion: Identifiable, Sendable {
    let id: String
    let userID: String
    let channelID: String?
    let messageID: String?
    let title: String
    let body: String
    let area: NativeSuggestionArea
    let status: String
    let staffNote: String?
    let createdAt: Date?
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let userID = row["user_id"].string, UUID(uuidString: userID) != nil,
              let title = row["title"].string, let body = row["body"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.userID = userID; self.title = title; self.body = body
        channelID = row["channel_id"].string; messageID = row["message_id"].string
        area = NativeSuggestionArea(rawValue: row["area"].string ?? "") ?? .other
        status = row["status"].string ?? "open"; staffNote = row["staff_note"].string
        createdAt = row["created_at"].string.flatMap { try? NativeDate.parse($0) }
    }
    var statusLabel: String {
        switch status {
        case "open": "Neu"
        case "planned": "Geplant"
        case "done": "Umgesetzt"
        case "declined": "Abgelehnt"
        default: "Status unbekannt"
        }
    }
}
nonisolated struct NativeSuggestionVotes: Sendable {
    var up: Int
    var down: Int
    var total: Int
}

extension NativeAPI {
    nonisolated static let suggestionServerID = "c479964e-033e-44ae-a4bf-523c4afe5c5c"

    func nativeSuggestionChannels(session: NativeSession) async throws -> [NativeServerChannel] {
        let rows = try await rpc("visible_server_channels", arguments: ["sids": .array([.string(Self.suggestionServerID)])], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map { try NativeServerChannel($0, serverID: Self.suggestionServerID) }
            .filter { $0.kind == "text" && ["suggestions-new", "suggestions"].contains($0.name) }
            .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name == "suggestions-new" }
    }

    func nativeMySuggestions(session: NativeSession) async throws -> [NativeSuggestion] {
        let rows = try await table("suggestions", query: [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "20")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        let suggestions = try rows.array.map(NativeSuggestion.init)
        guard suggestions.allSatisfy({ $0.userID == session.userID }) else { throw NativeClientError.invalidResponse }; return suggestions
    }

    func nativeSuggestionVotes(messageIDs: [String], session: NativeSession) async throws -> [String: NativeSuggestionVotes] {
        let ids = Array(Set(messageIDs)).sorted()
        guard ids.count <= 500, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NativeClientError.invalidResponse }
        guard !ids.isEmpty else { return [:] }
        let rows = try await rpc("suggestion_votes", arguments: ["ids": .array(ids.map(NativeJSON.string))], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        var result: [String: NativeSuggestionVotes] = [:]
        for row in rows.array {
            guard let id = row["message_id"].string, ids.contains(id), let up = row["up"].int, let down = row["down"].int, let total = row["total"].int,
                  up >= 0, down >= 0, total >= 0 else { throw NativeClientError.invalidResponse }
            result[id] = NativeSuggestionVotes(up: up, down: down, total: total)
        }
        return result
    }

    func nativeSubmitSuggestion(channel: NativeServerChannel, title: String, area: NativeSuggestionArea, body: String, session: NativeSession) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard channel.serverID == Self.suggestionServerID, channel.kind == "text", ["suggestions-new", "suggestions"].contains(channel.name),
              (5...100).contains(title.utf16.count), (10...1500).contains(body.utf16.count) else { throw NativeClientError.invalidResponse }
        _ = try await rpc("submit_suggestion", arguments: ["cid": .string(channel.id), "p_title": .string(title), "p_area": .string(area.rawValue), "p_body": .string(body)], session: session)
    }

    func nativeSuggestionOwnReactions(messageIDs: [String], session: NativeSession) async throws -> [NativeReaction] {
        let ids = Array(Set(messageIDs)).sorted()
        guard ids.count <= 500, ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw NativeClientError.invalidResponse }
        guard !ids.isEmpty else { return [] }
        let rows = try await table("reactions", query: [URLQueryItem(name: "select", value: "id,message_id,user_id,emoji"), URLQueryItem(name: "message_id", value: "in.(\(ids.joined(separator: ",")))"), URLQueryItem(name: "user_id", value: "eq.\(session.userID)")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map { row in
            guard let reaction = NativeReaction(row), reaction.userID == session.userID, ids.contains(reaction.messageID) else { throw NativeClientError.invalidResponse }; return reaction
        }
    }

    func nativeVoteSuggestion(_ suggestion: NativeSuggestion, emoji: String, session: NativeSession) async throws {
        guard ["👍", "👎"].contains(emoji), let mid = suggestion.messageID, let cid = suggestion.channelID,
              UUID(uuidString: mid) != nil, UUID(uuidString: cid) != nil else { throw NativeClientError.invalidResponse }
        // Verify that the posted message is still visible in this suggestion's actual channel.
        let rows = try await table("messages", query: [URLQueryItem(name: "select", value: "id,channel_id"), URLQueryItem(name: "id", value: "eq.\(mid)"), URLQueryItem(name: "channel_id", value: "eq.\(cid)")], session: session)
        guard case .array = rows, rows.array.count == 1, rows.array[0]["id"].string == mid, rows.array[0]["channel_id"].string == cid else { throw NativeClientError.invalidResponse }
        let own = try await nativeSuggestionOwnReactions(messageIDs: [mid], session: session)
        try await toggleReaction(messageID: mid, emoji: emoji, existing: own, session: session)
    }
}
