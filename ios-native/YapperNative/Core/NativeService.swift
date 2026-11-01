import Foundation

nonisolated struct NativeCapabilities: Equatable, Sendable {
    var isAdministrator = false
    var isModerator = false
    var flags: NativeJSON = .object([:])
    var joinedServerIDs: Set<String> = []

    /// Shipped flagOnReal: everyone, or a test user's ID / one joined server's ID.
    /// Bootstrap supplies an array; my_flags consumers may supply a keyed object.
    func flagOn(_ key: String, userID: String?, serverID: String? = nil) -> Bool {
        let flag = flags.object?[key] ?? flags.array.first(where: { $0["key"].string == key }) ?? .null
        if flag["mode"].string == "everyone" { return true }
        guard flag["mode"].string == "test" else { return false }
        if let userID, flag["users"].array.contains(.string(userID)) { return true }
        if let serverID { return flag["servers"].array.contains(.string(serverID)) }
        return flag["servers"].array.contains { row in row.string.map(joinedServerIDs.contains) ?? false }
    }
}

/// The official Plus limit requires both a live subscription and the feature rollout.
/// Carry the profile identity so another account's cached entitlement cannot apply.
nonisolated struct NativeMessagePolicy: Equatable, Sendable {
    let userID: String?
    let plusUntil: Date?
    let capabilities: NativeCapabilities

    init(user: YapperUser? = nil, capabilities: NativeCapabilities = NativeCapabilities()) {
        userID = user?.id
        plusUntil = user?.plusUntil
        self.capabilities = capabilities
    }

    static let standard = NativeMessagePolicy()

    func maximumLength(for sessionUserID: String?, at now: Date = Date()) -> Int {
        guard let sessionUserID, sessionUserID == userID,
              let plusUntil, plusUntil > now,
              capabilities.flagOn("plus_4000", userID: sessionUserID) else { return 2000 }
        return 4000
    }

    func validate(_ text: String, for sessionUserID: String, at now: Date = Date()) throws {
        guard text.utf16.count <= maximumLength(for: sessionUserID, at: now) else { throw NativeClientError.messageTooLong }
    }
}

/// Preserves the observed wire contract, including optional and versioned profile fields.
nonisolated enum NativeJSON: Codable, Equatable, Sendable {
    case object([String: NativeJSON]), array([NativeJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? value.decode([NativeJSON].self) { self = .array(v) }
        else { self = .object(try value.decode([String: NativeJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(v): try value.encode(v)
        case let .array(v): try value.encode(v)
        case let .string(v): try value.encode(v)
        case let .number(v): try value.encode(v)
        case let .bool(v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> NativeJSON { object?[key] ?? .null }
    var object: [String: NativeJSON]? { if case let .object(v) = self { v } else { nil } }
    var array: [NativeJSON] { if case let .array(v) = self { v } else { [] } }
    var string: String? { if case let .string(v) = self { v } else { nil } }
    var number: Double? { if case let .number(v) = self { v } else { nil } }
    var int: Int? { number.flatMap { $0 >= Double(Int.min) && $0 < Double(Int.max) ? Int($0) : nil } }
    var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    var rows: [NativeJSON] { if case .array = self { array } else if case .object = self { [self] } else { [] } }
}

extension NativeAPI {
    func rpc(_ name: String, arguments: [String: NativeJSON] = [:], session: NativeSession) async throws -> NativeJSON {
        guard Self.validResourceName(name) else { throw NativeClientError.invalidEndpoint }
        let data = try await dataResponse(request: request(path: "rest/v1/rpc/" + name, method: "POST", token: session.accessToken, body: JSONEncoder().encode(NativeJSON.object(arguments))))
        guard !data.isEmpty else { return .null }
        do { return try JSONDecoder().decode(NativeJSON.self, from: data) }
        catch { throw NativeClientError.malformedResponse("RPC response") }
    }

    func table(_ name: String, query: [URLQueryItem] = [], method: String = "GET", values: NativeJSON? = nil, session: NativeSession, prefer: String? = nil) async throws -> NativeJSON {
        guard Self.validResourceName(name), ["GET", "POST", "PATCH", "DELETE"].contains(method) else { throw NativeClientError.invalidEndpoint }
        var request = try request(path: "rest/v1/" + name, query: query, method: method, token: session.accessToken, body: try values.map { try JSONEncoder().encode($0) })
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        let data = try await dataResponse(request: request)
        guard !data.isEmpty else { return .null }
        do { return try JSONDecoder().decode(NativeJSON.self, from: data) }
        catch { throw NativeClientError.malformedResponse("Service response") }
    }

    /// Same service origin and TLS policy as the official client; never forwards a session on redirects.
    func webAPI(path: String, method: String = "GET", body: NativeJSON? = nil, session: NativeSession) async throws -> NativeJSON {
        guard path.hasPrefix("api/"), !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw NativeClientError.invalidEndpoint }
        var request = try request(path: path, method: method, body: try body.map { try JSONEncoder().encode($0) }, loginOrigin: true)
        request.url = URL(string: "https://www.yapin.gg")!.appendingPathComponent(path)
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let data = try await dataResponse(request: request)
        guard !data.isEmpty else { return .null }
        do { return try JSONDecoder().decode(NativeJSON.self, from: data) }
        catch { throw NativeClientError.malformedResponse("Website API response") }
    }

    private static func validResourceName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 80 && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }
}
