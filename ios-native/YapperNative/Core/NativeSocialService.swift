import Foundation
import Observation

extension NativeAPI {
    private static let socialProfileColumns = "id,username,display_name,bio,pronouns,custom_status,custom_status_until,avatar_path,banner_path,accent_color,accent_color2,links,badges,created_at,plus_until,plus_since,plus_badge_hidden,account_level,tag,server_tag,tag_icon_off,verified_as,verified_hidden,banner_x,banner_y,banner_zoom,avatar_x,avatar_y,avatar_zoom,avatar_rot,avatar_deco,profile_effect,name_banner,avatar_revert_at"

    func socialProfiles(ids: [String], session: NativeSession) async throws -> [NativeProfileDetail] {
        try await publicProfiles(ids: ids, session: session).map(NativeProfileDetail.init(row:))
    }

    func socialSnapshot(session: NativeSession) async throws -> NativeSocialSnapshot {
        var friendships: [NativeJSON] = []
        for page in 0..<100 {
            try Task.checkCancellation()
            let rows = try await table("friendships", query: [URLQueryItem(name: "select", value: "requester,addressee,status,note"), URLQueryItem(name: "order", value: "id"), URLQueryItem(name: "offset", value: "\(page * 1_000)"), URLQueryItem(name: "limit", value: "1000")], session: session)
            guard case .array = rows else { throw NativeClientError.invalidResponse }
            friendships += rows.array
            if rows.array.count < 1_000 { break }
            if page == 99 { throw NativeClientError.malformedResponse("Friendship pagination limit") }
        }
        try Task.checkCancellation()
        let blocks = try await table("blocks", query: [URLQueryItem(name: "select", value: "blocked")], session: session)
        try Task.checkCancellation()
        let requests = try await table("dm_requests", query: [URLQueryItem(name: "select", value: "from_id"), URLQueryItem(name: "order", value: "created_at.desc"), URLQueryItem(name: "limit", value: "100")], session: session)
        guard case .array = blocks, case .array = requests else { throw NativeClientError.invalidResponse }
        var relation: [String: (NativeFriendRelation, String?)] = [:]
        for row in friendships {
            guard let requester = row["requester"].string, let addressee = row["addressee"].string,
                  requester == session.userID || addressee == session.userID else { throw NativeClientError.invalidResponse }
            let other = requester == session.userID ? addressee : requester
            let state: NativeFriendRelation
            switch row["status"].string {
            case "accepted": state = .accepted
            case "pending": state = requester == session.userID ? .outgoing : .incoming
            default: continue
            }
            relation[other] = (state, state == .incoming ? row["note"].string : nil)
        }
        let blockedIDs = blocks.array.compactMap { $0["blocked"].string }
        let requestIDs = requests.array.compactMap { $0["from_id"].string }
        let profiles = try await socialProfiles(ids: Array(relation.keys) + blockedIDs + requestIDs, session: session)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let friends = relation.compactMap { id, value in byID[id].map { NativeFriendEntry(profile: $0, relation: value.0, requestNote: value.1) } }
            .sorted { $0.profile.displayName.localizedStandardCompare($1.profile.displayName) == .orderedAscending }
        return NativeSocialSnapshot(friends: friends, blocked: blockedIDs.compactMap { byID[$0] }, requests: requestIDs.compactMap { byID[$0] })
    }

    func searchSocialPeople(_ query: String, session: NativeSession) async throws -> [NativeProfileDetail] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf16.count <= 100 else { return [] }
        let result = try await rpc("search_people", arguments: ["q": .string(query)], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        return try result.array.map(NativeProfileDetail.init(row:))
    }

    func friendAction(_ action: NativeFriendAction, session: NativeSession) async throws {
        let name: String
        let args: [String: NativeJSON]
        switch action {
        case let .request(username, note):
            let clean = username.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard !clean.isEmpty, clean.utf16.count <= 32, note.utf16.count <= 100 else { throw NativeClientError.invalidResponse }
            name = "send_friend_request"
            var values: [String: NativeJSON] = ["target_username": .string(clean)]
            let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanNote.isEmpty { values["note"] = .string(cleanNote) }
            args = values
        case let .respond(other, accept):
            try Self.requireSocialID(other)
            name = "respond_friend_request"; args = ["other": .string(other), "accept": .bool(accept)]
        case let .remove(other):
            try Self.requireSocialID(other)
            name = "remove_friend"; args = ["other": .string(other)]
        case let .block(other):
            try Self.requireSocialID(other)
            name = "block_user"; args = ["other": .string(other)]
        case let .unblock(other):
            try Self.requireSocialID(other)
            name = "unblock_user"; args = ["other": .string(other)]
        }
        _ = try await rpc(name, arguments: args, session: session)
    }

    func openSocialDM(userID: String, session: NativeSession) async throws -> String {
        try Self.requireSocialID(userID)
        let result = try await rpc("get_or_create_dm", arguments: ["other": .string(userID)], session: session)
        guard let id = result.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        try await nativeSetConversationHidden(channelID: id, hidden: false, session: session)
        return id
    }

    func ignoreSocialDMRequest(userID: String, session: NativeSession) async throws {
        try Self.requireSocialID(userID)
        _ = try await table("dm_requests", query: [URLQueryItem(name: "from_id", value: "eq.\(userID)")], method: "DELETE", session: session)
    }

    func saveSocialProfile(profileID: String, draft: NativeProfileDraft, avatarPath: String? = nil, bannerPath: String? = nil, removeAvatar: Bool = false, removeBanner: Bool = false, avatarRevertAt: Date? = nil, previousProfile: NativeProfileDetail? = nil, session: NativeSession) async throws -> NativeProfileDetail {
        guard profileID == session.userID, previousProfile.map({ $0.id == session.userID }) ?? true else { throw NativeClientError.invalidResponse }
        var values = try draft.values()
        if let avatarPath { values["avatar_path"] = .string(avatarPath) }
        else if removeAvatar { values["avatar_path"] = .null }
        if let bannerPath { values["banner_path"] = .string(bannerPath) }
        else if removeBanner { values["banner_path"] = .null }
        let changedAvatar = values["avatar_path"].map { $0.string != previousProfile?.avatarPath } ?? false
        if let avatarRevertAt {
            guard avatarPath != nil, avatarRevertAt > Date() else { throw NativeClientError.invalidResponse }
            values["avatar_revert_at"] = .string(ISO8601DateFormatter().string(from: avatarRevertAt))
        }
        var previousTemporaryPath: String?
        if changedAvatar, avatarRevertAt == nil, previousProfile?.avatarRevertAt != nil {
            previousTemporaryPath = try await rpc("my_avatar_prev_path", session: session).string
            try Task.checkCancellation()
        }
        let result = try await table("profiles", query: [URLQueryItem(name: "id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: Self.socialProfileColumns)], method: "PATCH", values: .object(values), session: session, prefer: "return=representation")
        guard let row = result.array.first else { throw NativeClientError.invalidResponse }
        let profile = try NativeProfileDetail(row: row)
        guard profile.id == session.userID else { throw NativeClientError.invalidResponse }
        if let previousProfile {
            if changedAvatar, !(avatarRevertAt != nil && previousProfile.avatarRevertAt == nil) { await removeSocialProfileImage(bucket: "avatars", path: previousProfile.avatarPath, session: session) }
            if let previousTemporaryPath, previousTemporaryPath != profile.avatarPath { await removeSocialProfileImage(bucket: "avatars", path: previousTemporaryPath, session: session) }
            if values["banner_path"] != nil, previousProfile.bannerPath != profile.bannerPath { await removeSocialProfileImage(bucket: "banners", path: previousProfile.bannerPath, session: session) }
        }
        return profile
    }

    func keepSocialTemporaryAvatar(session: NativeSession) async throws -> NativeProfileDetail {
        let previous = try await rpc("my_avatar_prev_path", session: session).string
        try Task.checkCancellation()
        let result = try await table("profiles", query: [URLQueryItem(name: "id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: Self.socialProfileColumns)], method: "PATCH", values: .object(["avatar_revert_at": .null]), session: session, prefer: "return=representation")
        guard case .array = result, result.array.count == 1, let row = result.array.first else { throw NativeClientError.invalidResponse }
        let profile = try NativeProfileDetail(row: row)
        guard profile.id == session.userID, profile.avatarRevertAt == nil else { throw NativeClientError.invalidResponse }
        if previous != profile.avatarPath { await removeSocialProfileImage(bucket: "avatars", path: previous, session: session) }
        return profile
    }

    private func removeSocialProfileImage(bucket: String, path: String?, session: NativeSession) async {
        guard let path, ["avatars", "banners"].contains(bucket), path.hasPrefix(session.userID + "/"), !path.contains(".."), !Task.isCancelled else { return }
        _ = try? await webAPI(path: "api/media/remove", method: "POST", body: .object(["bucket": .string(bucket), "path": .string(path)]), session: session)
    }

    func socialMatches(refresh: Bool = false, session: NativeSession) async throws -> [NativeSocialMatch] {
        let rows = try await rpc("my_matches", arguments: ["p_refresh": .bool(refresh)], session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        let ids = rows.array.compactMap { $0["user_id"].string }
        guard ids.count == rows.array.count else { throw NativeClientError.invalidResponse }
        let profiles = try await socialProfiles(ids: ids, session: session)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        return try rows.array.compactMap { row in
            guard let id = row["user_id"].string, let profile = byID[id] else { return nil }
            return try NativeSocialMatch(row: row, profile: profile)
        }
    }

    func socialMatchVisibility(session: NativeSession) async throws -> Bool {
        let rows = try await table("match_settings", query: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "suggest_me")], session: session)
        guard case .array = rows, rows.array.count <= 1 else { throw NativeClientError.invalidResponse }
        guard let row = rows.array.first else { return true }
        guard let visible = row["suggest_me"].bool else { throw NativeClientError.invalidResponse }
        return visible
    }

    func setSocialMatchVisibility(_ visible: Bool, session: NativeSession) async throws {
        _ = try await table("match_settings", method: "POST", values: .object(["user_id": .string(session.userID), "suggest_me": .bool(visible), "updated_at": .string(ISO8601DateFormatter().string(from: Date()))]), session: session, prefer: "resolution=merge-duplicates")
    }

    func socialServerTags(session: NativeSession) async throws -> [NativeServerTagChoice] {
        try await nativeServers(session: session).compactMap { server in
            guard let tag = server.raw["tag"].string, !tag.isEmpty, server.raw["shut_down_at"] == .null else { return nil }
            return NativeServerTagChoice(id: server.id, name: server.name, tag: tag, icon: server.raw["tag_icon"].string)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func wearSocialServerTag(_ id: String?, session: NativeSession) async throws {
        if let id { try Self.requireSocialID(id) }
        _ = try await rpc("set_server_tag", arguments: ["sid": id.map(NativeJSON.string) ?? .null], session: session)
    }

    func setSocialTagIconShown(_ shown: Bool, session: NativeSession) async throws {
        _ = try await rpc("set_tag_icon_shown", arguments: ["p_show": .bool(shown)], session: session)
    }

    func socialInbox(session: NativeSession) async throws -> [NativeInboxItem] {
        let result = try await rpc("my_inbox", arguments: ["lim": .number(30)], session: session)
        guard result.object != nil, case .array = result["items"] else { throw NativeClientError.invalidResponse }
        let before = result["read_before"].string.flatMap { try? NativeDate.parse($0) }
        let keys = Set(result["read_keys"].array.compactMap(\.string))
        return try result["items"].array.map { try NativeInboxItem(row: $0, readBefore: before, readKeys: keys) }.sorted { $0.at > $1.at }
    }

    func markSocialInbox(keys: [String], all: Bool, session: NativeSession) async throws {
        if all { _ = try await rpc("inbox_mark_all", session: session); return }
        guard keys.count <= 50, keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw NativeClientError.invalidResponse }
        _ = try await rpc("inbox_mark", arguments: ["keys": .array(keys.map(NativeJSON.string))], session: session)
    }

    func socialUserNote(userID: String, session: NativeSession) async throws -> String {
        try Self.requireSocialID(userID)
        let result = try await table("user_notes", query: [URLQueryItem(name: "about_id", value: "eq.\(userID)"), URLQueryItem(name: "select", value: "note")], session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        return result.array.first?["note"].string ?? ""
    }

    func setSocialPresence(_ status: String, until: Date? = nil, session: NativeSession) async throws {
        guard ["online", "idle", "dnd", "invisible"].contains(status) else { throw NativeClientError.invalidResponse }
        if let until, status != "online" {
            _ = try await rpc("set_status_until", arguments: ["p": .string(status), "until": .string(ISO8601DateFormatter().string(from: until))], session: session)
        } else {
            _ = try await rpc("set_status_pref", arguments: ["p": .string(status)], session: session)
        }
    }

    func saveSocialUserNote(userID: String, note: String, session: NativeSession) async throws {
        try Self.requireSocialID(userID)
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.utf16.count <= 500 else { throw NativeClientError.invalidResponse }
        let query = [URLQueryItem(name: "owner_id", value: "eq.\(session.userID)"), URLQueryItem(name: "about_id", value: "eq.\(userID)")]
        if note.isEmpty { _ = try await table("user_notes", query: query, method: "DELETE", session: session) }
        else {
            _ = try await table("user_notes", method: "POST", values: .object(["owner_id": .string(session.userID), "about_id": .string(userID), "note": .string(note), "updated_at": .string(ISO8601DateFormatter().string(from: Date()))]), session: session, prefer: "resolution=merge-duplicates")
        }
    }

    func createSocialGroup(name: String, members: [String], session: NativeSession) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !members.isEmpty, members.count <= 9 else { throw NativeClientError.invalidResponse }
        try members.forEach(Self.requireSocialID)
        let result = try await rpc("create_group", arguments: ["group_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "group_icon": .null, "member_ids": .array(Array(Set(members)).sorted().map(NativeJSON.string))], session: session)
        guard let id = result.string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        return id
    }

    func updateSocialGroup(channelID: String, name: String, session: NativeSession) async throws {
        try Self.requireSocialID(channelID)
        let result = try await table("channels", query: [URLQueryItem(name: "id", value: "eq.\(channelID)"), URLQueryItem(name: "select", value: "icon_path")], session: session)
        guard let row = result.array.first else { throw NativeClientError.invalidResponse }
        _ = try await rpc("update_group", arguments: ["cid": .string(channelID), "group_name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)), "group_icon": row["icon_path"]], session: session)
    }

    func addSocialGroupMembers(channelID: String, members: [String], session: NativeSession) async throws {
        try Self.requireSocialID(channelID)
        guard !members.isEmpty, members.count <= 9 else { throw NativeClientError.invalidResponse }
        try members.forEach(Self.requireSocialID)
        _ = try await rpc("add_group_members", arguments: ["cid": .string(channelID), "member_ids": .array(Array(Set(members)).sorted().map(NativeJSON.string))], session: session)
    }

    func removeSocialGroupMember(channelID: String, memberID: String, session: NativeSession) async throws {
        try Self.requireSocialID(channelID); try Self.requireSocialID(memberID)
        _ = try await rpc("remove_group_member", arguments: ["cid": .string(channelID), "uid": .string(memberID)], session: session)
    }

    private static func requireSocialID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
    }
}

nonisolated enum NativeFriendAction: Sendable {
    case request(username: String, note: String)
    case respond(other: String, accept: Bool)
    case remove(String)
    case block(String)
    case unblock(String)
}

@MainActor @Observable final class NativeSocialModel {
    let store: NativeStore
    var snapshot = NativeSocialSnapshot(friends: [], blocked: [], requests: [])
    var searchResults: [NativeProfileDetail] = []
    var isLoading = false
    var isBusy = false
    var error: String?
    private var loadID = UUID()
    private var searchID = UUID()

    init(store: NativeStore) { self.store = store }

    var isFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }

    func load() async {
        let operation = UUID(); loadID = operation
        isLoading = true; error = nil
        defer { if loadID == operation { isLoading = false } }
        do {
            #if DEBUG
            if isFixture {
                snapshot = NativeSocialSnapshot(friends: [NativeFriendEntry(profile: try fixtureProfile(), relation: .accepted, requestNote: nil)], blocked: [], requests: [])
                return
            }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.socialSnapshot(session: session) }
            guard operation == loadID, !Task.isCancelled else { return }
            snapshot = result
        } catch is CancellationError {} catch { if operation == loadID { self.error = error.localizedDescription } }
    }

    func search(_ query: String) async {
        let operation = UUID(); searchID = operation
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { searchResults = []; return }
        do {
            try await Task.sleep(for: .milliseconds(250))
            #if DEBUG
            if isFixture { searchResults = [try fixtureProfile()]; return }
            #endif
            let result = try await store.withAuthenticatedSession { api, session in try await api.searchSocialPeople(query, session: session) }
            guard operation == searchID, !Task.isCancelled else { return }
            searchResults = result
        } catch is CancellationError {} catch { if operation == searchID { self.error = error.localizedDescription } }
    }

    func act(_ action: NativeFriendAction) async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if isFixture { return }
            #endif
            try await store.withAuthenticatedSession { api, session in try await api.friendAction(action, session: session) }
            await load()
            await store.refreshNotificationSoundContext()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func openDM(_ profile: NativeProfileDetail) async -> Conversation? {
        guard !isBusy else { return nil }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if isFixture { return store.conversations.first }
            #endif
            let id = try await store.withAuthenticatedSession { api, session in try await api.openSocialDM(userID: profile.id, session: session) }
            await store.loadConversations()
            guard !Task.isCancelled, let conversation = store.conversations.first(where: { $0.id == id }) else { throw NativeClientError.invalidResponse }
            return conversation
        } catch is CancellationError { return nil } catch { self.error = error.localizedDescription; return nil }
    }

    #if DEBUG
    func fixtureProfile(userID: String = "33333333-3333-4333-8333-333333333333") throws -> NativeProfileDetail {
        try NativeProfileDetail(row: .object(["id": .string(userID), "username": .string(userID == store.user?.id ? "yapper-demo" : "nova"), "display_name": .string(userID == store.user?.id ? "Yapper Demo" : "Nova"), "bio": .string(userID == store.user?.id ? "Native iOS-Vorschau mit synthetischen Beispieldaten." : ""), "created_at": .string("2026-10-01T00:00:00Z"), "pronouns": .string(""), "custom_status": .string("")]))
    }
    #endif
}
