import Foundation

// Contracts: directory0mcrufu0avhsc.js, installation0sn16tkxmqvqh.js,
// developer/OAuth1y5-tms6m1pvx.js. See docs/developer-contracts.json.
extension NativeAPI {
    func developerBotDirectory(query: String, category: String = "", sort: String = "popular", session: NativeSession) async throws -> [NativeDirectoryBot] {
        guard category.isEmpty || NativeBotCategory(rawValue: category) != nil, ["popular", "new", "name"].contains(sort) else { throw NativeClientError.invalidResponse }
        let rows = try await rpc("bot_directory", arguments: ["q": .string(query.trimmingCharacters(in: .whitespacesAndNewlines)), "cat": .string(category), "sort": .string(sort)], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        var bots = try rows.array.map(NativeDirectoryBot.init)
        let profiles = try await socialProfiles(ids: bots.map(\.id), session: session)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for index in bots.indices { bots[index].profile = byID[bots[index].id] }
        return bots
    }

    func developerBotTargets(botID: String, session: NativeSession) async throws -> [NativeBotInstallTarget] {
        try Self.developerID(botID)
        let rows = try await rpc("bot_add_targets", arguments: ["bid": .string(botID)], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeBotInstallTarget.init)
    }

    func developerInstallBot(botID: String, serverID: String, session: NativeSession) async throws {
        try Self.developerID(serverID)
        let targets = try await developerBotTargets(botID: botID, session: session)
        guard let target = targets.first(where: { $0.id == serverID }) else { throw NativeClientError.api(status: 403, message: "Du brauchst auf diesem Server die Berechtigung Server verwalten.") }
        guard !target.added else { return }
        try Task.checkCancellation()
        _ = try await rpc("bot_add_to_server", arguments: ["bid": .string(botID), "sid": .string(serverID)], session: session)
    }

    func developerOwnedBots(flags: Set<String>, session: NativeSession) async throws -> [NativeOwnedBot] {
        var columns = "id,name,tag,description,category,public,posts,last_used_at,last_poll_at,last_event_at,created_at,submitted_at,verified_at,review_note"
        if flags.contains("bot_verified") { columns += ",support_invite" }
        if flags.contains("private_verify") { columns += ",unlisted" }
        if flags.contains("bot_share_add") { columns += ",shareable" }
        let rows = try await table("bots", query: [URLQueryItem(name: "select", value: columns), URLQueryItem(name: "owner_id", value: "eq.\(session.userID)"), URLQueryItem(name: "order", value: "created_at")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        let hooks = try await rpc("my_bot_hooks", session: session)
        guard case .array = hooks else { throw NativeClientError.invalidResponse }
        var bots = try rows.array.map(NativeOwnedBot.init)
        let byID = Dictionary(hooks.array.compactMap { row -> (String, String)? in
            guard let id = row["id"].string, let url = row["webhook_url"].string else { return nil }; return (id, url)
        }, uniquingKeysWith: { _, new in new })
        for index in bots.indices { bots[index].webhookURL = byID[bots[index].id] }
        return bots
    }

    func developerCreateBot(name: String, session: NativeSession) async throws -> (id: String, token: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_.]{2,32}$", options: .regularExpression) != nil else { throw NativeClientError.api(status: 400, message: "Wähle einen Namen mit 2 bis 32 Buchstaben, Zahlen, Punkten oder Unterstrichen.") }
        let row = try await webAPI(path: "api/bots", method: "POST", body: .object(["name": .string(name)]), session: session)
        guard let id = row["id"].string else { throw NativeClientError.invalidResponse }; try Self.developerID(id)
        return (id, try NativeDeveloperInput.secret(row, key: "token"))
    }

    func developerUpdateBot(bot: NativeOwnedBot, name: String, description: String, category: NativeBotCategory, supportInvite: String?, webhookURL: String?, session: NativeSession) async throws {
        try Self.developerID(bot.id)
        guard name.range(of: "^[A-Za-z0-9_.]{2,32}$", options: .regularExpression) != nil, description.utf16.count <= 300,
              webhookURL.map({ $0.isEmpty || NativeDeveloperInput.https($0) }) ?? true else { throw NativeClientError.invalidResponse }
        var body: [String: NativeJSON] = ["id": .string(bot.id)]
        if name != bot.name { body["name"] = .string(name) }
        if description != bot.description { body["description"] = .string(description) }
        if category != bot.category { body["category"] = .string(category.rawValue) }
        if (webhookURL ?? "") != (bot.webhookURL ?? "") { body["webhook_url"] = webhookURL.flatMap { $0.isEmpty ? nil : .string($0) } ?? .null }
        if let supportInvite, supportInvite.trimmingCharacters(in: .whitespacesAndNewlines) != (bot.supportInvite ?? "") { body["support_invite"] = .string(supportInvite.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard body.count > 1 else { return }
        _ = try await webAPI(path: "api/bots", method: "PATCH", body: .object(body), session: session)
    }

    func developerRotateBotToken(id: String, session: NativeSession) async throws -> String {
        try Self.developerID(id)
        let result = try await webAPI(path: "api/bots", method: "PATCH", body: .object(["id": .string(id), "rotate": .bool(true)]), session: session)
        return try NativeDeveloperInput.secret(result, key: "token")
    }
    func developerBotWebhookSecret(id: String, session: NativeSession) async throws -> String {
        try Self.developerID(id)
        let result = try await webAPI(path: "api/bots", method: "PATCH", body: .object(["id": .string(id)]), session: session)
        return try NativeDeveloperInput.secret(result, key: "webhook_secret")
    }
    func developerDeleteBot(id: String, session: NativeSession) async throws {
        try Self.developerID(id)
        _ = try await webAPI(path: "api/bots", method: "DELETE", body: .object(["id": .string(id)]), session: session)
    }
    func developerSetBotSharing(id: String, enabled: Bool, session: NativeSession) async throws {
        try Self.developerID(id)
        _ = try await rpc("bot_set_shareable", arguments: ["bid": .string(id), "on_off": .bool(enabled)], session: session)
    }
    func developerSetBotPublication(id: String, published: Bool, unlisted: Bool? = nil, session: NativeSession) async throws {
        try Self.developerID(id)
        var body: [String: NativeJSON] = ["id": .string(id)]
        if let unlisted { body["unlisted"] = .bool(unlisted) } else { body["public"] = .bool(published) }
        _ = try await webAPI(path: "api/bots", method: "PATCH", body: .object(body), session: session)
    }

    func developerBotCommands(id: String, session: NativeSession) async throws -> [NativeBotCommand] {
        try Self.developerID(id)
        let rows = try await table("bot_commands", query: [URLQueryItem(name: "select", value: "bot_id,name,description"), URLQueryItem(name: "bot_id", value: "eq.\(id)"), URLQueryItem(name: "order", value: "name")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeBotCommand.init)
    }

    func developerBotServers(id: String, session: NativeSession) async throws -> [NativeServerTagChoice] {
        try Self.developerID(id)
        var request = try request(path: "api/bots", query: [URLQueryItem(name: "servers", value: id)], loginOrigin: true)
        var components = URLComponents(string: "https://www.yapin.gg/api/bots")!
        components.queryItems = [URLQueryItem(name: "servers", value: id)]; request.url = components.url
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let result = try await response(NativeJSON.self, request: request)
        guard case .array = result["servers"] else { throw NativeClientError.invalidResponse }
        return try result["servers"].array.map { row in
            guard let id = row["id"].string, UUID(uuidString: id) != nil, let name = row["name"].string else { throw NativeClientError.invalidResponse }
            return NativeServerTagChoice(id: id, name: name, tag: "", icon: nil)
        }
    }
    func developerRemoveBotFromServer(botID: String, serverID: String, session: NativeSession) async throws {
        try Self.developerID(botID); try Self.developerID(serverID)
        _ = try await rpc("bot_remove_from_server", arguments: ["bid": .string(botID), "sid": .string(serverID)], session: session)
    }
    func developerUpdateBotProfile(id: String, displayName: String, bio: String, session: NativeSession) async throws {
        try Self.developerID(id)
        guard displayName.utf16.count <= 32, bio.utf16.count <= 300 else { throw NativeClientError.invalidResponse }
        _ = try await webAPI(path: "api/bots/profile", method: "PATCH", body: .object(["id": .string(id), "display_name": .string(displayName), "bio": .string(bio)]), session: session)
    }
    func developerRemoveBotProfileImage(id: String, kind: String, session: NativeSession) async throws {
        try Self.developerID(id); guard ["avatar", "banner"].contains(kind) else { throw NativeClientError.invalidResponse }
        _ = try await webAPI(path: "api/bots/profile", method: "DELETE", body: .object(["id": .string(id), "kind": .string(kind)]), session: session)
    }
    func developerUploadBotProfileImage(id: String, kind: String, data: Data, contentType: String, session: NativeSession) async throws -> String {
        try Self.developerID(id)
        guard ["avatar", "banner"].contains(kind), NativeMediaUploadPolicy.imageTypes.contains(contentType),
              !data.isEmpty, data.count <= 4 * 1_024 * 1_024 else { throw NativeClientError.api(status: 400, message: "Bot-Bilder dürfen maximal 4 MB groß sein.") }
        let boundary = "NativeBot-" + UUID().uuidString
        var body = Data()
        for (name, value) in [("id", id), ("kind", kind)] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8)); body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try request(path: "api/bots/profile", method: "POST", body: body, loginOrigin: true)
        request.url = URL(string: "https://www.yapin.gg/api/bots/profile")!
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let result = try await response(NativeJSON.self, request: request)
        guard let path = result["path"].string, NativeConfiguration.publicAsset(bucket: kind == "avatar" ? "avatars" : "banners", path: path) != nil else { throw NativeClientError.invalidResponse }
        return path
    }

    func developerBotActivities(id: String, session: NativeSession) async throws -> [NativeBotActivity] {
        try Self.developerID(id)
        let rows = try await rpc("bot_activities_mine", arguments: ["bid": .string(id)], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeBotActivity.init)
    }
    func developerSaveActivity(botID: String, activityID: String?, name: String, url: String, emoji: String, description: String, session: NativeSession) async throws {
        try Self.developerID(botID); if let activityID { try Self.developerID(activityID) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf16.count <= 40, url.utf16.count <= 500,
              NativeDeveloperInput.https(url), emoji.utf16.count <= 8, description.utf16.count <= 200 else { throw NativeClientError.invalidResponse }
        _ = try await rpc("bot_activity_save", arguments: ["bid": .string(botID), "p_id": activityID.map(NativeJSON.string) ?? .null, "p_name": .string(name), "p_url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines)), "p_emoji": emoji.isEmpty ? .null : .string(emoji), "p_description": description.isEmpty ? .null : .string(description)], session: session)
    }
    func developerRemoveActivity(id: String, session: NativeSession) async throws {
        try Self.developerID(id); _ = try await rpc("bot_activity_remove", arguments: ["p_id": .string(id)], session: session)
    }

    func developerOAuthApplications(session: NativeSession) async throws -> [NativeOAuthApplication] {
        let rows = try await rpc("oauth_my_apps", session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeOAuthApplication.init)
    }
    func developerCreateOAuthApplication(name: String, session: NativeSession) async throws -> (app: NativeOAuthApplication, secret: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(name.utf16.count) else { throw NativeClientError.invalidResponse }
        let result = try await webAPI(path: "api/oauth/apps", method: "POST", body: .object(["name": .string(name)]), session: session)
        return (try NativeOAuthApplication(result["app"]), try NativeDeveloperInput.secret(result, key: "secret"))
    }
    func developerUpdateOAuthApplication(id: String, name: String, description: String, redirectURIs: [String], iconPath: String? = nil, session: NativeSession) async throws -> NativeOAuthApplication {
        try Self.developerID(id)
        let redirects = redirectURIs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard (2...40).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count), description.utf16.count <= 400,
              redirects.count <= 10, redirects.allSatisfy(NativeDeveloperInput.redirectURI) else { throw NativeClientError.invalidResponse }
        var arguments: [String: NativeJSON] = ["p_id": .string(id), "p_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "p_description": .string(description), "p_redirect_uris": .array(redirects.map(NativeJSON.string))]
        if let iconPath { arguments["p_icon_path"] = .string(iconPath) }
        let app = try await NativeOAuthApplication(rpc("oauth_update_app", arguments: arguments, session: session))
        guard app.id == id else { throw NativeClientError.invalidResponse }; return app
    }
    func developerRotateOAuthSecret(id: String, session: NativeSession) async throws -> String {
        try Self.developerID(id)
        let result = try await webAPI(path: "api/oauth/apps", method: "PATCH", body: .object(["id": .string(id), "reset_secret": .bool(true)]), session: session)
        return try NativeDeveloperInput.secret(result, key: "secret")
    }
    func developerUpdateOAuthIcon(id: String, path: String, session: NativeSession) async throws -> NativeOAuthApplication {
        try Self.developerID(id)
        guard path.isEmpty || (path.hasPrefix(session.userID + "/") && !path.contains("..")) else { throw NativeClientError.invalidResponse }
        let app = try await NativeOAuthApplication(rpc("oauth_update_app", arguments: ["p_id": .string(id), "p_icon_path": .string(path)], session: session))
        guard app.id == id else { throw NativeClientError.invalidResponse }; return app
    }
    func developerRemoveOAuthApplication(id: String, session: NativeSession) async throws {
        try Self.developerID(id); _ = try await rpc("oauth_remove_app", arguments: ["p_id": .string(id)], session: session)
    }

    private static func developerID(_ id: String) throws { guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse } }
}
