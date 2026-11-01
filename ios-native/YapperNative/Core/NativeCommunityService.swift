import Foundation

extension NativeAPI {
    func communityFlags(session: NativeSession) async throws -> Set<String> {
        let flags = try await rpc("my_flags", session: session)
        guard case .array = flags else { throw NativeClientError.invalidResponse }
        let testServers = Set(flags.array.filter { $0["mode"].string == "test" }.flatMap { $0["servers"].array.compactMap(\.string) }.filter { UUID(uuidString: $0) != nil })
        var joined = Set<String>()
        if !testServers.isEmpty {
            let rows = try await table("server_members", query: [URLQueryItem(name: "select", value: "server_id"), URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "server_id", value: "in.(\(testServers.sorted().joined(separator: ",")))")], session: session)
            guard case .array = rows else { throw NativeClientError.invalidResponse }
            joined = Set(rows.array.compactMap { $0["server_id"].string })
        }
        return Set(flags.array.compactMap { row -> String? in
            guard let key = row["key"].string else { return nil }
            if row["mode"].string == "everyone" { return key }
            if row["mode"].string == "test", row["users"].array.compactMap(\.string).contains(session.userID) || !joined.isDisjoint(with: Set(row["servers"].array.compactMap(\.string))) { return key }
            return nil
        })
    }

    func communityShards(session: NativeSession) async throws -> NativeShardBalance {
        try await NativeShardBalance(row: rpc("my_shards", session: session))
    }

    func communityQuests(session: NativeSession) async throws -> [NativeShardQuest] {
        let rows = try await rpc("shard_quests", session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeShardQuest.init(row:))
    }

    func claimCommunityQuest(key: String, session: NativeSession) async throws -> NativeShardBalance {
        guard !key.isEmpty, key.utf8.count <= 120 else { throw NativeClientError.invalidResponse }
        return try await NativeShardBalance(row: rpc("claim_shard_quest", arguments: ["p_key": .string(key)], session: session))
    }

    func communityLevelUp(session: NativeSession) async throws -> NativeShardBalance {
        try await NativeShardBalance(row: rpc("level_up", session: session))
    }

    func communityLedger(before: String? = nil, session: NativeSession) async throws -> [NativeShardLedgerEntry] {
        var query = [URLQueryItem(name: "select", value: "id,amount,kind,note,created_at"), URLQueryItem(name: "order", value: "id.desc"), URLQueryItem(name: "limit", value: "50")]
        if let before {
            guard !before.isEmpty, before.utf8.count <= 80,
                  before.utf8.allSatisfy({ (48...57).contains($0) }) || UUID(uuidString: before) != nil else { throw NativeClientError.invalidResponse }
            query.append(URLQueryItem(name: "id", value: "lt.\(before)"))
        }
        let rows = try await table("shard_ledger", query: query, session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeShardLedgerEntry.init(row:))
    }

    func communityStreak(session: NativeSession) async throws -> NativeChatStreak? {
        let row = try await rpc("my_streak", session: session)
        return row == .null ? nil : try NativeChatStreak(row: row)
    }

    func setCommunityStreakHidden(_ hidden: Bool, session: NativeSession) async throws -> NativeChatStreak {
        try await NativeChatStreak(row: rpc("set_streak_hidden", arguments: ["p_hidden": .bool(hidden)], session: session))
    }

    func communityLeaderboard(_ kind: NativeLeaderboardKind, session: NativeSession) async throws -> NativeLeaderboard {
        let result = try await rpc(kind == .level ? "level_board_page" : "leaderboard_page", arguments: kind == .level ? [:] : ["p_board": .string(kind.rawValue)], session: session)
        guard result.object != nil, case .array = result["top"] else { throw NativeClientError.invalidResponse }
        let profiles = try await socialProfiles(ids: result["top"].array.compactMap { $0["id"].string }, session: session)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let rows = try result["top"].array.map { row -> NativeLeaderboardEntry in
            guard let id = row["id"].string, UUID(uuidString: id) != nil,
                  let position = row["pos"].int, let score = row[kind == .level ? "level" : "score"].int else { throw NativeClientError.invalidResponse }
            return NativeLeaderboardEntry(id: id, position: position, score: score, profile: byID[id])
        }
        return NativeLeaderboard(rows: rows, ownPosition: result["me"]["pos"].int, ownScore: result["me"][kind == .level ? "level" : "score"].int, hidden: result["hidden"].bool ?? false)
    }

    func setCommunityLeaderboardHidden(_ hidden: Bool, session: NativeSession) async throws {
        try await confirmCommunityProfileUpdate(field: "leaderboard_hidden", value: .bool(hidden), session: session)
    }

    func communityDecorations(kind: NativeDecorationKind, offset: Int = 0, session: NativeSession) async throws -> [NativeCommunityDecoration] {
        guard offset >= 0, offset <= 10_000 else { throw NativeClientError.invalidResponse }
        var arguments: [String: NativeJSON] = ["p_offset": .number(Double(offset)), "p_limit": .number(200)]
        if kind != .avatar { arguments["p_kind"] = .string(kind.rawValue) }
        let result: NativeJSON
        do { result = try await rpc("community_decos_popular", arguments: arguments, session: session) }
        catch let NativeClientError.api(status, message) where (status == 400 || status == 404) && message.contains("community_decos_popular") {
            result = try await table("community_decos", query: [URLQueryItem(name: "select", value: "id,name,artist_id,path,status,review_note,created_at,event,kind"), URLQueryItem(name: "status", value: "eq.approved"), URLQueryItem(name: "kind", value: kind == .avatar ? "not.in.(profile,banner)" : "eq.\(kind.rawValue)"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "offset", value: "\(offset)"), URLQueryItem(name: "limit", value: "200")], session: session)
        }
        guard case .array = result else { throw NativeClientError.invalidResponse }
        let ids = try result.array.map { row -> String in
            guard let id = row["id"].string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }; return id
        }
        guard !ids.isEmpty else { return [] }
        let filter = "in.(\(ids.joined(separator: ",")))"
        let prices = try await table("community_decos", query: [URLQueryItem(name: "select", value: "id,price"), URLQueryItem(name: "id", value: filter), URLQueryItem(name: "status", value: "eq.approved")], session: session)
        let owned = try await table("deco_owned", query: [URLQueryItem(name: "select", value: "deco_id"), URLQueryItem(name: "deco_id", value: filter)], session: session)
        guard case .array = prices, case .array = owned else { throw NativeClientError.invalidResponse }
        let byID = Dictionary(prices.array.compactMap { row -> (String, Int)? in
            guard let id = row["id"].string, let price = row["price"].int else { return nil }; return (id, price)
        }, uniquingKeysWith: { _, new in new })
        let ownedIDs = Set(owned.array.compactMap { $0["deco_id"].string })
        return try result.array.map { row in try NativeCommunityDecoration(row: row, kind: kind, price: byID[row["id"].string ?? ""], owned: ownedIDs.contains(row["id"].string ?? "")) }
    }

    func buyCommunityDecoration(_ decoration: NativeCommunityDecoration, session: NativeSession) async throws -> NativeShardBalance {
        guard let price = decoration.price, price >= 0 else { throw NativeClientError.invalidResponse }
        return try await NativeShardBalance(row: rpc("buy_community_deco", arguments: ["p_id": .string(decoration.id), "p_price": .number(Double(price))], session: session))
    }

    func equipCommunityDecoration(_ decoration: NativeCommunityDecoration?, kind: NativeDecorationKind, session: NativeSession) async throws {
        if let decoration, decoration.kind != kind { throw NativeClientError.invalidResponse }
        let value = decoration.map { NativeJSON.string(kind.prefix + $0.path) } ?? .null
        try await confirmCommunityProfileUpdate(field: kind.field, value: value, session: session)
    }

    func communityStanding(session: NativeSession) async throws -> NativeAccountStanding {
        try await NativeAccountStanding(row: rpc("my_standing", session: session))
    }

    func reportCommunityTarget(_ target: NativeReportTarget, reason: NativeReportReason, details: String, session: NativeSession) async throws {
        guard details.utf16.count <= 4_000 else { throw NativeClientError.invalidResponse }
        let name: String; let key: String; let id: String
        switch target {
        case let .user(value): name = "report_user"; key = "uid"; id = value
        case let .message(value): name = "report_message"; key = "mid"; id = value
        case let .server(value): name = "report_server"; key = "sid"; id = value
        }
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        _ = try await rpc(name, arguments: [key: .string(id), "why": .string(reason.rawValue), "more": .string(details.trimmingCharacters(in: .whitespacesAndNewlines))], session: session)
    }

    func communityBugReports(session: NativeSession) async throws -> [NativeBugReport] {
        let rows = try await table("bug_reports", query: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "100")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativeBugReport.init(row:))
    }

    func saveCommunityBugReport(id: String? = nil, title: String, body: String, severity: String, images: [String] = [], session: NativeSession) async throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines), body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...120).contains(title.utf16.count), (20...4_000).contains(body.utf16.count), ["low", "normal", "security"].contains(severity), images.count <= 4,
              images.allSatisfy({ Self.validCommunityProofPath($0, ownerID: session.userID) }) else { throw NativeClientError.invalidResponse }
        if let id {
            guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
            _ = try await rpc("edit_bug_report", arguments: ["bid": .string(id), "p_title": .string(title), "p_body": .string(body), "p_severity": .string(severity), "p_images": .array(images.map(NativeJSON.string))], session: session)
        } else {
            var values: [String: NativeJSON] = ["user_id": .string(session.userID), "title": .string(title), "body": .string(body), "severity": .string(severity)]
            if !images.isEmpty { values["images"] = .array(images.map(NativeJSON.string)) }
            _ = try await table("bug_reports", method: "POST", values: .object(values), session: session)
        }
    }

    func withdrawCommunityBugReport(id: String, session: NativeSession) async throws {
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        _ = try await rpc("withdraw_bug_report", arguments: ["bid": .string(id)], session: session)
    }

    func communityBanAppeal(session: NativeSession) async throws -> NativeJSON { try await rpc("my_ban_appeal", session: session) }
    func submitCommunityBanAppeal(_ message: String, session: NativeSession) async throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf16.count <= 1_500 else { throw NativeClientError.invalidResponse }
        _ = try await rpc("submit_ban_appeal", arguments: ["msg": .string(message)], session: session)
    }

    func communityVerificationRequest(session: NativeSession) async throws -> NativeJSON? {
        let rows = try await table("verification_requests", query: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "1")], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return rows.array.first
    }

    func submitCommunityVerification(platform: String, handle: String, link: String, note: String, proofPath: String?, session: NativeSession) async throws {
        guard ["youtube", "twitch", "tiktok", "instagram", "x", "other"].contains(platform), !handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: link), url.scheme == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil,
              proofPath.map({ Self.validCommunityProofPath($0, ownerID: session.userID) }) ?? true else { throw NativeClientError.invalidResponse }
        _ = try await rpc("apply_verification", arguments: ["p_platform": .string(platform), "p_handle": .string(handle.trimmingCharacters(in: .whitespacesAndNewlines)), "p_link": .string(link), "p_note": .string(note), "p_proof_path": proofPath.map(NativeJSON.string) ?? .null], session: session)
    }

    private func confirmCommunityProfileUpdate(field: String, value: NativeJSON, session: NativeSession) async throws {
        let rows = try await table("profiles", query: [URLQueryItem(name: "id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "id,\(field)")], method: "PATCH", values: .object([field: value]), session: session, prefer: "return=representation")
        guard case .array = rows, rows.array.count == 1, let row = rows.array.first,
              row["id"].string == session.userID, row[field] == value else { throw NativeClientError.invalidResponse }
    }

    private static func validCommunityProofPath(_ path: String, ownerID: String) -> Bool {
        guard path.hasPrefix(ownerID + "/"), path.utf8.count <= 1_024,
              !path.contains("\\"), !path.contains("%"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.count >= 2 && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
