import Foundation

// Observed contracts: official current 33-dglfmrlo2q.js and 120u8hxm8jr9b.js.
// These are normal authenticated client requests, subject to server permissions.
extension NativeAPI {
    func messageFeatures(ids: [String], channelID: String, session: NativeSession) async throws -> NativeMessageFeatureSnapshot {
        let ids = Array(Set(ids)).filter { UUID(uuidString: $0) != nil }.sorted()
        guard !ids.isEmpty, ids.count <= 100 else { return NativeMessageFeatureSnapshot(details: [:], reactions: [:], replies: [:]) }
        let rows = try await table("messages", query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"), URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "select", value: "id,reply_to_id,pinned_at,voice_secs,voice_wave,embeds")], session: session).rows
        let reactionRows = try await table("reactions", query: [URLQueryItem(name: "message_id", value: "in.(\(ids.joined(separator: ",")))"), URLQueryItem(name: "select", value: "id,message_id,user_id,emoji")], session: session).rows
        var details: [String: NativeMessageDetail] = [:]
        for row in rows { if let id = row["id"].string, ids.contains(id) { details[id] = NativeMessageDetail(row) } }
        var reactions: [String: [NativeReaction]] = [:]
        for row in reactionRows { if let reaction = NativeReaction(row), ids.contains(reaction.messageID) { reactions[reaction.messageID, default: []].append(reaction) } }
        let replyIDs = Array(Set(details.values.compactMap(\.replyToID))).filter { UUID(uuidString: $0) != nil }
        var replies: [String: ChatMessage] = [:]
        if !replyIDs.isEmpty {
            let replyRows = try await table("messages", query: [URLQueryItem(name: "id", value: "in.(\(replyIDs.joined(separator: ",")))"), URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "select", value: "*")], session: session).rows
            let profiles = try await messageProfiles(rows: replyRows, session: session)
            for row in replyRows { let item = try NativeMessageResult(json: row, profiles: profiles); replies[item.id] = item.message }
        }
        return NativeMessageFeatureSnapshot(details: details, reactions: reactions, replies: replies)
    }

    func sendReply(id: String, text: String, replyToID: String, channelID: String, session: NativeSession, messagePolicy: NativeMessagePolicy = .standard) async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NativeClientError.emptyMessage }
        try messagePolicy.validate(text, for: session.userID)
        guard UUID(uuidString: id) != nil, UUID(uuidString: replyToID) != nil else { throw NativeClientError.invalidResponse }
        let values = NativeJSON.object(["id": .string(id), "channel_id": .string(channelID), "author_id": .string(session.userID), "content": .string(text), "reply_to_id": .string(replyToID)])
        do {
            let rows = try await table("messages", query: [URLQueryItem(name: "select", value: "id")], method: "POST", values: values, session: session, prefer: "return=representation").rows
            guard rows.contains(where: { $0["id"].string == id }) else { throw NativeClientError.invalidResponse }
        } catch let NativeClientError.api(status, _) where status == 409 {
            let rows = try await table("messages", query: [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "author_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "id")], session: session).rows
            guard rows.count == 1, rows[0]["id"].string == id else { throw NativeClientError.invalidResponse }
        }
    }

    func editMessage(_ message: ChatMessage, text: String, session: NativeSession, messagePolicy: NativeMessagePolicy = .standard) async throws {
        guard message.author.id == session.userID else { throw NativeClientError.api(status: 403, message: "Du kannst nur deine eigenen Nachrichten bearbeiten.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !message.attachments.isEmpty else { throw NativeClientError.emptyMessage }
        try messagePolicy.validate(text, for: session.userID)
        let rows = try await table("messages", query: [URLQueryItem(name: "id", value: "eq.\(message.id)"), URLQueryItem(name: "select", value: "id")], method: "PATCH", values: .object(["content": .string(text)]), session: session, prefer: "return=representation").rows
        guard rows.contains(where: { $0["id"].string == message.id }) else { throw NativeClientError.api(status: 404, message: "Diese Nachricht wurde bereits entfernt oder kann nicht bearbeitet werden.") }
    }

    func deleteMessage(_ message: ChatMessage, session: NativeSession) async throws {
        guard message.author.id == session.userID else { throw NativeClientError.api(status: 403, message: "Du kannst nur deine eigenen Nachrichten löschen.") }
        let rows = try await table("messages", query: [URLQueryItem(name: "id", value: "eq.\(message.id)"), URLQueryItem(name: "select", value: "id,author_id,attachment_path")], method: "DELETE", session: session, prefer: "return=representation").rows
        guard let deleted = rows.first, deleted["id"].string == message.id else { throw NativeClientError.api(status: 403, message: "Diese Nachricht konnte nicht gelöscht werden.") }
        if deleted["author_id"].string == session.userID, let path = deleted["attachment_path"].string {
            _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string("attachments"), "path": .string(path)]), session: session)
        }
    }

    func toggleReaction(messageID: String, emoji: String, existing: [NativeReaction], session: NativeSession) async throws {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty, emoji.utf8.count <= 160 else { throw NativeClientError.invalidResponse }
        if existing.contains(where: { $0.userID == session.userID && $0.emoji == emoji }) {
            _ = try await table("reactions", query: [URLQueryItem(name: "message_id", value: "eq.\(messageID)"), URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "emoji", value: "eq.\(emoji)"), URLQueryItem(name: "select", value: "id")], method: "DELETE", session: session, prefer: "return=representation")
        } else {
            guard existing.contains(where: { $0.emoji == emoji }) || Set(existing.map(\.emoji)).count < 20 else { throw NativeClientError.api(status: 400, message: "Diese Nachricht hat bereits 20 verschiedene Reaktionen.") }
            do {
                _ = try await table("reactions", query: [URLQueryItem(name: "select", value: "id,message_id,user_id,emoji")], method: "POST", values: .object(["message_id": .string(messageID), "user_id": .string(session.userID), "emoji": .string(emoji)]), session: session, prefer: "return=representation")
            } catch let NativeClientError.api(status, _) where status == 409 {
                let rows = try await table("reactions", query: [URLQueryItem(name: "message_id", value: "eq.\(messageID)"), URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "emoji", value: "eq.\(emoji)"), URLQueryItem(name: "select", value: "id")], session: session).rows
                guard !rows.isEmpty else { throw NativeClientError.invalidResponse }
            }
        }
    }

    func pinMessage(id: String, pinned: Bool, session: NativeSession) async throws {
        _ = try await rpc("pin_message", arguments: ["mid": .string(id), "pinned": .bool(pinned)], session: session)
    }

    func pinnedMessages(channelID: String, session: NativeSession) async throws -> [NativeMessageResult] {
        let rows = try await table("messages", query: [URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "pinned_at", value: "not.is.null"), URLQueryItem(name: "order", value: "pinned_at.desc"), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "select", value: "*")], session: session).rows
        let profiles = try await messageProfiles(rows: rows, session: session)
        return try rows.map { try NativeMessageResult(json: $0, profiles: profiles) }
    }

    func searchMessages(_ search: NativeMessageSearch, channelID: String?, serverID: String? = nil, session: NativeSession) async throws -> [NativeMessageResult] {
        var args = search.arguments(channelID: channelID, serverID: serverID)
        var rows: [NativeJSON]
        do { rows = try await rpc("search_messages_v4", arguments: args, session: session).rows }
        catch let NativeClientError.api(status, message) where status == 404 || message.contains("search_messages_v4") || message.contains("PGRST202") || message.contains("schema cache") {
            args.removeValue(forKey: "mention"); args.removeValue(forKey: "pinned")
            if ["embed", "sound", "poll"].contains(search.has ?? "") { args["has"] = .null }
            do { rows = try await rpc("search_messages_v3", arguments: args, session: session).rows }
            catch let NativeClientError.api(status, message) where status == 404 || message.contains("search_messages_v3") || message.contains("PGRST202") || message.contains("schema cache") {
                args.removeValue(forKey: "since"); args.removeValue(forKey: "has")
                rows = try await rpc("search_messages_v2", arguments: args, session: session).rows
            }
        }
        if let channelID { guard rows.allSatisfy({ $0["channel_id"].string == channelID }) else { throw NativeClientError.invalidResponse } }
        rows = rows.filter(search.matches)
        let profiles = try await messageProfiles(rows: rows, session: session)
        return try rows.map { try NativeMessageResult(json: $0, profiles: profiles) }
    }

    private func messageProfiles(rows: [NativeJSON], session: NativeSession) async throws -> [String: YapperUser] {
        let ids = Array(Set(rows.compactMap { $0["author_id"].string })).filter { UUID(uuidString: $0) != nil }.sorted()
        guard !ids.isEmpty else { return [:] }
        let profiles = try await table("profiles", query: [URLQueryItem(name: "id", value: "in.(\(ids.joined(separator: ",")))"), URLQueryItem(name: "select", value: "*")], session: session).rows
        var result: [String: YapperUser] = [:]
        for row in profiles {
            guard let id = row["id"].string, let username = row["username"].string, ids.contains(id) else { continue }
            let decoded = try JSONDecoder().decode(ProfileRow.self, from: JSONEncoder().encode(row))
            guard decoded.username == username else { throw NativeClientError.invalidResponse }
            result[id] = decoded.user()
        }
        return result
    }
}
