import Foundation

nonisolated struct NativeCustomEmoji: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL?
    let animated: Bool
    let serverID: String?
    var token: String { "<\(animated ? "a" : ""):\(name):\(id)>" }

    init?(_ row: NativeJSON) {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string, !name.isEmpty else { return nil }
        self.id = id; self.name = name
        url = NativeConfiguration.publicAsset(bucket: "emojis", path: row["path"].string)
        animated = row["animated"].bool == true; serverID = row["server_id"].string
    }
}

nonisolated struct NativeEmojiToken: Sendable {
    let id: String
    let name: String
    let range: NSRange
}

nonisolated enum NativeEmojiTokens {
    private static let pattern = try? NSRegularExpression(pattern: #"<(a?):([A-Za-z0-9_]{2,32}):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})>"#)

    static func matches(_ text: String) -> [NativeEmojiToken] {
        guard let pattern else { return [] }
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            NativeEmojiToken(id: string.substring(with: match.range(at: 3)), name: string.substring(with: match.range(at: 2)), range: match.range)
        }
    }
}

extension NativeAPI {
    func messageEmojis(ids: [String], session: NativeSession) async throws -> [String: NativeCustomEmoji] {
        let ids = Array(Set(ids)).filter { UUID(uuidString: $0) != nil }.sorted()
        guard !ids.isEmpty else { return [:] }
        var rows: [NativeJSON] = []
        for offset in stride(from: 0, to: ids.count, by: 100) {
            rows += try await rpc("emojis_by_ids", arguments: ["ids": .array(ids[offset..<min(ids.count, offset + 100)].map(NativeJSON.string))], session: session).rows
        }
        var result: [String: NativeCustomEmoji] = [:]
        for row in rows { if let emoji = NativeCustomEmoji(row), ids.contains(emoji.id) { result[emoji.id] = emoji } }
        return result
    }

    func availableMessageEmojis(session: NativeSession) async throws -> [NativeCustomEmoji] {
        let serverIDs = try await nativeJoinedServerIDs(session: session)
        var rows: [NativeJSON] = []
        for offset in stride(from: 0, to: serverIDs.count, by: 100) {
            let ids = serverIDs[offset..<min(offset + 100, serverIDs.count)]
            rows += try await table("emojis", query: [URLQueryItem(name: "server_id", value: "in.(\(ids.joined(separator: ",")))"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "limit", value: "5000")], session: session).rows
        }
        rows += try await table("emojis", query: [URLQueryItem(name: "owner_id", value: "eq.\(session.userID)"), URLQueryItem(name: "server_id", value: "is.null"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "limit", value: "5000")], session: session).rows
        var seen = Set<String>()
        return rows.compactMap(NativeCustomEmoji.init).filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
