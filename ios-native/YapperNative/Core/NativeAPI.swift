import Foundation

nonisolated enum NativeConfiguration {
    static let apiHost = "dnfkuqzddwvtdojzgmdm.supabase.co"
    static let apiURL = URL(string: "https://dnfkuqzddwvtdojzgmdm.supabase.co")!
    // Public anonymous project key, shipped by the official web client. Never a service-role key.
    static let anonymousKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRuZmt1cXpkZHd2dGRvanpnbWRtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE2Mzk0ODgsImV4cCI6MjEwNzIxNTQ4OH0.kMZcUf8DgMrYFNGtMPW9SGja2m1cRdMq5WJv5XBNgCU"

    static func permits(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return url.host == apiHost || (["yapin.gg", "www.yapin.gg"].contains(url.host ?? "") && url.path.hasPrefix("/api/"))
    }

    static func publicAsset(bucket: String, path: String?) -> URL? {
        guard let path, !path.isEmpty, !path.contains(".."), !path.contains("://") else { return nil }
        if path.hasPrefix("/") { return URL(string: "https://yapin.gg")?.appendingPathComponent(path) }
        return URL(string: "https://files.yapper.website")?.appendingPathComponent(bucket).appendingPathComponent(path)
    }

    static func communityCosmeticAsset(_ value: String?, prefix: String) -> URL? {
        guard let value, ["c:", "p:"].contains(prefix), value.hasPrefix(prefix) else { return nil }
        return publicAsset(bucket: "avatars", path: String(value.dropFirst(2)))
    }
}

/// Returning nil rejects *all* redirects, so a server cannot forward credentials to another origin.
nonisolated final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class NativeAPI {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    // Official profile consumer (3-pd02a6i86ee.js, module 99833) selects public columns.
    // A wildcard also requests restricted columns and is denied by the server.
    static let publicProfileColumns = "id,username,created_at,bio,avatar_path,banner_path,banner_x,banner_y,avatar_x,avatar_y,avatar_zoom,avatar_rot,banner_zoom,links,verified_as,verified_hidden,badges,display_name,pronouns,accent_color,accent_color2,plus_until,plus_badge_hidden,dms_from,server_tag,tag,tag_icon,tag_icon_off,shown_badge,verify_required,custom_status,custom_status_until,avatar_deco,profile_effect,name_banner,discriminator,avatar_revert_at,name_style,account_level,plus_since,gifts_given,chat_streak"
    private let transport: Transport
    private let session: URLSession?

    init(transport: Transport? = nil) {
        if let transport {
            self.transport = transport
            session = nil
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 45
            let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
            self.session = session
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NativeClientError.invalidResponse }
                return (data, http)
            }
        }
    }

    func request(path: String, query: [URLQueryItem] = [], method: String = "GET", token: String? = nil, body: Data? = nil, single: Bool = false, loginOrigin: Bool = false) throws -> URLRequest {
        let base = loginOrigin ? URL(string: "https://yapin.gg")! : NativeConfiguration.apiURL
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { throw NativeClientError.invalidEndpoint }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, NativeConfiguration.permits(url) else { throw NativeClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(single ? "application/vnd.pgrst.object+json" : "application/json", forHTTPHeaderField: "Accept")
        if !loginOrigin {
            request.setValue(NativeConfiguration.anonymousKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token ?? NativeConfiguration.anonymousKey)", forHTTPHeaderField: "Authorization")
        }
        if single { request.setValue("return=representation", forHTTPHeaderField: "Prefer") }
        return request
    }

    func response<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let data = try await dataResponse(request: request)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw NativeClientError.malformedResponse(String(describing: type)) }
    }

    func dataResponse(request: URLRequest, maximumBytes: Int = 8 * 1024 * 1024) async throws -> Data {
        guard let url = request.url, NativeConfiguration.permits(url) else { throw NativeClientError.invalidEndpoint }
        try Task.checkCancellation()
        try NativeAuthenticationContext.check?()
        let received: (Data, HTTPURLResponse)
        do { received = try await transport(request) }
        catch {
            try Task.checkCancellation()
            let failure = error as NSError
            if error is CancellationError || (failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) {
                throw CancellationError()
            }
            throw error
        }
        let (data, response) = received
        try Task.checkCancellation()
        try NativeAuthenticationContext.check?()
        guard response.url == request.url else { throw NativeClientError.invalidEndpoint }
        guard (200...299).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(APIErrorBody.self, from: data)
            let message = error?.safeMessage ?? "Serverfehler (\(response.statusCode)). Bitte erneut versuchen."
            throw NativeClientError.api(status: response.statusCode, message: message)
        }
        guard maximumBytes > 0, data.count <= maximumBytes else { throw NativeClientError.invalidResponse }
        return data
    }

    func signIn(identifier: String, password: String) async throws -> NativeSession {
        let isEmail = identifier.contains("@")
        let body = if isEmail { ["email": identifier.lowercased(), "password": password] }
                   else { ["username": identifier, "password": password] }
        let request = try request(path: isEmail ? "auth/v1/token" : "api/login",
                                  query: isEmail ? [URLQueryItem(name: "grant_type", value: "password")] : [],
                                  method: "POST", body: JSONEncoder().encode(body), loginOrigin: !isEmail)
        let tokens = try await response(TokenResponse.self, request: request)
        if tokens.user != nil { return try tokens.session() }
        let user = try await authUser(token: tokens.access_token)
        return try tokens.session(fallbackUserID: user.id)
    }

    func refresh(_ session: NativeSession) async throws -> NativeSession {
        let request = try request(path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], method: "POST", body: JSONEncoder().encode(["refresh_token": session.refreshToken]))
        return try await response(TokenResponse.self, request: request).session(fallbackUserID: session.userID)
    }

    func authUser(token: String) async throws -> AuthUserResponse {
        try await response(AuthUserResponse.self, request: request(path: "auth/v1/user", token: token))
    }

    func validateBrowserLogin(_ tokens: BrowserLoginTokens) async throws -> BrowserLoginValidation {
        let claims = try BrowserTokenClaims.decode(tokens.accessToken)
        guard claims.exp > Date().timeIntervalSince1970 else { throw NativeClientError.sessionExpired }
        // Decoding is only scheduling/identity metadata. This HTTPS request validates the actual token.
        let authenticatedUser = try await authUser(token: tokens.accessToken)
        guard authenticatedUser.id == claims.sub else { throw NativeClientError.invalidResponse }
        let needsTwoFactor = authenticatedUser.factors?.contains(where: { $0.status == "verified" }) == true
            && claims.aal != "aal2"
        let session = NativeSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                                    expiresAt: Date(timeIntervalSince1970: claims.exp), userID: authenticatedUser.id)
        return BrowserLoginValidation(session: session, requiresTwoFactor: needsTwoFactor)
    }

    func verifyTOTP(factorID: String, code: String, session: NativeSession) async throws -> NativeSession {
        guard UUID(uuidString: factorID) != nil, code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { throw NativeClientError.unsupportedChallenge }
        let challenge = try await response(MFAChallenge.self, request: request(path: "auth/v1/factors/\(factorID)/challenge", method: "POST", token: session.accessToken, body: JSONEncoder().encode(["factorId": factorID])))
        let body = try JSONEncoder().encode(["challenge_id": challenge.id, "code": code])
        return try await response(TokenResponse.self, request: request(path: "auth/v1/factors/\(factorID)/verify", method: "POST", token: session.accessToken, body: body)).session(fallbackUserID: session.userID)
    }

    func bootstrap(session: NativeSession) async throws -> BootstrapResponse {
        try await response(BootstrapResponse.self, request: request(path: "rest/v1/rpc/bootstrap", method: "POST", token: session.accessToken, body: Data("{}".utf8)))
    }

    func profile(id: String, session: NativeSession) async throws -> ProfileRow {
        let query = [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "select", value: Self.publicProfileColumns)]
        let profile = try await response(ProfileRow.self, request: request(path: "rest/v1/profiles", query: query, token: session.accessToken, single: true))
        guard profile.id == id, !profile.username.isEmpty else { throw NativeClientError.invalidResponse }
        return profile
    }

    func publicProfiles(ids: [String], session: NativeSession) async throws -> [NativeJSON] {
        let unique = Array(Set(ids)).sorted()
        guard unique.allSatisfy({ UUID(uuidString: $0) != nil }), unique.count <= 5_000 else { throw NativeClientError.invalidResponse }
        var profiles: [NativeJSON] = []
        for start in stride(from: 0, to: unique.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(unique[start..<min(start + 100, unique.count)])
            let query = [URLQueryItem(name: "select", value: Self.publicProfileColumns), URLQueryItem(name: "id", value: "in.(\(batch.joined(separator: ",")))")]
            let rows = try await response([NativeJSON].self, request: request(path: "rest/v1/profiles", query: query, token: session.accessToken))
            var seen = Set<String>()
            guard rows.allSatisfy({ row in
                guard let id = row["id"].string, let username = row["username"].string else { return false }
                return batch.contains(id) && !username.isEmpty && seen.insert(id).inserted
            }) else { throw NativeClientError.invalidResponse }
            profiles += rows
        }
        return profiles
    }

    func history(channelID: String, before: String? = nil, session: NativeSession) async throws -> HistoryResponse {
        let body = try JSONEncoder().encode(HistoryRequest(cid: channelID, before: before, lim: 50))
        return try await response(HistoryResponse.self, request: request(path: "rest/v1/rpc/channel_messages", method: "POST", token: session.accessToken, body: body))
    }

    func send(id: String, text: String, channelID: String, session: NativeSession, messagePolicy: NativeMessagePolicy = .standard) async throws -> MessageRow {
        try messagePolicy.validate(text, for: session.userID)
        let row = MessageInsert(id: id, channel_id: channelID, author_id: session.userID, content: text)
        return try await insertMessage(id: id, channelID: channelID, body: JSONEncoder().encode(row), session: session).row
    }

    // The official client inserts/selects a single object and reuses its UUID on a duplicate.
    // UUID text casing is not identity: Swift generates uppercase, while Postgres returns lowercase.
    func insertMessage(id: String, channelID: String, body: Data, session: NativeSession) async throws -> (row: MessageRow, duplicate: Bool) {
        guard UUID(uuidString: id) != nil, UUID(uuidString: channelID) != nil,
              UUID(uuidString: session.userID) != nil else { throw NativeClientError.invalidResponse }
        let data: Data
        do {
            data = try await dataResponse(request: request(path: "rest/v1/messages", query: [URLQueryItem(name: "select", value: "*")], method: "POST", token: session.accessToken, body: body, single: true))
        } catch let NativeClientError.api(status, _) where status == 409 {
            return (try await requireSentMessage(id: id, channelID: channelID, session: session), true)
        }
        if let rows = Self.sentMessageRows(data), rows.count == 1,
           let row = rows.first, row.confirmsSend(id: id, channelID: channelID, authorID: session.userID),
           (try? NativeDate.parse(row.created_at)) != nil { return (row, false) }
        // An empty or unreadable successful acknowledgement may follow a committed insert.
        // Confirm that exact row without issuing a second insert or inventing a successful message.
        return (try await requireSentMessage(id: id, channelID: channelID, session: session), false)
    }

    func sentMessage(id: String, channelID: String, session: NativeSession) async throws -> MessageRow? {
        guard UUID(uuidString: id) != nil, UUID(uuidString: channelID) != nil,
              UUID(uuidString: session.userID) != nil else { throw NativeClientError.invalidResponse }
        let query = [URLQueryItem(name: "id", value: "eq.\(id)"), URLQueryItem(name: "channel_id", value: "eq.\(channelID)"), URLQueryItem(name: "author_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "*")]
        let data = try await dataResponse(request: request(path: "rest/v1/messages", query: query, token: session.accessToken))
        guard let rows = Self.sentMessageRows(data), rows.count <= 1 else { throw NativeClientError.invalidResponse }
        guard let row = rows.first else { return nil }
        guard row.confirmsSend(id: id, channelID: channelID, authorID: session.userID),
              (try? NativeDate.parse(row.created_at)) != nil else { throw NativeClientError.invalidResponse }
        return row
    }

    private func requireSentMessage(id: String, channelID: String, session: NativeSession) async throws -> MessageRow {
        guard let row = try await sentMessage(id: id, channelID: channelID, session: session) else { throw NativeClientError.invalidResponse }
        return row
    }

    private static func sentMessageRows(_ data: Data) -> [MessageRow]? {
        let decoder = JSONDecoder()
        if let row = try? decoder.decode(MessageRow.self, from: data) { return [row] }
        return try? decoder.decode([MessageRow].self, from: data)
    }
}

private nonisolated struct APIErrorBody: Decodable {
    let message: String?
    let msg: String?
    let error_description: String?
    let error: String?
    var safeMessage: String? {
        guard let message = message ?? msg ?? error_description ?? error, !message.isEmpty else { return nil }
        if message.localizedCaseInsensitiveContains("captcha") || message.localizedCaseInsensitiveContains("turnstile") {
            return "Yapper verlangt eine Browser-Bestätigung (CAPTCHA). Melde dich über das Anmeldefenster in der App an."
        }
        // Response messages are shown as text only; never log the response or credentials.
        return String(message.prefix(300))
    }
}

nonisolated struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
    let expires_in: TimeInterval?
    let expires_at: TimeInterval?
    let user: AuthUserResponse?
    func session(fallbackUserID: String? = nil) throws -> NativeSession {
        guard !access_token.isEmpty, !refresh_token.isEmpty, let id = user?.id ?? fallbackUserID, !id.isEmpty else { throw NativeClientError.invalidResponse }
        let expiry: Date
        if let expires_at { expiry = Date(timeIntervalSince1970: expires_at) }
        else if let expires_in { expiry = Date().addingTimeInterval(expires_in) }
        else if let jwtExpiry = Self.jwtExpiry(access_token) { expiry = Date(timeIntervalSince1970: jwtExpiry) }
        else { throw NativeClientError.invalidResponse }
        guard expiry.timeIntervalSince1970.isFinite, expiry > Date() else { throw NativeClientError.sessionExpired }
        return NativeSession(accessToken: access_token, refreshToken: refresh_token, expiresAt: expiry, userID: id)
    }

    private static func jwtExpiry(_ token: String) -> TimeInterval? {
        // Scheduling metadata only. The HTTPS auth service validates credentials and token identity.
        let parts = token.split(separator: ".")
        guard parts.count == 3, parts[1].count < 16_384 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        nonisolated struct Claims: Decodable { let exp: TimeInterval }
        guard let data = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(Claims.self, from: data) else { return nil }
        return claims.exp
    }
}

nonisolated struct AuthUserResponse: Decodable {
    let id: String
    let factors: [MFAFactor]?
}
nonisolated struct MFAFactor: Decodable {
    let id: String
    let factor_type: String
    let status: String
}
private nonisolated struct MFAChallenge: Decodable { let id: String }
private nonisolated struct HistoryRequest: Encodable {
    let cid: String
    let before: String?
    let lim: Int
    enum CodingKeys: String, CodingKey { case cid, before, lim }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cid, forKey: .cid)
        if let before { try c.encode(before, forKey: .before) }
        else { try c.encodeNil(forKey: .before) }
        try c.encode(lim, forKey: .lim)
    }
}
private nonisolated struct MessageInsert: Encodable { let id: String; let channel_id: String; let author_id: String; let content: String }

nonisolated struct ProfileRow: Decodable, Sendable {
    let id: String
    let username: String
    let display_name: String?
    let avatar_path: String?
    let bio: String?
    let avatar_deco: String?
    let profile_effect: String?
    let name_banner: String?
    let avatar_x: Double?
    let avatar_y: Double?
    let avatar_zoom: Double?
    let avatar_rot: Double?
    let plus_until: String?
    func user() -> YapperUser {
        YapperUser(id: id, username: username, displayName: display_name,
                   avatarURL: NativeConfiguration.publicAsset(bucket: "avatars", path: avatar_path), bio: bio,
                   avatarDecorationURL: NativeConfiguration.communityCosmeticAsset(avatar_deco, prefix: "c:"),
                   profileEffectURL: NativeConfiguration.communityCosmeticAsset(profile_effect, prefix: "p:"),
                   nameBannerURL: NativeConfiguration.communityCosmeticAsset(name_banner, prefix: "c:"),
                   avatarCrop: NativeImageCrop(x: avatar_x ?? 50, y: avatar_y ?? 50, zoom: avatar_zoom ?? 1, rotation: avatar_rot ?? 0),
                   plusUntil: plus_until.flatMap { try? NativeDate.parse($0) })
    }
}

nonisolated struct ChannelRow: Decodable, Sendable {
    let id: String
    let kind: String
    let server_id: String?
    let name: String?
    let icon_path: String?
    let last_message_at: String?
}

nonisolated struct UnreadRow: Decodable, Sendable {
    let channel_id: String
    let unread: Int
}

nonisolated struct BootstrapResponse: Decodable, Sendable {
    let dm_channels: [ChannelRow]
    let dm_members: [[String]]
    let profiles: [ProfileRow]
    let unread: [UnreadRow]?
    let is_admin: Bool?
    let mod: NativeJSON?
    let flags: NativeJSON?
    let calls: [BootstrapCallRow]?
    let servers: [NativeJSON]?

    var capabilities: NativeCapabilities {
        NativeCapabilities(isAdministrator: is_admin == true, isModerator: mod?.object != nil && mod?["suspended_at"] == .null, flags: flags ?? .object([:]), joinedServerIDs: Set((servers ?? []).compactMap { row in
            guard let id = row["id"].string, UUID(uuidString: id) != nil else { return nil }
            return id
        }))
    }

    func activeCallChannels(now: Date) -> Set<String> {
        Set((calls ?? []).compactMap { row in
            guard let started = try? NativeDate.parse(row.started_at), (0..<21_600).contains(now.timeIntervalSince(started)) else { return nil }
            return row.channel_id
        })
    }

    func conversations(currentUserID: String) throws -> [Conversation] {
        guard dm_channels.allSatisfy({ !$0.id.isEmpty && ($0.kind == "dm" || $0.kind == "group") && $0.server_id == nil }),
              profiles.allSatisfy({ !$0.id.isEmpty && !$0.username.isEmpty }) else { throw NativeClientError.malformedResponse("DM list") }
        var profilesByID: [String: YapperUser] = [:]
        for profile in profiles { profilesByID[profile.id] = profile.user() }
        var members: [String: [String]] = [:]
        for tuple in dm_members {
            guard tuple.count == 2 else { throw NativeClientError.malformedResponse("DM member tuple") }
            members[tuple[0], default: []].append(tuple[1])
        }
        let unreadByID = Dictionary((unread ?? []).map { ($0.channel_id, $0.unread) }, uniquingKeysWith: max)
        var seen = Set<String>()
        return dm_channels.filter { seen.insert($0.id).inserted }.sorted { ($0.last_message_at ?? "") > ($1.last_message_at ?? "") }.map { row in
            let participants = (members[row.id] ?? []).filter { $0 != currentUserID }.compactMap { profilesByID[$0] }
            let title = row.name.flatMap { $0.isEmpty ? nil : $0 } ?? participants.map(\.displayName).joined(separator: ", ")
            return Conversation(id: row.id, title: title.isEmpty ? "Direktnachricht" : title, participants: participants,
                                avatarURL: NativeConfiguration.publicAsset(bucket: "icons", path: row.icon_path) ?? participants.first?.avatarURL,
                                unreadCount: unreadByID[row.id] ?? 0, isGroup: row.kind == "group", lastMessageAt: row.last_message_at.flatMap { try? NativeDate.parse($0) })
        }
    }
}

nonisolated struct BootstrapCallRow: Decodable, Sendable {
    let channel_id: String
    let started_by: String
    let started_at: String
}

nonisolated struct HistoryResponse: Decodable, Sendable {
    let messages: [MessageRow]
    let profiles: [ProfileRow]
}

nonisolated struct MessageContextResponse: Decodable, Sendable {
    let found: Bool
    let at_end: Bool?
    let messages: [MessageRow]?
    let profiles: [ProfileRow]?
}

nonisolated struct MessageRow: Decodable, Sendable {
    let id: String
    let channel_id: String
    let author_id: String?
    let content: String?
    let created_at: String
    let edited_at: String?
    let attachment_path: String?
    let attachment_name: String?
    let system: NativeJSON?
    let reply_to_id: String?
    let webhook: NativeJSON?

    func confirmsSend(id: String, channelID: String, authorID: String) -> Bool {
        guard let expectedID = UUID(uuidString: id), let expectedChannel = UUID(uuidString: channelID),
              let expectedAuthor = UUID(uuidString: authorID), let author_id else { return false }
        return UUID(uuidString: self.id) == expectedID && UUID(uuidString: channel_id) == expectedChannel
            && UUID(uuidString: author_id) == expectedAuthor
    }

    func message(profiles: [String: YapperUser]) throws -> ChatMessage {
        guard !id.isEmpty, !channel_id.isEmpty else { throw NativeClientError.malformedResponse("Message identity") }
        func canonical(_ value: String) -> String { UUID(uuidString: value)?.uuidString.lowercased() ?? value }
        let messageID = canonical(id)
        let channelID = canonical(channel_id)
        let authorID = author_id.map(canonical)
        let author = authorID.flatMap { profiles[$0] } ?? author_id.flatMap { profiles[$0] }
            ?? YapperUser(id: authorID ?? "system", username: author_id == nil ? "System" : "Unbekannt")
        let attachments = attachment_path.map { path in
            [MessageAttachment(id: messageID + ":attachment", url: NativeConfiguration.publicAsset(bucket: "attachments", path: path), filename: attachment_name ?? "Anhang", contentType: nil)]
        } ?? []
        return ChatMessage(id: messageID, channelID: channelID, author: author, content: content ?? "", createdAt: try NativeDate.parse(created_at), attachments: attachments, isEdited: edited_at != nil, grouping: .from(system: system ?? .null, replyToID: reply_to_id.map(canonical), webhook: webhook ?? .null))
    }
}

nonisolated extension NativeMessageGroupingMetadata {
    static func from(system: NativeJSON, replyToID: String?, webhook: NativeJSON) -> Self {
        Self(isSystem: system.bool ?? (system != .null), replyToID: replyToID,
             webhookID: webhook["id"].string, webhookName: webhook["name"].string,
             webhookAvatarURL: webhook["avatar_url"].string, webhookAvatarPath: webhook["avatar_path"].string)
    }
}
