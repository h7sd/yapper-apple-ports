import Foundation

// Official invite route 0zmnye7enpxtk.js and server helpers in
// 04ggl-1jky0-d.js: get_invite, invite_apply_info, apply_to_server,
// withdraw_join_request. This form remains native and uses no web content.
nonisolated struct NativeServerInvitation: Sendable {
    let serverID: String
    let name: String
    let iconPath: String?
    let memberCount: Int?
    let alreadyMember: Bool
    init(_ row: NativeJSON) throws {
        guard let serverID = row["server_id"].string, UUID(uuidString: serverID) != nil,
              let name = row["name"].string, !name.isEmpty else { throw NativeClientError.malformedResponse("Server invitation") }
        self.serverID = serverID; self.name = name; iconPath = row["icon_path"].string
        memberCount = row["member_count"].int; alreadyMember = row["already_member"].bool ?? false
    }
}

nonisolated struct NativeServerApplication: Sendable {
    let apply: Bool
    let questions: [String]
    let requestStatus: String?
    let note: String?
    let retryAt: Date?
    init(_ row: NativeJSON) throws {
        guard row.object != nil, let apply = row["apply"].bool else { throw NativeClientError.malformedResponse("Server application") }
        self.apply = apply; questions = row["questions"].array.compactMap(\.string)
        guard questions.count <= 10 else { throw NativeClientError.invalidResponse }
        requestStatus = row["request"]["status"].string; note = row["request"]["note"].string
        retryAt = try row["request"]["retry_at"].string.map(NativeDate.parse)
    }
}

extension NativeAPI {
    func nativeServerInvitation(code: String, session: NativeSession) async throws -> NativeServerInvitation {
        let normalized = try NativeServerInput.inviteCode(code)
        let rows = try await rpc("get_invite", arguments: ["invite_code": .string(normalized)], session: session).rows
        guard let row = rows.first else { throw NativeClientError.api(status: 404, message: "Diese Einladung ist abgelaufen oder für dich nicht verfügbar.") }
        return try NativeServerInvitation(row)
    }

    func nativeServerApplication(code: String, session: NativeSession) async throws -> NativeServerApplication? {
        let normalized = try NativeServerInput.inviteCode(code)
        do {
            let value = try await rpc("invite_apply_info", arguments: ["invite_code": .string(normalized)], session: session)
            if value == .null { return nil }
            return try NativeServerApplication(value)
        } catch let NativeClientError.api(status, message) where status == 404 && (message.contains("invite_apply_info") || message.contains("PGRST202")) { return nil }
    }

    func nativeApplyToServer(code: String, message: String, answers: [String], session: NativeSession) async throws -> String? {
        let normalized = try NativeServerInput.inviteCode(code)
        guard message.count <= 500, answers.count <= 10, answers.allSatisfy({ $0.count <= 300 }) else { throw NativeClientError.api(status: 400, message: "Nachrichten dürfen höchstens 500 Zeichen und Antworten höchstens 300 Zeichen lang sein.") }
        let value = try await rpc("apply_to_server", arguments: ["invite_code": .string(normalized), "p_message": .string(message), "p_answers": .array(answers.map(NativeJSON.string))], session: session)
        guard let joined = value["joined"].bool else { throw NativeClientError.invalidResponse }
        if joined {
            guard let id = value["server_id"].string, UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
            return id
        }
        return nil
    }

    func nativeWithdrawServerApplication(serverID: String, session: NativeSession) async throws {
        guard UUID(uuidString: serverID) != nil else { throw NativeClientError.invalidResponse }
        _ = try await rpc("withdraw_join_request", arguments: ["sid": .string(serverID)], session: session)
    }
}
