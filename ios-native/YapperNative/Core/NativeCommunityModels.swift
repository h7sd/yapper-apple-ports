import Foundation

nonisolated struct NativeShardBalance: Sendable {
    let balance: Int
    let earned: Int
    let level: Int
    let nextCost: Int?
    let streak: Int
    let frozen: Bool
    init(row: NativeJSON) throws {
        guard let balance = row["balance"].int, let earned = row["earned"].int,
              let level = row["level"].int, balance >= 0, level >= 0 else { throw NativeClientError.invalidResponse }
        self.balance = balance; self.earned = earned; self.level = level
        nextCost = row["next_cost"].int; streak = row["streak"].int ?? 0; frozen = row["frozen"].bool ?? false
    }
}

nonisolated struct NativeShardQuest: Identifiable, Sendable {
    let id: String
    let title: String
    let how: String
    let reward: Int
    let kind: String
    let done: Bool
    let claimed: Bool
    init(row: NativeJSON) throws {
        guard let key = row["key"].string, !key.isEmpty, let title = row["title"].string,
              let reward = row["reward"].int else { throw NativeClientError.invalidResponse }
        id = key; self.title = title; how = row["how"].string ?? ""
        self.reward = reward; kind = row["kind"].string ?? "daily"
        done = row["done"].bool ?? false; claimed = row["claimed"].bool ?? false
    }
}

nonisolated struct NativeShardLedgerEntry: Identifiable, Sendable {
    let id: String
    let amount: Int
    let kind: String
    let note: String
    let createdAt: Date
    init(row: NativeJSON) throws {
        guard let id = row["id"].string ?? row["id"].int.map(String.init),
              let amount = row["amount"].int, let at = row["created_at"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.amount = amount; createdAt = try NativeDate.parse(at)
        kind = row["kind"].string ?? ""; note = row["note"].string ?? ""
    }
    var label: String {
        switch kind {
        case "daily": "Heute aktiv"
        case "activity": "Gespräche"
        case "streak": "Streak-Bonus"
        case "invite": "Einladung"
        case "deco_buy": "Dekoration gekauft"
        case "deco_sale": "Dekoration verkauft"
        case "level_up": "Level erhöht"
        case "quest": "Quest"
        default: note.isEmpty ? "Shards" : note
        }
    }
}

nonisolated struct NativeChatStreak: Sendable {
    let current: Int
    let best: Int
    let todayMessages: Int
    let requiredMessages: Int
    let counted: Bool
    let hidden: Bool
    let freezesLeft: Int
    init(row: NativeJSON) throws {
        guard let current = row["cur"].int, let best = row["best"].int else { throw NativeClientError.invalidResponse }
        self.current = current; self.best = best
        todayMessages = row["today_msgs"].int ?? 0; requiredMessages = row["min_msgs"].int ?? 3
        counted = row["counted"].bool ?? false; hidden = row["hidden"].bool ?? false
        freezesLeft = row["freezes_left"].int ?? 0
    }
}

nonisolated enum NativeLeaderboardKind: String, CaseIterable, Identifiable, Sendable {
    case level, messagesWeek = "messages_week", messagesAll = "messages_all", voice = "voice_week", shards = "shards_week", gifts, invites
    var id: String { rawValue }
    var label: String {
        switch self {
        case .level: "Level"
        case .messagesWeek: "Nachrichten diese Woche"
        case .messagesAll: "Nachrichten insgesamt"
        case .voice: "Sprachzeit diese Woche"
        case .shards: "Shards diese Woche"
        case .gifts: "Geschenke"
        case .invites: "Einladungen"
        }
    }
}

nonisolated struct NativeLeaderboardEntry: Identifiable, Sendable {
    let id: String
    let position: Int
    let score: Int
    let profile: NativeProfileDetail?
}

nonisolated struct NativeLeaderboard: Sendable {
    let rows: [NativeLeaderboardEntry]
    let ownPosition: Int?
    let ownScore: Int?
    let hidden: Bool
}

nonisolated enum NativeDecorationKind: String, CaseIterable, Identifiable, Sendable {
    case avatar = "deco", profile, banner
    var id: String { rawValue }
    var label: String {
        switch self {
        case .avatar: "Avatar-Dekorationen"
        case .profile: "Profileffekte"
        case .banner: "Namensbanner"
        }
    }
    var field: String {
        switch self {
        case .avatar: "avatar_deco"
        case .profile: "profile_effect"
        case .banner: "name_banner"
        }
    }
    var prefix: String { self == .profile ? "p:" : "c:" }
}

nonisolated struct NativeCommunityDecoration: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let artistID: String?
    let kind: NativeDecorationKind
    let price: Int?
    let owned: Bool
    var imageURL: URL? { NativeConfiguration.publicAsset(bucket: "avatars", path: path) }
    init(row: NativeJSON, kind: NativeDecorationKind, price: Int?, owned: Bool) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string,
              let path = row["path"].string, NativeConfiguration.publicAsset(bucket: "avatars", path: path) != nil else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name; self.path = path; self.kind = kind; self.price = price; self.owned = owned
        artistID = row["artist_id"].string
    }
}

nonisolated struct NativeStandingWarning: Identifiable, Sendable {
    let id: String
    let reason: String
    let at: Date?
    let expires: Date?
}

nonisolated struct NativeAccountStanding: Sendable {
    let enabled: Bool
    let tier: String
    let warnings: [NativeStandingWarning]
    let suspensionReason: String?
    let suspendedUntil: Date?
    let improvesAt: Date?
    init(row: NativeJSON) throws {
        guard row.object != nil else { throw NativeClientError.invalidResponse }
        enabled = row["on"].bool ?? false; tier = row["tier"].string ?? "good"
        warnings = row["warnings"].array.enumerated().map { index, value in
            NativeStandingWarning(id: value["id"].string ?? "\(index)", reason: value["reason"].string ?? "",
                                  at: value["at"].string.flatMap { try? NativeDate.parse($0) }, expires: value["expires"].string.flatMap { try? NativeDate.parse($0) })
        }
        suspensionReason = row["suspended"]["reason"].string
        suspendedUntil = row["suspended"]["until"].string.flatMap { try? NativeDate.parse($0) }
        improvesAt = row["improves_at"].string.flatMap { try? NativeDate.parse($0) }
    }
    var label: String {
        switch tier {
        case "good": "Konto ohne Einschränkungen"
        case "limited": "Konto eingeschränkt"
        case "very_limited": "Konto stark eingeschränkt"
        case "suspended": "Konto vorübergehend gesperrt"
        default: "Kontostatus"
        }
    }
}

nonisolated enum NativeReportTarget: Sendable {
    case user(String), message(String), server(String)
}

nonisolated enum NativeReportReason: String, CaseIterable, Identifiable, Sendable {
    case harassment, hate, sexual, minorSafety = "minor_safety", violence, selfHarm = "self_harm", spam, illegal, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .harassment: "Belästigung oder Mobbing"
        case .hate: "Hassrede oder Beleidigungen"
        case .sexual: "Sexuelle Inhalte"
        case .minorSafety: "Sicherheit Minderjähriger"
        case .violence: "Drohungen oder Gewalt"
        case .selfHarm: "Selbstverletzung oder Suizid"
        case .spam: "Spam oder Betrug"
        case .illegal: "Rechtswidrige Inhalte"
        case .other: "Etwas anderes"
        }
    }
}

nonisolated struct NativeBugReport: Identifiable, Sendable {
    let id: String
    let title: String
    let body: String
    let severity: String
    let status: String
    let createdAt: Date?
    let images: [String]
    init(row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil, let title = row["title"].string,
              let body = row["body"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.title = title; self.body = body
        severity = row["severity"].string ?? "normal"; status = row["status"].string ?? "open"
        createdAt = row["created_at"].string.flatMap { try? NativeDate.parse($0) }
        switch row["images"] {
        case .null: images = []
        case let .array(values):
            images = try values.map { value in
                guard let path = value.string else { throw NativeClientError.invalidResponse }
                return path
            }
        default: throw NativeClientError.invalidResponse
        }
    }
}
