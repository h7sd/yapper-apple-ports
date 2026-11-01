import Foundation

extension NativeAPI {
    /// Observed preloadChannel: fetch the visible channel and its members, then their profiles.
    func conversationForSearchResult(_ message: ChatMessage, session: NativeSession) async throws -> Conversation {
        guard UUID(uuidString: message.channelID) != nil else { throw NativeClientError.invalidResponse }
        let rows = try await table("channels", query: [URLQueryItem(name: "id", value: "eq.\(message.channelID)"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "limit", value: "1")], session: session).rows
        guard let row = rows.first, row["id"].string == message.channelID, let kind = row["kind"].string,
              ["dm", "group", "text", "thread", "forum", "voice"].contains(kind) else { throw NativeClientError.invalidResponse }
        let memberRows = try await table("channel_members", query: [URLQueryItem(name: "channel_id", value: "eq.\(message.channelID)"), URLQueryItem(name: "select", value: "user_id")], session: session).rows
        let ids = memberRows.compactMap { $0["user_id"].string }.filter { $0 != session.userID }
        let profiles = try await socialProfiles(ids: ids, session: session)
        let title = row["name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? profiles.map(\.displayName).joined(separator: ", ")
        return Conversation(id: message.channelID, title: title.isEmpty ? "Gespräch" : kind == "text" ? "#" + title : title,
                            participants: profiles.map(\.user), avatarURL: NativeConfiguration.publicAsset(bucket: "icons", path: row["icon_path"].string),
                            isGroup: kind == "group", serverID: row["server_id"].string, lastMessageAt: row["last_message_at"].string.flatMap { try? NativeDate.parse($0) })
    }
}
