import Foundation

/// The authenticated user's saved preference is separate from socket availability.
/// Official status module 41958 only auto-idles the online preference after ten minutes.
nonisolated enum NativePresencePreference: String, CaseIterable, Sendable {
    case online, idle, dnd, invisible

    static let autoIdleInterval: TimeInterval = 600

    func profileStatus(autoIdle: Bool) -> String {
        self == .online && autoIdle ? Self.idle.rawValue : rawValue
    }

    /// Other users see an invisible user as offline; the account menu retains their preference.
    func visibleStatus(autoIdle: Bool) -> String {
        self == .invisible ? "offline" : profileStatus(autoIdle: autoIdle)
    }

    func isAutomaticallyIdle(lastActivityAt: Date, now: Date) -> Bool {
        self == .online && now.timeIntervalSince(lastActivityAt) >= Self.autoIdleInterval
    }
}

nonisolated struct NativeOwnPresencePreference: Equatable, Sendable {
    let ownerID: String
    let preference: NativePresencePreference
    var status: String { preference.rawValue }
}

extension NativeAPI {
    /// This read must not depend on optional notification preferences or the blocks table.
    /// Official startStatus defaults to online; syncStatusFromAccount retains that local
    /// preference for a successful null result. Failures and malformed values remain errors.
    func nativeOwnPresencePreference(session: NativeSession, defaultPreference: NativePresencePreference = .online) async throws -> NativeOwnPresencePreference {
        let request = try request(path: "rest/v1/rpc/my_status_pref", method: "POST", token: session.accessToken,
                                  body: JSONEncoder().encode(NativeJSON.object([:])))
        let data = try await dataResponse(request: request)
        let result: NativeJSON
        do { result = try JSONDecoder().decode(NativeJSON.self, from: data) }
        catch { throw NativeClientError.malformedResponse("RPC response") }
        let preference: NativePresencePreference
        if result == .null { preference = defaultPreference }
        else if let value = result.string, let saved = NativePresencePreference(rawValue: value) { preference = saved }
        else { throw NativeClientError.invalidResponse }
        return NativeOwnPresencePreference(ownerID: session.userID, preference: preference)
    }
}
