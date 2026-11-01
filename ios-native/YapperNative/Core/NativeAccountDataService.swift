import Foundation

nonisolated struct NativeAccountExport: Sendable {
    let data: Data
    let cutShort: [String]
    let couldNotLoad: [String]
    let complete: Bool

    init(data: Data) throws {
        let json = try JSONDecoder().decode(NativeJSON.self, from: data)
        guard json["export_complete"].bool == true else {
            throw NativeClientError.api(status: 502, message: "Der Export wurde nicht vollständig übertragen. Bitte erneut versuchen.")
        }
        self.data = data
        cutShort = json["cut_short"].array.compactMap(\.string)
        couldNotLoad = json["could_not_load"].array.compactMap(\.string)
        complete = json["complete"].bool != false && cutShort.isEmpty && couldNotLoad.isEmpty
    }

    @concurrent static func decode(data: Data) async throws -> Self {
        try Task.checkCancellation()
        let export = try Self(data: data)
        try Task.checkCancellation()
        return export
    }
}

/// Observed export and deletion contracts from modules 27w8… and 0sn….
/// Deletion is called only after an explicit password + destructive confirmation.
@MainActor struct NativeAccountDataService {
    let api: NativeAPI

    func export(session: NativeSession) async throws -> NativeAccountExport {
        var request = try api.request(path: "api/me/export", method: "POST", loginOrigin: true)
        request.url = URL(string: "https://www.yapin.gg/api/me/export")!
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return try await NativeAccountExport.decode(data: api.dataResponse(request: request, maximumBytes: 128 * 1024 * 1024))
    }

    func deleteAccount(password: String, gdprDelete: Bool, session: NativeSession) async throws {
        guard !password.isEmpty, password.utf8.count <= 1024, UUID(uuidString: session.userID) != nil else { throw NativeClientError.invalidResponse }
        let reauthenticated = try await api.rpc("reauth_check", arguments: ["p_password": .string(password)], session: session)
        try requireNoError(reauthenticated)
        try Task.checkCancellation()
        // The official flow removes hosted media first; cleanup failures do not block account deletion.
        _ = try? await api.webAPI(path: "api/media/remove", method: "POST", body: .object(["all": .bool(true)]), session: session)
        for bucket in ["avatars", "banners", "emojis", "attachments", "icons"] {
            try Task.checkCancellation()
            var paths: [String] = []
            var offset = 0
            while true {
                let body: NativeJSON = .object(["prefix": .string(session.userID), "limit": .number(1000), "offset": .number(Double(offset))])
                guard let rows = try? await api.response([NativeJSON].self, request: api.request(path: "storage/v1/object/list/" + bucket, method: "POST", token: session.accessToken, body: JSONEncoder().encode(body))), !rows.isEmpty else { break }
                for row in rows where row["id"].string != nil {
                    if let name = row["name"].string, !name.isEmpty, !name.contains("/"), !name.contains("..") {
                        paths.append(session.userID + "/" + name)
                    }
                }
                if rows.count < 1000 { break }
                offset += 1000
                try Task.checkCancellation()
            }
            for offset in stride(from: 0, to: paths.count, by: 100) {
                let chunk = Array(paths[offset..<min(offset + 100, paths.count)])
                let body: NativeJSON = .object(["prefixes": .array(chunk.map(NativeJSON.string))])
                _ = try? await api.dataResponse(request: api.request(path: "storage/v1/object/" + bucket, method: "DELETE", token: session.accessToken, body: JSONEncoder().encode(body)))
            }
        }
        try Task.checkCancellation()
        if gdprDelete {
            _ = try await api.webAPI(path: "api/account/delete", method: "POST", body: .object(["password": .string(password)]), session: session)
        } else {
            let result = try await api.rpc("delete_my_account", arguments: ["p_password": .string(password)], session: session)
            try requireNoError(result)
        }
        _ = try? await api.dataResponse(request: api.request(path: "auth/v1/logout", method: "POST", token: session.accessToken))
    }

    private func requireNoError(_ value: NativeJSON) throws {
        switch value {
        case .null, .bool(false), .number(0), .string(""): return
        case let .string(message): throw NativeClientError.api(status: 400, message: String(message.prefix(500)))
        default: throw NativeClientError.invalidResponse
        }
    }
}
