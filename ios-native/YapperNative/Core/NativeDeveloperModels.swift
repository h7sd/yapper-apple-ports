import Foundation

nonisolated enum NativeBotCategory: String, CaseIterable, Identifiable, Sendable {
    case moderation, fun, games, utility, music, economy, social, ai, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .moderation: "Moderation"
        case .fun: "Unterhaltung"
        case .games: "Spiele"
        case .utility: "Werkzeuge"
        case .music: "Musik"
        case .economy: "Wirtschaft"
        case .social: "Community"
        case .ai: "KI"
        case .other: "Sonstige"
        }
    }
}

nonisolated struct NativeBotCommand: Identifiable, Sendable {
    let name: String
    let description: String
    var id: String { name }
    init(_ row: NativeJSON) throws {
        guard let name = row["name"].string, !name.isEmpty else { throw NativeClientError.invalidResponse }
        self.name = name; description = row["description"].string ?? ""
    }
}

nonisolated struct NativeDirectoryBot: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: NativeBotCategory
    let ownerName: String
    let serverCount: Int
    let commandCount: Int
    let online: Bool
    let verifiedAt: Date?
    let commands: [NativeBotCommand]
    var profile: NativeProfileDetail?
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string,
              case .array = row["command_list"] else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; description = row["description"].string ?? ""
        category = NativeBotCategory(rawValue: row["category"].string ?? "") ?? .other
        ownerName = row["owner_name"].string ?? ""; serverCount = row["servers"].int ?? 0
        commandCount = row["commands"].int ?? 0; online = row["online"].bool ?? false
        verifiedAt = row["verified_at"].string.flatMap { try? NativeDate.parse($0) }
        commands = try row["command_list"].array.map(NativeBotCommand.init)
    }
}

nonisolated struct NativeBotInstallTarget: Identifiable, Sendable {
    let id: String
    let name: String
    let added: Bool
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string,
              let added = row["added"].bool else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; self.added = added
    }
}

nonisolated struct NativeOwnedBot: Identifiable, Sendable {
    let id: String
    let name: String
    let tag: String?
    let description: String
    let category: NativeBotCategory
    let isPublic: Bool
    let unlisted: Bool
    let shareable: Bool
    let verified: Bool
    let reviewNote: String?
    let supportInvite: String?
    let lastPollAt: Date?
    var webhookURL: String?
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; tag = row["tag"].string
        description = row["description"].string ?? ""; category = NativeBotCategory(rawValue: row["category"].string ?? "") ?? .other
        isPublic = row["public"].bool ?? false; unlisted = row["unlisted"].bool ?? false
        shareable = row["shareable"].bool ?? false; verified = row["verified_at"].string != nil
        reviewNote = row["review_note"].string; supportInvite = row["support_invite"].string
        lastPollAt = row["last_poll_at"].string.flatMap { try? NativeDate.parse($0) }
        webhookURL = row["webhook_url"].string
    }
}

nonisolated struct NativeOAuthApplication: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let redirectURIs: [String]
    let iconPath: String?
    let users: Int
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string,
              case .array = row["redirect_uris"] else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; description = row["description"].string ?? ""
        redirectURIs = try row["redirect_uris"].array.map { value in
            guard let uri = value.string else { throw NativeClientError.invalidResponse }; return uri
        }
        iconPath = row["icon_path"].string; users = row["users"].int ?? 0
    }
}

nonisolated struct NativeBotActivity: Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let emoji: String
    let description: String
    let verified: Bool
    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string,
              let url = row["url"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; self.url = url
        emoji = row["emoji"].string ?? ""; description = row["description"].string ?? ""; verified = row["verified"].bool ?? false
    }
}

nonisolated enum NativeDeveloperInput {
    static func redirectURI(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf16.count <= 500, !value.contains("#"), !value.contains("\\"),
              value.utf8.allSatisfy({ (33...126).contains($0) }), let components = URLComponents(string: value),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return false }
        let pattern = "^(https://[A-Za-z0-9.-]+|http://(localhost|127\\.0\\.0\\.1|\\[::1\\]))(:[0-9]{1,5})?(/.*)?$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
    static func https(_ value: String) -> Bool {
        guard let url = URL(string: value), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
    static func secret(_ row: NativeJSON, key: String) throws -> String {
        guard let value = row[key].string, !value.isEmpty, value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NativeClientError.invalidResponse }
        return value
    }
}
