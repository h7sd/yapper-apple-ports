import Foundation

nonisolated enum AuthState: Equatable {
    case signedOut, restoring, signingIn, requiresTwoFactor, signedIn
}

nonisolated struct YapperUser: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let username: String
    var displayName: String
    var avatarURL: URL?
    var presence: String
    var bio: String?
    var avatarDecorationURL: URL?
    var profileEffectURL: URL?
    var nameBannerURL: URL?
    var avatarCrop: NativeImageCrop
    var plusUntil: Date?

    init(id: String, username: String, displayName: String? = nil, avatarURL: URL? = nil, presence: String = "unknown", bio: String? = nil, avatarDecorationURL: URL? = nil, profileEffectURL: URL? = nil, nameBannerURL: URL? = nil, avatarCrop: NativeImageCrop = .centered, plusUntil: Date? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName.flatMap { $0.isEmpty ? nil : $0 } ?? username
        self.avatarURL = avatarURL
        self.presence = presence
        self.bio = bio
        self.avatarDecorationURL = avatarDecorationURL
        self.profileEffectURL = profileEffectURL
        self.nameBannerURL = nameBannerURL
        self.avatarCrop = avatarCrop
        self.plusUntil = plusUntil
    }
}

nonisolated struct Conversation: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var participants: [YapperUser]
    var avatarURL: URL?
    var lastMessage: String?
    var unreadCount: Int
    var isGroup: Bool
    var serverID: String?
    var lastMessageAt: Date?

    init(id: String, title: String, participants: [YapperUser], avatarURL: URL? = nil, lastMessage: String? = nil, unreadCount: Int = 0, isGroup: Bool = false, serverID: String? = nil, lastMessageAt: Date? = nil) {
        self.id = id
        self.title = title
        self.participants = participants
        self.avatarURL = avatarURL
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.isGroup = isGroup
        self.serverID = serverID
        self.lastMessageAt = lastMessageAt
    }
}

nonisolated struct MessageAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL?
    let filename: String
    let contentType: String?
}

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let channelID: String
    var author: YapperUser
    var content: String
    let createdAt: Date
    var attachments: [MessageAttachment]
    var isEdited: Bool
    var grouping = NativeMessageGroupingMetadata()
    var hereRecipientIDs: [String] = []
    var mentions: NativeMessageMentions { NativeMessageMentions(content: content, hereRecipientIDs: hereRecipientIDs) }
}

nonisolated struct NativeMessageGroupingMetadata: Hashable, Sendable {
    var isSystem = false
    var replyToID: String? = nil
    var webhookID: String? = nil
    var webhookName: String? = nil
    var webhookAvatarURL: String? = nil
    var webhookAvatarPath: String? = nil
}

nonisolated enum NativeMessageGrouping {
    /// Exact shipped seven-minute rule, with the source's system/reply/webhook exclusions.
    static func groups(_ current: ChatMessage, after previous: ChatMessage?, firstUnreadID: String? = nil, calendar: Calendar = .current) -> Bool {
        guard let previous, current.author.id == previous.author.id,
              !current.grouping.isSystem, !previous.grouping.isSystem,
              current.grouping.replyToID == nil, current.id != firstUnreadID,
              current.grouping.webhookID == previous.grouping.webhookID,
              current.grouping.webhookName == previous.grouping.webhookName,
              current.grouping.webhookAvatarURL == previous.grouping.webhookAvatarURL,
              current.grouping.webhookAvatarPath == previous.grouping.webhookAvatarPath,
              calendar.isDate(current.createdAt, inSameDayAs: previous.createdAt) else { return false }
        return (0..<420).contains(current.createdAt.timeIntervalSince(previous.createdAt))
    }
}

nonisolated struct NativeSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String
}

nonisolated struct NativeIncomingCall: Identifiable, Equatable, Sendable {
    let channelID: String
    let fromUserID: String
    let title: String
    let startedAt: Date
    var id: String { channelID }
}

nonisolated enum NativeClientError: Error, LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case malformedResponse(String)
    case api(status: Int, message: String)
    case missingSession
    case sessionExpired
    case keychain(Int32)
    case emptyMessage
    case messageTooLong
    case missingProfile
    case unsupportedChallenge

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Diese Serveradresse ist nicht zugelassen."
        case .invalidResponse: "Der Server hat keine gültige Antwort gesendet."
        case .malformedResponse: "Die Serverantwort konnte nicht gelesen werden. Bitte erneut versuchen."
        case let .api(_, message): message
        case .missingSession: "Bitte melde dich an."
        case .sessionExpired: "Deine Sitzung ist abgelaufen. Bitte melde dich erneut an."
        case .keychain: "Die Anmeldung konnte nicht sicher im iOS-Schlüsselbund gespeichert werden."
        case .emptyMessage: "Gib eine Nachricht ein."
        case .messageTooLong: "Diese Nachricht ist zu lang."
        case .missingProfile: "Dein Yapper-Profil wurde vom Server nicht zurückgegeben."
        case .unsupportedChallenge: "Diese Anmeldung benötigt eine zusätzliche Bestätigung, die der native Client noch nicht unterstützt."
        }
    }
}

nonisolated enum NativeDate {
    static func parse(_ string: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: string) { return date }
        throw NativeClientError.malformedResponse("Invalid timestamp")
    }
}
