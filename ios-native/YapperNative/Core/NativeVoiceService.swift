import Foundation

nonisolated enum NativeVoiceAction: String, CaseIterable, Identifiable, Sendable {
    case mute, kick, move, voiceban
    var id: String { rawValue }
    var permission: String {
        switch self { case .mute: "mute_members"; case .kick: "kick_members"; case .move: "move_members"; case .voiceban: "ban_members" }
    }
    var label: String {
        switch self { case .mute: "Mikrofon stummschalten"; case .kick: "Aus dem Sprachkanal entfernen"; case .move: "In einen Sprachkanal verschieben"; case .voiceban: "Sprachsperre verhängen" }
    }
}

@MainActor struct NativeVoiceService {
    let api: NativeAPI

    func moderate(_ action: NativeVoiceAction, channelID: String, userID: String, snapshot: NativeServerSnapshot, minutes: Int = 10, destination: String? = nil, reason: String = "", session: NativeSession) async throws {
        guard UUID(uuidString: userID) != nil, userID != session.userID,
              snapshot.hasPermission(action.permission, userID: session.userID),
              snapshot.outranks(userID, userID: session.userID),
              snapshot.channels.contains(where: { $0.id == channelID && $0.kind == "voice" }) else { throw NativeClientError.invalidResponse }
        var body: [String: NativeJSON] = ["userId": .string(userID), "action": .string(action.rawValue)]
        if action == .voiceban {
            guard (1...525_600).contains(minutes), reason.utf16.count <= 1000 else { throw NativeClientError.invalidResponse }
            body["serverId"] = .string(snapshot.server.id)
            body["minutes"] = .number(Double(minutes))
            body["reason"] = .string(reason)
        } else {
            body["channelId"] = .string(channelID)
            if action == .mute {
                guard (1...1440).contains(minutes) else { throw NativeClientError.invalidResponse }
                body["minutes"] = .number(Double(minutes))
            }
            if action == .move {
                guard let destination, destination != channelID,
                      snapshot.channels.contains(where: { $0.id == destination && $0.kind == "voice" }) else { throw NativeClientError.invalidResponse }
                body["toChannelId"] = .string(destination)
            }
        }
        _ = try await api.webAPI(path: "api/voice/moderate", method: "POST", body: .object(body), session: session)
    }

    func report(channelID: String, userID: String, reason: String, details: String, session: NativeSession) async throws {
        guard UUID(uuidString: channelID) != nil, UUID(uuidString: userID) != nil, userID != session.userID,
              !reason.isEmpty, reason.utf16.count <= 80, details.utf16.count <= 2000 else { throw NativeClientError.invalidResponse }
        _ = try await api.rpc("report_voice", arguments: ["uid": .string(userID), "vchannel": .string(channelID), "why": .string(reason), "more": .string(details)], session: session)
        _ = try? await api.webAPI(path: "api/voice/moderate", method: "POST", body: .object(["channelId": .string(channelID), "userId": .string(userID), "action": .string("enforce")]), session: session)
    }

    func bans(serverID: String, session: NativeSession) async throws -> [NativeJSON] {
        guard UUID(uuidString: serverID) != nil else { throw NativeClientError.invalidResponse }
        return try await api.table("server_voice_bans", query: [URLQueryItem(name: "server_id", value: "eq." + serverID), URLQueryItem(name: "select", value: "user_id,until,reason,by,created_at"), URLQueryItem(name: "order", value: "created_at.desc")], session: session).array.filter { row in
            guard let until = row["until"].string.flatMap({ try? NativeDate.parse($0) }) else { return row["until"] == .null }
            return until > Date()
        }
    }

    func unban(userID: String, snapshot: NativeServerSnapshot, session: NativeSession) async throws {
        guard UUID(uuidString: userID) != nil, snapshot.hasPermission("ban_members", userID: session.userID) else { throw NativeClientError.invalidResponse }
        _ = try await api.rpc("voice_unban", arguments: ["sid": .string(snapshot.server.id), "uid": .string(userID)], session: session)
    }
}
