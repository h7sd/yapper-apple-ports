import Foundation

nonisolated struct NativePollVoter: Identifiable, Sendable {
    let userID: String
    let votedAt: String
    var profile: NativeProfileDetail?
    var id: String { userID }

    init(_ row: NativeJSON) throws {
        guard let user = row["user_id"].string, UUID(uuidString: user) != nil,
              let date = row["voted_at"].string, (try? NativeDate.parse(date)) != nil else { throw NativeClientError.malformedResponse("Poll voter") }
        userID = user; votedAt = date
    }
}

extension NativeAPI {
    /// The shipped roster is public only for non-anonymous polls in the quiz_polls rollout.
    func pollVoters(state: NativePollViewState, optionID: String, before: NativePollVoter? = nil, capabilities: NativeCapabilities, serverID: String?, session: NativeSession) async throws -> [NativePollVoter] {
        guard !state.poll.anonymous, state.visible,
              capabilities.flagOn("quiz_polls", userID: session.userID, serverID: serverID),
              state.poll.options.contains(where: { $0.id == optionID }) else { throw NativeClientError.api(status: 403, message: "Die Abstimmenden dieser Umfrage sind nicht sichtbar.") }
        let fresh = try await pollState(state.poll, session: session)
        guard fresh.visible else { throw NativeClientError.api(status: 403, message: "Das Ergebnis ist noch nicht sichtbar.") }
        let rows = try await rpc("poll_voters", arguments: ["pid": .string(state.poll.id), "opt": .string(optionID), "before_at": before.map { .string($0.votedAt) } ?? .null, "before_uid": before.map { .string($0.userID) } ?? .null, "lim": .number(50)], session: session)
        guard case .array = rows, rows.array.count <= 50 else { throw NativeClientError.invalidResponse }
        var voters = try rows.array.map(NativePollVoter.init)
        let profiles = try await socialProfiles(ids: voters.map(\.userID), session: session)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for index in voters.indices { voters[index].profile = byID[voters[index].userID] }
        return voters
    }
}
