import Foundation

nonisolated struct NativePollOption: Identifiable, Sendable {
    let id: String
    let text: String
}

nonisolated struct NativePoll: Identifiable, Sendable {
    let id: String
    let messageID: String
    let question: String
    let options: [NativePollOption]
    let multi: Bool
    let quiz: Bool
    let anonymous: Bool
    let closesAt: Date?
    var closed: Bool { closesAt.map { $0 <= Date() } ?? false }

    init(_ row: NativeJSON) throws {
        guard let id = row["id"].string, let messageID = row["message_id"].string,
              let question = row["question"].string, !question.isEmpty else { throw NativeClientError.malformedResponse("Poll identity") }
        self.id = id; self.messageID = messageID; self.question = question
        options = try row["options"].array.map { option in
            guard let id = option["id"].string, let text = option["text"].string else { throw NativeClientError.malformedResponse("Poll option") }
            return NativePollOption(id: id, text: text)
        }
        guard options.count >= 2 else { throw NativeClientError.malformedResponse("Poll options") }
        multi = row["multi"].bool == true; quiz = row["quiz"].bool == true; anonymous = row["anonymous"].bool != false
        closesAt = try row["closes_at"].string.map { try NativeDate.parse($0) }
    }
}

nonisolated struct NativePollTally: Sendable {
    let optionID: String
    let votes: Int
    let mine: Bool

    init?(_ json: NativeJSON) {
        guard let id = json["option_id"].string else { return nil }
        optionID = id
        let n = json["votes"].int ?? Int(json["votes"].string ?? "") ?? 0
        votes = max(0, n); mine = json["mine"].bool == true
    }
}

nonisolated struct NativePollViewState: Sendable {
    let poll: NativePoll
    let results: [NativePollTally]
    let visible: Bool
    let voted: Bool
    let total: Int
    let correct: Set<String>
    let youRight: Bool?
}

extension NativeAPI {
    func pollForMessage(_ messageID: String, session: NativeSession) async throws -> NativePollViewState? {
        let rows = try await table("polls", query: [URLQueryItem(name: "message_id", value: "eq.\(messageID)"), URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "limit", value: "1")], session: session).rows
        guard let row = rows.first else { return nil }
        let poll = try NativePoll(row)
        guard poll.messageID == messageID else { throw NativeClientError.invalidResponse }
        return try await pollState(poll, session: session)
    }

    func pollState(_ poll: NativePoll, session: NativeSession) async throws -> NativePollViewState {
        if poll.quiz {
            let row = try await rpc("poll_view", arguments: ["pid": .string(poll.id)], session: session)
            let visible = row["visible"].bool == true
            return NativePollViewState(poll: poll, results: row["results"].array.compactMap(NativePollTally.init), visible: visible, voted: row["voted"].bool == true,
                                       total: row["total"].int ?? Int(row["total"].string ?? "") ?? 0,
                                       correct: visible ? Set(row["correct"].array.compactMap(\.string)) : [], youRight: visible ? row["you_right"].bool : nil)
        }
        let rows = try await rpc("poll_results", arguments: ["pid": .string(poll.id)], session: session).rows
        let tallies = rows.compactMap(NativePollTally.init)
        return NativePollViewState(poll: poll, results: tallies, visible: true, voted: tallies.contains(where: \.mine), total: tallies.reduce(0) { $0 + $1.votes }, correct: [], youRight: nil)
    }

    func votePoll(_ poll: NativePoll, options: Set<String>, session: NativeSession) async throws -> NativePollViewState {
        guard !poll.closed, options.isSubset(of: Set(poll.options.map(\.id))), poll.multi || options.count <= 1,
              !poll.quiz || !options.isEmpty else { throw NativeClientError.invalidResponse }
        _ = try await rpc(poll.quiz ? "vote_quiz" : "vote_poll", arguments: ["pid": .string(poll.id), "option_ids": .array(options.sorted().map(NativeJSON.string))], session: session)
        return try await pollState(poll, session: session)
    }

    func createPoll(channelID: String, question: String, options: [String], multi: Bool, hours: Int, quiz: Bool, correct: Set<Int>, reveal: String, anonymous: Bool, session: NativeSession) async throws {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !question.isEmpty, question.utf16.count <= 200, (2...10).contains(options.count), options.allSatisfy({ $0.utf16.count <= 80 }),
              [0, 1, 4, 8, 24, 72, 168].contains(hours), ["vote", "close"].contains(reveal),
              !quiz || (!correct.isEmpty && correct.count < options.count && correct.allSatisfy { options.indices.contains($0) } && (reveal != "close" || hours > 0)) else { throw NativeClientError.invalidResponse }
        var args: [String: NativeJSON] = ["cid": .string(channelID), "question": .string(question), "opts": .array(options.map(NativeJSON.string)), "multi": .bool(multi), "hours": .number(Double(hours)), "quiz": .bool(quiz), "correct": .array(quiz ? correct.sorted().map { .string(String($0 + 1)) } : []), "reveal": .string(reveal), "anon": .bool(anonymous)]
        do { _ = try await rpc("create_poll_ex", arguments: args, session: session) }
        catch let NativeClientError.api(status, message) where !quiz && !anonymous && (status == 404 || message.contains("create_poll_ex") || message.contains("PGRST202")) {
            for key in ["quiz", "correct", "reveal", "anon"] { args.removeValue(forKey: key) }
            _ = try await rpc("create_poll", arguments: args, session: session)
        }
    }
}
