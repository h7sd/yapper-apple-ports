import Foundation
import Observation

nonisolated struct NativeConversationPreferenceCapabilities: Equatable, Sendable {
    let hide: Bool
    let pin: Bool
    let timedMute: Bool

    init(flags: NativeJSON, userID: String, joinedServerIDs: Set<String> = []) {
        func enabled(_ key: String) -> Bool {
            let flag = flags.object?[key] ?? flags.array.first(where: { $0["key"].string == key }) ?? .null
            if flag["mode"].string == "everyone" { return true }
            guard flag["mode"].string == "test" else { return false }
            return flag["users"].array.contains(.string(userID)) || !joinedServerIDs.isDisjoint(with: flag["servers"].array.compactMap(\.string))
        }
        hide = enabled("close_dms"); pin = enabled("pin_dms"); timedMute = enabled("quick_notify")
    }
}

nonisolated enum NativeConversationMuteDuration: String, CaseIterable, Identifiable, Sendable {
    case off, fifteenMinutes, oneHour, eightHours, oneDay, forever
    var id: String { rawValue }
    var minutes: Int? {
        switch self { case .off: 0; case .fifteenMinutes: 15; case .oneHour: 60; case .eightHours: 480; case .oneDay: 1440; case .forever: nil }
    }
    var label: String {
        switch self { case .off: "Stummschaltung aufheben"; case .fifteenMinutes: "15 Minuten"; case .oneHour: "1 Stunde"; case .eightHours: "8 Stunden"; case .oneDay: "24 Stunden"; case .forever: "Bis ich sie aufhebe" }
    }
}

nonisolated struct NativeConversationPreferenceSnapshot: Sendable {
    let capabilities: NativeConversationPreferenceCapabilities
    var pins: [String]
    var hidden: Set<String>
    var hiddenAt: [String: Date]
    var muted: Set<String>
    var muteUntil: [String: Date]
}

extension NativeAPI {
    // Official helpers: 2lxxd-jx-9d4l.js (pins), 33-dglfmrlo2q.js (hidden_at,
    // unread_counts_v2/set_muted), 03nx2jt6m1jmz.js (my_notify_settings/mute).
    func nativeConversationPreferences(flags: NativeJSON, conversationIDs: [String], session: NativeSession) async throws -> NativeConversationPreferenceSnapshot {
        try Self.requireConversationPreferenceID(session.userID)
        let ids = try conversationIDs.map { try Self.validatedConversationPreferenceID($0) }
        let testServers = Set(["close_dms", "pin_dms", "quick_notify"].flatMap { key -> [String] in
            let flag = flags.object?[key] ?? flags.array.first(where: { $0["key"].string == key }) ?? .null
            return flag["mode"].string == "test" ? flag["servers"].array.compactMap(\.string) : []
        })
        let joined: Set<String> = testServers.isEmpty ? [] : Set(try await nativeJoinedServerIDs(session: session))
        let capabilities = NativeConversationPreferenceCapabilities(flags: flags, userID: session.userID, joinedServerIDs: joined)
        let pins = capabilities.pin ? try await nativeConversationPins(session: session) : []
        var hidden: Set<String> = []
        var hiddenDates: [String: Date] = [:]
        if capabilities.hide, !ids.isEmpty {
            let memberships = try await table("channel_members", query: [.init(name: "select", value: "channel_id,hidden_at"), .init(name: "user_id", value: "eq." + session.userID)], session: session)
            let channels = try await table("channels", query: [.init(name: "select", value: "id,last_message_at,server_id,kind"), .init(name: "id", value: "in.(" + ids.joined(separator: ",") + ")")], session: session)
            guard case .array = memberships, case .array = channels else { throw NativeClientError.malformedResponse("Conversation visibility") }
            let allowed = Set(ids)
            for row in memberships.array where row["hidden_at"].string != nil {
                guard let id = row["channel_id"].string, allowed.contains(id), let value = row["hidden_at"].string else { continue }
                hiddenDates[id] = try NativeDate.parse(value)
            }
            for row in channels.array {
                guard let id = row["id"].string, allowed.contains(id), row["server_id"] == .null,
                      ["dm", "group"].contains(row["kind"].string ?? "") else { throw NativeClientError.invalidResponse }
                guard let hiddenAt = hiddenDates[id] else { continue }
                let lastMessageAt = try row["last_message_at"].string.map(NativeDate.parse)
                if lastMessageAt.map({ $0 <= hiddenAt }) ?? true { hidden.insert(id) }
            }
        }
        let unread = try await rpc("unread_counts_v2", session: session)
        guard case .array = unread else { throw NativeClientError.malformedResponse("Conversation mute state") }
        var muted = Set(unread.array.compactMap { $0["muted"].bool == true ? $0["channel_id"].string : nil })
        var until: [String: Date] = [:]
        if capabilities.timedMute {
            let notify = try await rpc("my_notify_settings", session: session)
            guard case .array = notify else { throw NativeClientError.malformedResponse("Notification preferences") }
            for row in notify.array {
                guard let id = row["channel_id"].string else { continue }
                try Self.requireConversationPreferenceID(id)
                if row["lifted"].bool == true { muted.remove(id) }
                if let value = row["muted_until"].string { until[id] = try NativeDate.parse(value) }
            }
        }
        return NativeConversationPreferenceSnapshot(capabilities: capabilities, pins: pins, hidden: hidden, hiddenAt: hiddenDates, muted: muted, muteUntil: until)
    }

    func nativeConversationPins(session: NativeSession) async throws -> [String] {
        try Self.requireConversationPreferenceID(session.userID)
        let value = try await table("user_dm_pins", query: [.init(name: "select", value: "pins"), .init(name: "user_id", value: "eq." + session.userID)], session: session)
        guard case .array = value, value.array.count <= 1 else { throw NativeClientError.malformedResponse("Pinned conversations") }
        guard let row = value.array.first else { return [] }
        guard case .array = row["pins"] else { return [] }
        var seen: Set<String> = []
        return Array(row["pins"].array.compactMap(\.string).filter { UUID(uuidString: $0) != nil && $0 == $0.lowercased() && seen.insert($0).inserted }.prefix(50))
    }

    @discardableResult func nativeSetConversationPinned(channelID: String, pinned: Bool, visibleConversationIDs: [String], session: NativeSession) async throws -> [String] {
        try Self.requireConversationPreferenceID(channelID)
        let allowed = Set(try visibleConversationIDs.map { try Self.validatedConversationPreferenceID($0) })
        guard allowed.contains(channelID) else { throw NativeClientError.invalidResponse }
        let previous = try await nativeConversationPins(session: session)
        try Task.checkCancellation()
        var pins = previous.filter { $0 != channelID }
        if pinned {
            pins = pins.filter { allowed.contains($0) }
            guard pins.count < 50 else { throw NativeClientError.api(status: 400, message: "Du kannst höchstens 50 Chats anheften.") }
            pins.insert(channelID, at: 0)
        }
        _ = try await table("user_dm_pins", query: [.init(name: "on_conflict", value: "user_id")], method: "POST", values: .object(["user_id": .string(session.userID), "pins": .array(pins.map(NativeJSON.string))]), session: session, prefer: "resolution=merge-duplicates,return=minimal")
        return pins
    }

    func nativeSetConversationHidden(channelID: String, hidden: Bool, at date: Date = Date(), session: NativeSession) async throws {
        try Self.requireConversationPreferenceID(channelID); try Self.requireConversationPreferenceID(session.userID)
        let value = hidden ? NativeJSON.string(ISO8601DateFormatter().string(from: date)) : .null
        let result = try await table("channel_members", query: [.init(name: "channel_id", value: "eq." + channelID), .init(name: "user_id", value: "eq." + session.userID), .init(name: "select", value: "channel_id,hidden_at")], method: "PATCH", values: .object(["hidden_at": value]), session: session, prefer: "return=representation")
        guard result.rows.count == 1, result.rows[0]["channel_id"].string == channelID,
              hidden ? result.rows[0]["hidden_at"].string != nil : result.rows[0]["hidden_at"] == .null else { throw NativeClientError.api(status: 403, message: "Die Sichtbarkeit dieses Chats konnte nicht geändert werden.") }
    }

    @discardableResult func nativeMuteConversation(channelID: String, duration: NativeConversationMuteDuration, timed: Bool, session: NativeSession) async throws -> Date? {
        try Self.requireConversationPreferenceID(channelID)
        if timed {
            let result = try await rpc("set_notify_mute", arguments: ["cid": .string(channelID), "mins": duration.minutes.map { .number(Double($0)) } ?? .null], session: session)
            if let value = result.string { return try NativeDate.parse(value) }
            guard result == .null, duration == .off || duration == .forever else { throw NativeClientError.malformedResponse("Mute expiry") }
            return nil
        }
        guard duration == .off || duration == .forever else { throw NativeClientError.invalidResponse }
        _ = try await rpc("set_muted", arguments: ["cid": .string(channelID), "mute": .bool(duration != .off)], session: session)
        return nil
    }

    private static func requireConversationPreferenceID(_ id: String) throws {
        guard UUID(uuidString: id) != nil, id == id.lowercased() else { throw NativeClientError.invalidResponse }
    }
    private static func validatedConversationPreferenceID(_ id: String) throws -> String { try requireConversationPreferenceID(id); return id }
}

@MainActor @Observable final class NativeConversationPreferenceModel {
    private(set) var snapshot: NativeConversationPreferenceSnapshot?
    private(set) var isLoading = false
    private(set) var isBusy = false
    var error: String?
    private var revision = UUID()
    private var ownerID: String?

    func ordered(_ conversations: [Conversation]) -> [Conversation] {
        let ranks = Dictionary(uniqueKeysWithValues: (snapshot?.pins ?? []).enumerated().map { ($0.element, $0.offset) })
        return conversations.enumerated().filter { item in
            guard snapshot?.hidden.contains(item.element.id) == true else { return true }
            guard let hiddenAt = snapshot?.hiddenAt[item.element.id], let activity = item.element.lastMessageAt else { return false }
            return activity > hiddenAt
        }.sorted {
            let lhs = ranks[$0.element.id] ?? Int.max, rhs = ranks[$1.element.id] ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    func isMuted(_ id: String, at date: Date = Date()) -> Bool {
        guard snapshot?.muted.contains(id) == true else { return false }
        return snapshot?.muteUntil[id].map { $0 > date } ?? true
    }

    func revealOpenedConversation(_ id: String) {
        snapshot?.hidden.remove(id)
        snapshot?.hiddenAt.removeValue(forKey: id)
    }

    func load(store: NativeStore) async {
        let current = UUID(); revision = current
        if ownerID != store.user?.id { snapshot = nil; error = nil; ownerID = store.user?.id }
        guard let userID = store.user?.id, store.authState == .signedIn else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { return }
        #endif
        isLoading = true; error = nil
        defer { if current == revision { isLoading = false } }
        do {
            let flags = store.capabilities.flags, ids = store.conversations.filter { $0.serverID == nil }.map(\.id)
            let value = try await store.withAuthenticatedSession { api, session in try await api.nativeConversationPreferences(flags: flags, conversationIDs: ids, session: session) }
            guard current == revision, userID == store.user?.id else { return }; snapshot = value
        } catch is CancellationError { }
        catch { if current == revision { self.error = error.localizedDescription } }
    }

    @discardableResult func pin(_ conversation: Conversation, store: NativeStore) async -> Bool {
        await perform(store: store) {
            guard let snapshot = self.snapshot, snapshot.capabilities.pin else { throw NativeClientError.invalidResponse }
            let pin = !snapshot.pins.contains(conversation.id), ids = store.conversations.filter { $0.serverID == nil && !snapshot.hidden.contains($0.id) }.map(\.id)
            let pins = try await store.withAuthenticatedSession { api, session in try await api.nativeSetConversationPinned(channelID: conversation.id, pinned: pin, visibleConversationIDs: ids, session: session) }
            self.snapshot?.pins = pins
        }
    }

    @discardableResult func mute(_ conversation: Conversation, duration: NativeConversationMuteDuration, store: NativeStore) async -> Bool {
        await perform(store: store) {
            guard let snapshot = self.snapshot else { throw NativeClientError.invalidResponse }
            let until = try await store.withAuthenticatedSession { api, session in try await api.nativeMuteConversation(channelID: conversation.id, duration: duration, timed: snapshot.capabilities.timedMute, session: session) }
            if duration == .off { self.snapshot?.muted.remove(conversation.id) } else { self.snapshot?.muted.insert(conversation.id) }
            self.snapshot?.muteUntil[conversation.id] = until
        }
    }

    @discardableResult func hide(_ conversation: Conversation, store: NativeStore) async -> Bool {
        await perform(store: store) {
            guard let snapshot = self.snapshot, snapshot.capabilities.hide else { throw NativeClientError.invalidResponse }
            let hiddenAt = Date()
            try await store.withAuthenticatedSession { api, session in try await api.nativeSetConversationHidden(channelID: conversation.id, hidden: true, at: hiddenAt, session: session) }
            self.snapshot?.hidden.insert(conversation.id)
            self.snapshot?.hiddenAt[conversation.id] = hiddenAt
            // The website also removes hidden chats from pins. Keep a failed unpin visible as
            // an error while retaining the already-confirmed hidden state.
            if snapshot.pins.contains(conversation.id) {
                let ids = store.conversations.filter { $0.serverID == nil }.map(\.id)
                let pins = try await store.withAuthenticatedSession { api, session in try await api.nativeSetConversationPinned(channelID: conversation.id, pinned: false, visibleConversationIDs: ids, session: session) }
                self.snapshot?.pins = pins
            }
        }
    }

    private func perform(store: NativeStore, _ operation: @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy, ownerID == store.user?.id, store.authState == .signedIn else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") { error = "Die synthetische Vorschau ist schreibgeschützt."; return false }
        #endif
        isBusy = true; error = nil
        revision = UUID(); isLoading = false
        defer { isBusy = false }
        do { try await operation(); return true }
        catch is CancellationError { return false }
        catch { self.error = error.localizedDescription; return false }
    }
}
