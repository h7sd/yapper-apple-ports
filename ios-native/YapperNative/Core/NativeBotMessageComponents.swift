import Foundation

nonisolated struct NativeMessageButton: Identifiable, Sendable {
    let label: String
    let emoji: String
    let style: String
    let customID: String?
    let url: URL?
    let disabled: Bool
    var id: String { customID ?? url?.absoluteString ?? label + emoji }

    init?(_ row: NativeJSON) {
        guard let style = row["style"].string, ["primary", "secondary", "success", "danger", "link"].contains(style) else { return nil }
        let label = String((row["label"].string ?? "").prefix(80))
        let emoji = String((row["emoji"].string ?? row["emoji"]["name"].string ?? "").prefix(80))
        guard !label.isEmpty || !emoji.isEmpty else { return nil }
        if style == "link" {
            guard let raw = row["url"].string, raw.utf16.count <= 512, let url = Self.https(raw) else { return nil }
            self.url = url; customID = nil
        } else {
            guard let id = row["custom_id"].string, !id.isEmpty, id.utf16.count <= 100 else { return nil }
            customID = id; url = nil
        }
        self.label = label; self.emoji = emoji; self.style = style; disabled = row["disabled"].bool == true
    }

    static func https(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2048, let url = URL(string: raw), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return url
    }
}

nonisolated indirect enum NativeMessageComponent: Sendable {
    case text(String), buttons([NativeMessageButton]), group([NativeMessageComponent], spoiler: Bool, accent: Int?), image(URL, String, spoiler: Bool), file(URL, String, spoiler: Bool), separator(Bool, Bool)

    static func isV2(_ rows: [NativeJSON]) -> Bool { rows.contains { $0["type"].number != nil && $0["type"].int != 2 } }

    var emojiIDs: [String] {
        switch self {
        case let .text(text): NativeEmojiTokens.matches(text).map(\.id)
        case let .buttons(buttons): buttons.flatMap { NativeEmojiTokens.matches($0.emoji + " " + $0.label).map(\.id) }
        case let .group(children, _, _): children.flatMap(\.emojiIDs)
        default: []
        }
    }

    static func parse(_ rows: [NativeJSON]) -> [Self] {
        if !isV2(rows) {
            return rows.prefix(5).compactMap { row in
                let buttons = row["components"].array.prefix(5).compactMap(NativeMessageButton.init)
                return buttons.isEmpty ? nil : .buttons(buttons)
            }
        }
        var budget = 200
        func nodes(_ rows: [NativeJSON], depth: Int) -> [Self] {
            guard depth <= 6 else { return [] }
            var result: [Self] = []
            for row in rows.prefix(40) {
                guard budget > 0 else { break }; budget -= 1
                switch row["type"].int {
                case 17:
                    let accent = row["accent_color"].int.flatMap { (0...0xffffff).contains($0) ? $0 : nil }
                    result.append(.group(nodes(row["components"].array, depth: depth + 1), spoiler: row["spoiler"].bool == true, accent: accent))
                case 10: if let text = row["content"].string { result.append(.text(String(text.prefix(16_384)))) }
                case 9:
                    var parts = nodes(Array(row["components"].array.prefix(3)), depth: depth + 1)
                    let accessory = row["accessory"]
                    if accessory["type"].int == 2, let button = NativeMessageButton(accessory) { parts.append(.buttons([button])) }
                    else if accessory["type"].int == 11, let raw = accessory["media"]["url"].string, let url = NativeMessageButton.https(raw) { parts.append(.image(url, accessory["description"].string ?? "Bild", spoiler: accessory["spoiler"].bool == true)) }
                    result.append(.group(parts, spoiler: false, accent: nil))
                case 12:
                    for item in row["items"].array.prefix(10) {
                        if let raw = item["media"]["url"].string, let url = NativeMessageButton.https(raw) { result.append(.image(url, item["description"].string ?? "Bild", spoiler: item["spoiler"].bool == true)) }
                    }
                case 13: if let raw = row["file"]["url"].string, let url = NativeMessageButton.https(raw) { result.append(.file(url, row["name"].string ?? "Datei", spoiler: row["spoiler"].bool == true)) }
                case 14: result.append(.separator(row["divider"].bool != false, row["spacing"].int == 2))
                case 1:
                    let buttons = row["components"].array.prefix(5).compactMap(NativeMessageButton.init)
                    if !buttons.isEmpty { result.append(.buttons(buttons)) }
                default: break
                }
            }
            return result
        }
        return nodes(rows, depth: 0)
    }
}

nonisolated struct NativeBotInteractionReply: Identifiable, Sendable {
    let id: String
    let content: String
    let embeds: [NativeJSON]
    init(_ row: NativeJSON, interactionID: String, messageID: String, channelID: String, userID: String) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              row["interaction_id"].string == interactionID,
              row["channel_id"].string == channelID, row["user_id"].string == userID,
              row["kind"].string == "ephemeral" else { throw NativeClientError.invalidResponse }
        self.id = id; content = row["content"].string ?? ""; embeds = Array(row["embeds"].array.prefix(10))
    }
}

extension NativeAPI {
    func pressMessageButton(messageID: String, button: NativeMessageButton, session: NativeSession) async throws -> String {
        guard UUID(uuidString: messageID) != nil, !button.disabled, button.url == nil, let customID = button.customID else { throw NativeClientError.invalidResponse }
        let result = try await rpc("press_button", arguments: ["mid": .string(messageID), "button": .string(customID)], session: session)
        guard let id = result.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func messageButtonReplies(interactionID: String, messageID: String, channelID: String, session: NativeSession) async throws -> [NativeBotInteractionReply] {
        guard UUID(uuidString: interactionID) != nil else { throw NativeClientError.invalidResponse }
        let result = try await table("bot_interaction_replies", query: [URLQueryItem(name: "interaction_id", value: "eq.\(interactionID)"), URLQueryItem(name: "select", value: "id,interaction_id,bot_id,user_id,channel_id,message_id,kind,content,embeds,created_at")], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        // Non-ephemeral replies acknowledge an interaction but are rendered as ordinary messages.
        return try result.array.filter { $0["kind"].string == "ephemeral" }.prefix(20).map { try NativeBotInteractionReply($0, interactionID: interactionID, messageID: messageID, channelID: channelID, userID: session.userID) }
    }
}
