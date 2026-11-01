import Foundation
import Observation

nonisolated struct NativeSecurityFactor: Identifiable, Sendable, Equatable {
    let id: String
    let type: String
    let status: String
    let name: String
    let createdAt: Date?
    var isVerified: Bool { status == "verified" }

    init(row: NativeJSON) throws {
        guard let id = row["id"].string, UUID(uuidString: id) != nil,
              let type = row["factor_type"].string,
              let status = row["status"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.type = type; self.status = status
        name = row["friendly_name"].string ?? (type == "totp" ? "Authenticator" : type)
        createdAt = row["created_at"].string.flatMap { try? NativeDate.parse($0) }
    }
}

nonisolated struct NativeSecurityAccount: Sendable {
    let email: String?
    var pendingEmail: String? = nil
    let createdAt: Date?
    let lastSignIn: Date?
    let factors: [NativeSecurityFactor]
}

nonisolated struct NativePasskey: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let createdAt: Date?
    let lastUsedAt: Date?
    let backedUp: Bool

    init(row: NativeJSON) throws {
        guard let id = row["id"].string, !id.isEmpty, id.utf8.count <= 512 else { throw NativeClientError.invalidResponse }
        self.id = id
        name = row["name"].string ?? "Passkey"
        createdAt = row["created_at"].string.flatMap { try? NativeDate.parse($0) }
        lastUsedAt = row["last_used_at"].string.flatMap { try? NativeDate.parse($0) }
        backedUp = row["backed_up"].bool ?? false
    }
}

nonisolated struct NativeOAuthGrant: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let owner: String?
    let scope: [String]
    let firstAt: Date?
    let lastAt: Date?
    let iconURL: URL?

    init(row: NativeJSON) throws {
        guard let id = row["app_id"].string, !id.isEmpty, id.utf8.count <= 512,
              let name = row["name"].string else { throw NativeClientError.invalidResponse }
        self.id = id; self.name = name
        owner = row["owner_username"].string
        scope = row["scope"].array.compactMap(\.string)
        firstAt = row["first_at"].string.flatMap { try? NativeDate.parse($0) }
        lastAt = row["last_at"].string.flatMap { try? NativeDate.parse($0) }
        iconURL = NativeConfiguration.publicAsset(bucket: "icons", path: row["icon_path"].string)
    }
}

nonisolated struct NativeTOTPEnrollment: Identifiable, Sendable {
    let id: String
    let secret: String
    let uri: String

    init(row: NativeJSON) throws {
        guard row["type"].string == "totp", let id = row["id"].string, UUID(uuidString: id) != nil,
              let secret = row["totp"]["secret"].string, (16...512).contains(secret.utf8.count),
              secret.uppercased().utf8.allSatisfy({ (65...90).contains($0) || (50...55).contains($0) || $0 == 61 }),
              let uri = row["totp"]["uri"].string, uri.utf8.count <= 4_096,
              let components = URLComponents(string: uri), components.scheme == "otpauth", components.host == "totp",
              components.user == nil, components.password == nil, components.port == nil,
              components.queryItems?.first(where: { $0.name == "secret" })?.value?.uppercased() == secret.uppercased() else { throw NativeClientError.invalidResponse }
        self.id = id; self.secret = secret; self.uri = uri
    }
}

nonisolated enum NativeDMPrivacy: String, CaseIterable, Identifiable, Sendable {
    case everyone, servers, friends
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyone: "Alle"
        case .servers: "Gemeinsame Server und Freunde"
        case .friends: "Nur Freunde"
        }
    }
}

extension NativeAPI {
    func securityAccount(session: NativeSession) async throws -> NativeSecurityAccount {
        let value = try await response(NativeJSON.self, request: request(path: "auth/v1/user", token: session.accessToken))
        guard value["id"].string == session.userID else { throw NativeClientError.invalidResponse }
        let factors: [NativeSecurityFactor]
        switch value["factors"] {
        case .null: factors = []
        case let .array(rows): factors = try rows.map(NativeSecurityFactor.init(row:))
        default: throw NativeClientError.invalidResponse
        }
        return NativeSecurityAccount(email: value["email"].string, pendingEmail: value["new_email"].string.flatMap { $0.isEmpty ? nil : $0 }, createdAt: value["created_at"].string.flatMap { try? NativeDate.parse($0) }, lastSignIn: value["last_sign_in_at"].string.flatMap { try? NativeDate.parse($0) }, factors: factors)
    }

    func requestSecurityEmailChange(_ email: String, session: NativeSession) async throws {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) != nil else {
            throw NativeClientError.api(status: 400, message: "Gib eine gültige E-Mail-Adresse ein.")
        }
        // Auth SDK _updateUser: signed-in PUT/user, with the official website as confirmation target.
        // The backend controls confirmations; requesting a change does not replace the native session.
        let request = try request(path: "auth/v1/user", query: [URLQueryItem(name: "redirect_to", value: "https://www.yapin.gg")], method: "PUT", token: session.accessToken, body: JSONEncoder().encode(NativeJSON.object(["email": .string(email)])))
        let response = try await response(NativeJSON.self, request: request)
        let user = response["user"].object == nil ? response : response["user"]
        guard user["id"].string == session.userID else { throw NativeClientError.invalidResponse }
    }

    func securityPasskeys(session: NativeSession) async throws -> [NativePasskey] {
        let rows = try await rpc("my_passkeys", session: session)
        guard case .array = rows else { throw NativeClientError.invalidResponse }
        return try rows.array.map(NativePasskey.init(row:))
    }

    func renameSecurityPasskey(id: String, name: String, session: NativeSession) async throws {
        try Self.requireSecurityOpaqueID(id)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 40 else {
            throw NativeClientError.api(status: 400, message: "Der Passkey-Name braucht 1 bis 40 Zeichen.")
        }
        _ = try await rpc("rename_passkey", arguments: ["p_id": .string(id), "p_name": .string(name)], session: session)
    }

    func removeSecurityPasskey(id: String, session: NativeSession) async throws {
        try Self.requireSecurityOpaqueID(id)
        _ = try await rpc("remove_passkey", arguments: ["p_id": .string(id)], session: session)
    }

    func securityOAuthGrants(session: NativeSession) async throws -> [NativeOAuthGrant] {
        let result = try await rpc("oauth_my_grants", session: session)
        guard case .array = result else { throw NativeClientError.invalidResponse }
        return try result.array.map(NativeOAuthGrant.init(row:))
    }

    func revokeSecurityOAuthGrant(id: String, session: NativeSession) async throws {
        try Self.requireSecurityOpaqueID(id)
        _ = try await rpc("oauth_revoke", arguments: ["p_app_id": .string(id)], session: session)
    }

    func enrollSecurityTOTP(name: String, session: NativeSession) async throws -> NativeTOTPEnrollment {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf16.count <= 100 else { throw NativeClientError.invalidResponse }
        let body: NativeJSON = .object(["factor_type": .string("totp"), "friendly_name": .string(clean)])
        let value = try await response(NativeJSON.self, request: request(path: "auth/v1/factors", method: "POST", token: session.accessToken, body: JSONEncoder().encode(body)))
        return try NativeTOTPEnrollment(row: value)
    }

    func removeSecurityFactor(id: String, session: NativeSession) async throws {
        guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse }
        _ = try await dataResponse(request: request(path: "auth/v1/factors/\(id)", method: "DELETE", token: session.accessToken))
    }

    func securityDMPrivacy(session: NativeSession) async throws -> NativeDMPrivacy {
        let rows = try await table("profiles", query: [URLQueryItem(name: "id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "id,dms_from")], session: session)
        guard let row = rows.array.first, row["id"].string == session.userID else { throw NativeClientError.invalidResponse }
        if row["dms_from"] == .null { return .servers }
        guard let value = row["dms_from"].string, let privacy = NativeDMPrivacy(rawValue: value) else { throw NativeClientError.invalidResponse }
        return privacy
    }

    func saveSecurityDMPrivacy(_ privacy: NativeDMPrivacy, session: NativeSession) async throws {
        let rows = try await table("profiles", query: [URLQueryItem(name: "id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "id,dms_from")], method: "PATCH", values: .object(["dms_from": .string(privacy.rawValue)]), session: session, prefer: "return=representation")
        guard let row = rows.array.first, row["id"].string == session.userID, row["dms_from"].string == privacy.rawValue else { throw NativeClientError.invalidResponse }
    }

    func changeSecurityPassword(current: String, replacement: String, session: NativeSession) async throws {
        guard (6...72).contains(replacement.utf16.count) else {
            throw NativeClientError.api(status: 400, message: "Das Passwort braucht 6 bis 72 Zeichen.")
        }
        let result = try await webAPI(path: "api/account/password", method: "POST", body: .object(["current": .string(current), "password": .string(replacement)]), session: session)
        if let message = result["error"].string { throw NativeClientError.api(status: 400, message: String(message.prefix(300))) }
    }

    func securityLogoutEverywhere(session: NativeSession) async throws {
        _ = try? await rpc("logout_everywhere_signal", session: session)
        try Task.checkCancellation()
        _ = try await dataResponse(request: request(path: "auth/v1/logout", query: [URLQueryItem(name: "scope", value: "global")], method: "POST", token: session.accessToken))
    }

    private static func requireSecurityOpaqueID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains(where: \.isWhitespace) else { throw NativeClientError.invalidResponse }
    }
}

@MainActor @Observable final class NativeSecurityModel {
    let store: NativeStore
    var account: NativeSecurityAccount?
    var passkeys: [NativePasskey]?
    var grants: [NativeOAuthGrant]?
    var privacy: NativeDMPrivacy?
    var pendingEnrollment: NativeTOTPEnrollment?
    var isLoading = false
    var isBusy = false
    var error: String?
    var passkeyError: String?
    var grantsError: String?
    var privacyError: String?
    private var loadID = UUID()

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
        isLoading = true; error = nil; passkeyError = nil; grantsError = nil; privacyError = nil
        defer { if operation == loadID { isLoading = false } }
        #if DEBUG
        if isFixture {
            account = NativeSecurityAccount(email: nil, createdAt: nil, lastSignIn: nil, factors: [])
            passkeys = []; grants = []; privacy = .servers
            return
        }
        #endif
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.securityAccount(session: session) }
            guard operation == loadID, !Task.isCancelled else { return }
            account = result
        } catch is CancellationError { return } catch { if operation == loadID { self.error = error.localizedDescription } }
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.securityPasskeys(session: session) }
            guard operation == loadID, !Task.isCancelled else { return }
            passkeys = result
        } catch is CancellationError { return } catch { if operation == loadID { passkeyError = error.localizedDescription } }
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.securityOAuthGrants(session: session) }
            guard operation == loadID, !Task.isCancelled else { return }
            grants = result
        } catch is CancellationError { return } catch { if operation == loadID { grantsError = error.localizedDescription } }
        do {
            let result = try await store.withAuthenticatedSession { api, session in try await api.securityDMPrivacy(session: session) }
            guard operation == loadID, !Task.isCancelled else { return }
            privacy = result
        } catch is CancellationError {} catch { if operation == loadID { privacyError = error.localizedDescription } }
    }

    func rename(_ key: NativePasskey, name: String) async {
        await perform {
            try await self.store.withAuthenticatedSession { api, session in try await api.renameSecurityPasskey(id: key.id, name: name, session: session) }
        }
    }

    func remove(_ key: NativePasskey) async {
        await perform {
            try await self.store.withAuthenticatedSession { api, session in try await api.removeSecurityPasskey(id: key.id, session: session) }
        }
    }

    func revoke(_ grant: NativeOAuthGrant) async {
        await perform {
            try await self.store.withAuthenticatedSession { api, session in try await api.revokeSecurityOAuthGrant(id: grant.id, session: session) }
        }
    }

    func setPrivacy(_ value: NativeDMPrivacy) async {
        await perform {
            try await self.store.withAuthenticatedSession { api, session in try await api.saveSecurityDMPrivacy(value, session: session) }
        }
    }

    func beginEnrollment() async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if isFixture { return }
            #endif
            let name = "Yapper iPhone \(Date().formatted(.dateTime.year().month().day().hour().minute()))"
            pendingEnrollment = try await store.withAuthenticatedSession { api, session in try await api.enrollSecurityTOTP(name: name, session: session) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func verifyEnrollment(code: String) async -> Bool {
        guard let pending = pendingEnrollment, !isBusy else { return false }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            try await store.verifyNativeSecurityFactor(factorID: pending.id, code: code)
            pendingEnrollment = nil
            await load()
            return true
        } catch is CancellationError { return false } catch { self.error = error.localizedDescription; return false }
    }

    func cancelEnrollment() async {
        guard let pending = pendingEnrollment, !isBusy else { return }
        pendingEnrollment = nil
        await perform {
            try await self.store.withAuthenticatedSession { api, session in try await api.removeSecurityFactor(id: pending.id, session: session) }
        }
    }

    func removeFactor(_ factor: NativeSecurityFactor, code: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if isFixture { return true }
            #endif
            if factor.isVerified && factor.type == "totp" {
                try await store.verifyNativeSecurityFactor(factorID: factor.id, code: code)
            }
            try await store.withAuthenticatedSession { api, session in try await api.removeSecurityFactor(id: factor.id, session: session) }
            await load()
            return true
        } catch is CancellationError { return false } catch { self.error = error.localizedDescription; return false }
    }

    func logoutEverywhere() async {
        await perform(reload: false) {
            try await self.store.withAuthenticatedSession { api, session in try await api.securityLogoutEverywhere(session: session) }
            self.store.signOut()
        }
    }

    private func perform(reload: Bool = true, _ operation: @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true; error = nil
        defer { isBusy = false }
        do {
            #if DEBUG
            if isFixture { return }
            #endif
            try await operation()
            if reload { await load() }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
