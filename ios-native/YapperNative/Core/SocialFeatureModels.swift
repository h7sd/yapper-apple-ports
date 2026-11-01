import Foundation

nonisolated struct NativeProfileDetail: Identifiable, Sendable, Equatable {
    let id: String
    let username: String
    var displayName: String
    var bio: String
    var pronouns: String
    var customStatus: String
    var avatarPath: String?
    var bannerPath: String?
    var accentColor: String?
    var accentColor2: String?
    var links: [String]
    var badges: [String]
    var createdAt: Date?
    var plusUntil: Date?
    var plusSince: Date?
    var plusBadgeHidden: Bool
    var accountLevel: Int?
    var serverTag: String?
    var serverID: String?
    var verifiedAs: String?
    var verifiedHidden: Bool
    var customStatusUntil: Date?
    var bannerX: Double
    var bannerY: Double
    var bannerZoom: Double
    var avatarX: Double
    var avatarY: Double
    var avatarZoom: Double
    var avatarRotation: Double
    var avatarDecoration: String?
    var profileEffect: String?
    var nameBanner: String?
    var avatarRevertAt: Date?
    var tagIconHidden: Bool
    var avatarURL: URL? { NativeConfiguration.publicAsset(bucket: "avatars", path: avatarPath) }
    var bannerURL: URL? { NativeConfiguration.publicAsset(bucket: "banners", path: bannerPath) }
    var user: YapperUser {
        YapperUser(id: id, username: username, displayName: displayName, avatarURL: avatarURL, bio: bio,
                   avatarDecorationURL: NativeConfiguration.communityCosmeticAsset(avatarDecoration, prefix: "c:"),
                   profileEffectURL: NativeConfiguration.communityCosmeticAsset(profileEffect, prefix: "p:"),
                   nameBannerURL: NativeConfiguration.communityCosmeticAsset(nameBanner, prefix: "c:"),
                   avatarCrop: NativeImageCrop(x: avatarX, y: avatarY, zoom: avatarZoom, rotation: avatarRotation))
    }

    init(row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              let username = row["username"].string, !username.isEmpty else { throw NativeClientError.invalidResponse }
        self.id = id
        self.username = username
        displayName = row["display_name"].string.flatMap { $0.isEmpty ? nil : $0 } ?? username
        bio = row["bio"].string ?? ""
        pronouns = row["pronouns"].string ?? ""
        customStatus = row["custom_status"].string ?? ""
        avatarPath = row["avatar_path"].string
        bannerPath = row["banner_path"].string
        accentColor = row["accent_color"].string
        accentColor2 = row["accent_color2"].string
        links = row["links"].array.compactMap { $0.string ?? $0["url"].string }
        badges = row["badges"].array.compactMap(\.string)
        createdAt = row["created_at"].string.flatMap { try? NativeDate.parse($0) }
        plusUntil = row["plus_until"].string.flatMap { try? NativeDate.parse($0) }
        plusSince = row["plus_since"].string.flatMap { try? NativeDate.parse($0) }
        plusBadgeHidden = row["plus_badge_hidden"].bool ?? false
        accountLevel = row["account_level"].int
        serverTag = row["tag"].string
        serverID = row["server_tag"].string
        verifiedAs = row["verified_as"].string
        verifiedHidden = row["verified_hidden"].bool ?? false
        customStatusUntil = row["custom_status_until"].string.flatMap { try? NativeDate.parse($0) }
        bannerX = row["banner_x"].number ?? 50
        bannerY = row["banner_y"].number ?? 50
        bannerZoom = row["banner_zoom"].number ?? 1
        avatarX = row["avatar_x"].number ?? 50
        avatarY = row["avatar_y"].number ?? 50
        avatarZoom = row["avatar_zoom"].number ?? 1
        avatarRotation = row["avatar_rot"].number ?? 0
        avatarDecoration = row["avatar_deco"].string
        profileEffect = row["profile_effect"].string
        nameBanner = row["name_banner"].string
        avatarRevertAt = row["avatar_revert_at"].string.flatMap { try? NativeDate.parse($0) }
        tagIconHidden = row["tag_icon_off"].bool ?? false
    }
}

nonisolated struct NativeSocialMatch: Identifiable, Sendable {
    let profile: NativeProfileDetail
    let sharedInterests: [String]
    let interestCount: Int
    let sharedServers: [String]
    let serverCount: Int
    var id: String { profile.id }
    init(row: NativeJSON, profile: NativeProfileDetail) throws {
        guard row["user_id"].string == profile.id, case .array = row["items"], case .array = row["servers"],
              let interestCount = row["items_n"].int, let serverCount = row["servers_n"].int else { throw NativeClientError.invalidResponse }
        self.profile = profile; self.interestCount = interestCount; self.serverCount = serverCount
        sharedInterests = row["items"].array.compactMap { $0["title"].string }
        sharedServers = try row["servers"].array.map { value in
            guard let name = value.string else { throw NativeClientError.invalidResponse }
            return name
        }
    }
}

nonisolated struct NativeServerTagChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let tag: String
    let icon: String?
}



nonisolated enum NativeFriendRelation: String, CaseIterable, Sendable {
    case accepted, incoming, outgoing
    var label: String {
        switch self {
        case .accepted: "Freundschaft"
        case .incoming: "Eingehende Anfrage"
        case .outgoing: "Gesendete Anfrage"
        }
    }
}

nonisolated struct NativeFriendEntry: Identifiable, Sendable {
    let profile: NativeProfileDetail
    let relation: NativeFriendRelation
    let requestNote: String?
    var id: String { profile.id }
}

nonisolated struct NativeSocialSnapshot: Sendable {
    var friends: [NativeFriendEntry]
    var blocked: [NativeProfileDetail]
    var requests: [NativeProfileDetail]
}

nonisolated struct NativeInboxItem: Identifiable, Sendable {
    let id: String
    let kind: String
    let at: Date
    let userID: String?
    let channelID: String?
    let messageID: String?
    let title: String
    let content: String
    var isUnread: Bool

    init(row: NativeJSON, readBefore: Date?, readKeys: Set<String>) throws {
        guard let id = row["key"].string, !id.isEmpty,
              let timestamp = row["at"].string else { throw NativeClientError.invalidResponse }
        self.id = id
        let parsedAt = try NativeDate.parse(timestamp)
        at = parsedAt
        kind = row["kind"].string ?? "notice"
        userID = row["user_id"].string
        channelID = row["channel_id"].string
        messageID = row["message_id"].string
        title = row["title"].string ?? row["name"].string ?? Self.title(for: kind)
        content = row["content"].string ?? row["body"].string ?? row["text"].string ?? row["reason"].string ?? ""
        isUnread = row["seen"].bool != true && !readKeys.contains(id) && readBefore.map { parsedAt > $0 } != false
    }

    private static func title(for kind: String) -> String {
        switch kind {
        case "friend": "Freundschaftsanfrage"
        case "call": "Verpasster Anruf"
        case "partner": "Partnerschaft"
        case "creator": "Creator-Programm"
        case "bot": "Bot"
        default: "Benachrichtigung"
        }
    }
}

nonisolated struct NativeProfileDraft: Sendable {
    var username: String
    var displayName: String
    var bio: String
    var pronouns: String
    var customStatus: String
    var accentColor: String
    var accentColor2: String
    var customStatusUntil: Date?
    var bannerX: Double
    var bannerY: Double
    var bannerZoom: Double
    var avatarX: Double
    var avatarY: Double
    var avatarZoom: Double
    var avatarRotation: Double

    init(profile: NativeProfileDetail) {
        username = profile.username
        displayName = profile.displayName
        bio = profile.bio
        pronouns = profile.pronouns
        customStatus = profile.customStatus
        accentColor = profile.accentColor ?? ""
        accentColor2 = profile.accentColor2 ?? ""
        if let until = profile.customStatusUntil, until <= Date() {
            customStatus = ""; customStatusUntil = nil
        } else { customStatusUntil = profile.customStatusUntil }
        bannerX = profile.bannerX; bannerY = profile.bannerY; bannerZoom = profile.bannerZoom
        avatarX = profile.avatarX; avatarY = profile.avatarY; avatarZoom = profile.avatarZoom; avatarRotation = profile.avatarRotation
    }

    func values() throws -> [String: NativeJSON] {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_.]{2,32}$", options: .regularExpression) != nil else {
            throw NativeClientError.api(status: 400, message: "Benutzernamen brauchen 2 bis 32 Buchstaben, Zahlen, Punkte oder Unterstriche.")
        }
        guard bio.utf16.count <= 300, customStatus.utf16.count <= 80 else {
            throw NativeClientError.api(status: 400, message: "Die Bio darf höchstens 300 Zeichen haben, der Status höchstens 80.")
        }
        for color in [accentColor, accentColor2] where !color.isEmpty {
            guard color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                throw NativeClientError.api(status: 400, message: "Gib eine Farbe als #RRGGBB ein oder lasse das Feld leer.")
            }
        }
        func optional(_ text: String) -> NativeJSON {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? .null : .string(clean)
        }
        guard (0...100).contains(bannerX), (0...100).contains(bannerY), bannerZoom.isFinite, bannerZoom > 0,
              (0...100).contains(avatarX), (0...100).contains(avatarY), avatarZoom.isFinite, avatarZoom > 0,
              avatarRotation.isFinite else { throw NativeClientError.invalidResponse }
        return ["username": .string(name), "display_name": optional(displayName), "bio": .string(bio.trimmingCharacters(in: .whitespacesAndNewlines)),
                "pronouns": optional(pronouns), "custom_status": optional(customStatus),
                "custom_status_until": customStatusUntil.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "accent_color": optional(accentColor), "accent_color2": optional(accentColor2),
                "banner_x": .number(bannerX), "banner_y": .number(bannerY), "banner_zoom": .number(bannerZoom),
                "avatar_x": .number(avatarX), "avatar_y": .number(avatarY), "avatar_zoom": .number(avatarZoom), "avatar_rot": .number(avatarRotation)]
    }
}
