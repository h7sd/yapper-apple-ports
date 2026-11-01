import Foundation
import Observation

nonisolated struct NativeReaction: Identifiable, Hashable, Sendable {
    let id: String
    let messageID: String
    let userID: String
    let emoji: String

    init?(_ json: NativeJSON) {
        guard let id = json["id"].string, let message = json["message_id"].string,
              let user = json["user_id"].string, let emoji = json["emoji"].string,
              !id.isEmpty, !message.isEmpty, !user.isEmpty, !emoji.isEmpty else { return nil }
        self.id = id; messageID = message; userID = user; self.emoji = emoji
    }
}

nonisolated struct NativeReactionGroup: Identifiable, Sendable {
    var id: String { emoji }
    let emoji: String
    let count: Int
    let isMine: Bool

    static func groups(_ rows: [NativeReaction], currentUserID: String?) -> [Self] {
        var order: [String] = []
        var groups: [String: [NativeReaction]] = [:]
        for row in rows {
            if groups[row.emoji] == nil { order.append(row.emoji) }
            groups[row.emoji, default: []].append(row)
        }
        return order.map { emoji in
            let values = groups[emoji] ?? []
            return Self(emoji: emoji, count: Set(values.map(\.userID)).count,
                        isMine: values.contains { $0.userID == currentUserID })
        }
    }
}

nonisolated struct NativeMessageDetail: Sendable {
    let replyToID: String?
    let pinnedAt: String?
    let voiceSeconds: Double?
    let voiceWave: String?
    let embeds: [NativeJSON]
    let components: [NativeJSON]

    init(_ json: NativeJSON) {
        replyToID = json["reply_to_id"].string
        pinnedAt = json["pinned_at"].string
        voiceSeconds = json["voice_secs"].number.flatMap { $0.isFinite && $0 > 0 && $0 <= 305 ? $0 : nil }
        voiceWave = json["voice_wave"].string
        embeds = json["embeds"].array
        components = json["components"].array
    }
}

nonisolated struct NativeMessageResult: Identifiable, Sendable {
    var id: String { message.id }
    let message: ChatMessage
    let detail: NativeMessageDetail

    init(json: NativeJSON, profiles: [String: YapperUser]) throws {
        guard let id = json["id"].string, !id.isEmpty,
              let channel = json["channel_id"].string, !channel.isEmpty,
              let created = json["created_at"].string else { throw NativeClientError.malformedResponse("Message identity") }
        let authorID = json["author_id"].string ?? "system"
        let author = profiles[authorID] ?? YapperUser(id: authorID, username: authorID == "system" ? "System" : "Unbekannt")
        var attachments: [MessageAttachment] = []
        if let path = json["attachment_path"].string, !path.isEmpty {
            attachments.append(MessageAttachment(id: id + ":attachment", url: NativeConfiguration.publicAsset(bucket: "attachments", path: path),
                                                 filename: json["attachment_name"].string ?? "Anhang",
                                                 contentType: NativeMessageMedia.contentType(path: path)))
        }
        message = ChatMessage(id: id, channelID: channel, author: author, content: json["content"].string ?? "",
                              createdAt: try NativeDate.parse(created), attachments: attachments, isEdited: json["edited_at"].string != nil, grouping: .from(system: json["system"], replyToID: json["reply_to_id"].string, webhook: json["webhook"]))
        detail = NativeMessageDetail(json)
    }
}

nonisolated enum NativeMessageMedia {
    static func contentType(path: String) -> String? {
        let ext = URL(fileURLWithPath: path.components(separatedBy: "?")[0]).pathExtension.lowercased()
        return ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
                "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm", "m4v": "video/mp4",
                "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav", "ogg": "audio/ogg", "oga": "audio/ogg", "opus": "audio/opus", "weba": "audio/webm", "flac": "audio/flac", "aac": "audio/aac",
                "pdf": "application/pdf", "txt": "text/plain", "zip": "application/zip"][ext]
    }

    static func isImage(_ attachment: MessageAttachment) -> Bool {
        (attachment.contentType ?? contentType(path: attachment.url?.path ?? attachment.filename) ?? "").hasPrefix("image/")
    }

    static func isPlayable(_ attachment: MessageAttachment) -> Bool {
        let type = attachment.contentType ?? contentType(path: attachment.url?.path ?? attachment.filename) ?? ""
        return type.hasPrefix("audio/") || type.hasPrefix("video/")
    }
}

nonisolated struct NativeMessageSearch: Sendable {
    var query = ""
    var author: String?
    var before: String?
    var since: String?
    var has: String?
    var pinned = false
    var mention: String?

    func arguments(channelID: String?, serverID: String? = nil) -> [String: NativeJSON] {
        ["q": .string(query.trimmingCharacters(in: .whitespacesAndNewlines)), "sid": serverID.map(NativeJSON.string) ?? .null, "cid": channelID.map(NativeJSON.string) ?? .null,
         "author": author.map(NativeJSON.string) ?? .null, "before": before.map(NativeJSON.string) ?? .null,
         "since": since.map(NativeJSON.string) ?? .null, "has": has.map(NativeJSON.string) ?? .null,
         "mention": mention.map(NativeJSON.string) ?? .null, "pinned": .bool(pinned)]
    }

    func matches(_ row: NativeJSON) -> Bool {
        if pinned && row["pinned_at"].string == nil { return false }
        if let author, row["author_id"].string != author { return false }
        if let mention, !(row["content"].string ?? "").contains("<@\(mention)>") { return false }
        if let since {
            guard let date = row["created_at"].string.flatMap({ try? NativeDate.parse($0) }), let boundary = try? NativeDate.parse(since), date > boundary else { return false }
        }
        if let before {
            guard let date = row["created_at"].string.flatMap({ try? NativeDate.parse($0) }), let boundary = try? NativeDate.parse(before), date < boundary else { return false }
        }
        let path = row["attachment_path"].string ?? ""
        let type = NativeMessageMedia.contentType(path: path) ?? ""
        switch has {
        case "image": return type.hasPrefix("image/")
        case "video": return type.hasPrefix("video/")
        case "sound": return type.hasPrefix("audio/")
        case "file": return !path.isEmpty
        case "link": return (row["content"].string ?? "").range(of: "https?://", options: .regularExpression) != nil
        case "embed": return !row["embeds"].array.isEmpty
        case "poll": return (row["content"].string ?? "").hasPrefix("📊 ")
        default: return true
        }
    }
}

@MainActor @Observable final class NativeMessageFeatures {
    private(set) var details: [String: NativeMessageDetail] = [:]
    private(set) var reactions: [String: [NativeReaction]] = [:]
    private(set) var replies: [String: ChatMessage] = [:]
    private(set) var emojis: [String: NativeCustomEmoji] = [:]
    private(set) var isWorking = false
    var errorMessage: String?
    private var revision = 0
    private var pending: Set<String> = []

    func cancel() { revision += 1; pending.removeAll(); isWorking = false }

    func load(store: NativeStore, messages: [ChatMessage], channelID: String) async {
        let generation = revision
        let recent = Set(messages.suffix(50).map(\.id))
        let ids = messages.map(\.id).filter { UUID(uuidString: $0) != nil && (details[$0] == nil || recent.contains($0)) }
        guard !ids.isEmpty else { return }
        do {
            let snapshot = try await store.withAuthenticatedSession { api, session in
                var allDetails: [String: NativeMessageDetail] = [:]
                var allReactions: [String: [NativeReaction]] = [:]
                var allReplies: [String: ChatMessage] = [:]
                for offset in stride(from: 0, to: ids.count, by: 100) {
                    let page = try await api.messageFeatures(ids: Array(ids[offset..<min(ids.count, offset + 100)]), channelID: channelID, session: session)
                    allDetails.merge(page.details) { _, fresh in fresh }; allReactions.merge(page.reactions) { _, fresh in fresh }; allReplies.merge(page.replies) { _, fresh in fresh }
                }
                let snapshot = NativeMessageFeatureSnapshot(details: allDetails, reactions: allReactions, replies: allReplies)
                let texts = messages.map(\.content) + snapshot.reactions.values.flatMap { $0.map(\.emoji) }
                let emojiIDs = Array(Set(texts.flatMap { NativeEmojiTokens.matches($0).map(\.id) }))
                let emojiRows = try await api.messageEmojis(ids: emojiIDs, session: session)
                return NativeMessageFeatureSnapshot(details: snapshot.details, reactions: snapshot.reactions, replies: snapshot.replies, emojis: emojiRows)
            }
            guard generation == revision, !Task.isCancelled else { return }
            details.merge(snapshot.details) { _, fresh in fresh }
            for id in ids { reactions[id] = snapshot.reactions[id] ?? [] }
            for replyID in snapshot.details.values.compactMap(\.replyToID) { replies[replyID] = snapshot.replies[replyID] }
            emojis.merge(snapshot.emojis) { _, fresh in fresh }
        } catch is CancellationError {} catch {
            guard generation == revision else { return }
            errorMessage = error.localizedDescription
        }
    }

    func perform(store: NativeStore, key: String, operation: @escaping @MainActor (NativeAPI, NativeSession) async throws -> Void) async -> Bool {
        guard !pending.contains(key) else { return false }
        let generation = revision
        pending.insert(key); isWorking = true; errorMessage = nil
        defer { if generation == revision { pending.remove(key); isWorking = !pending.isEmpty } }
        do {
            _ = try await store.withAuthenticatedSession { api, session in
                try await operation(api, session)
                return true
            }
            return generation == revision && !Task.isCancelled
        } catch is CancellationError { return false }
        catch {
            if generation == revision { errorMessage = error.localizedDescription }
            return false
        }
    }
}

nonisolated struct NativeMessageFeatureSnapshot: Sendable {
    let details: [String: NativeMessageDetail]
    let reactions: [String: [NativeReaction]]
    let replies: [String: ChatMessage]
    var emojis: [String: NativeCustomEmoji] = [:]
}
