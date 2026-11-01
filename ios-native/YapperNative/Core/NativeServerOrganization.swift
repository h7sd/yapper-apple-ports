import Foundation
import Observation

nonisolated struct NativeServerFolder: Identifiable, Equatable, Sendable {
    let id: String
    var name: String?
    var color: String?
    var servers: [String]
    var wire: NativeJSON { .object(["id": .string(id), "name": name.map(NativeJSON.string) ?? .null, "color": color.map(NativeJSON.string) ?? .null, "servers": .array(servers.map(NativeJSON.string))]) }
}

nonisolated struct NativeServerOrganizationItem: Identifiable, Equatable, Sendable {
    let id: String
    var folder: NativeServerFolder?
    var serverIDs: [String] { folder?.servers ?? [id] }
    static func server(_ id: String) -> Self { Self(id: id, folder: nil) }
    static func group(_ folder: NativeServerFolder) -> Self { Self(id: "f:" + folder.id, folder: folder) }
}

nonisolated struct NativeServerOrganization: Equatable, Sendable {
    let folders: [NativeServerFolder]
    let order: [String]

    func items(serverIDs: [String]) -> [NativeServerOrganizationItem] {
        let known = Set(serverIDs)
        var emitted: Set<String> = [], assigned: Set<String> = []
        var byServer: [String: NativeServerFolder] = [:]
        for folder in folders {
            let ids = folder.servers.filter { known.contains($0) && assigned.insert($0).inserted }
            guard ids.count >= 2 else { assigned.subtract(ids); continue }
            var group = folder; group.servers = ids
            for id in ids { byServer[id] = group }
        }
        let sorted = order.filter { known.contains($0) } + serverIDs.filter { !order.contains($0) }
        return sorted.compactMap { id in
            if let folder = byServer[id] { return emitted.insert("f:" + folder.id).inserted ? .group(folder) : nil }
            return emitted.insert(id).inserted ? .server(id) : nil
        }
    }

    static func decodeFolders(_ value: NativeJSON) -> [NativeServerFolder] {
        var assigned: Set<String> = []
        return value.array.prefix(50).compactMap { row in
            guard let id = row["id"].string, !id.isEmpty, id.utf8.count <= 120 else { return nil }
            let ids = row["servers"].array.compactMap(\.string).filter { UUID(uuidString: $0) != nil && $0 == $0.lowercased() && assigned.insert($0).inserted }
            guard !ids.isEmpty else { return nil }
            let name = row["name"].string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(String.UnicodeScalarView($0.unicodeScalars.prefix(32))) }
            let color = row["color"].string.flatMap { $0.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil ? $0 : nil }
            return NativeServerFolder(id: id, name: name, color: color, servers: Array(ids.prefix(100)))
        }
    }

    static func validate(_ items: [NativeServerOrganizationItem], knownServerIDs: [String]) throws -> Self {
        let ids = items.flatMap(\.serverIDs), known = Set(knownServerIDs)
        guard ids.count == Set(ids).count, Set(ids) == known,
              ids.allSatisfy({ UUID(uuidString: $0) != nil && $0 == $0.lowercased() }) else { throw NativeClientError.invalidResponse }
        let folders = items.compactMap(\.folder)
        guard folders.count <= 50, Set(folders.map(\.id)).count == folders.count else { throw NativeClientError.invalidResponse }
        for folder in folders {
            guard !folder.id.isEmpty, folder.id.utf8.count <= 120, (2...100).contains(folder.servers.count),
                  folder.name.map({ $0.unicodeScalars.count <= 32 }) ?? true,
                  folder.color.map({ $0.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil }) ?? true else { throw NativeClientError.invalidResponse }
        }
        return Self(folders: folders, order: ids)
    }
}

extension NativeAPI {
    func nativeServerOrganization(foldersEnabled: Bool, session: NativeSession) async throws -> NativeServerOrganization {
        try Self.serverOrganizationID(session.userID)
        let profile = try await table("profiles", query: [.init(name: "select", value: "id,server_order"), .init(name: "id", value: "eq." + session.userID)], session: session)
        guard profile.rows.count == 1, profile.rows[0]["id"].string == session.userID else { throw NativeClientError.invalidResponse }
        var seen: Set<String> = []
        let order = profile.rows[0]["server_order"].array.compactMap(\.string).filter { UUID(uuidString: $0) != nil && seen.insert($0).inserted }
        guard foldersEnabled else { return NativeServerOrganization(folders: [], order: order) }
        let rows = try await table("user_server_folders", query: [.init(name: "select", value: "folders"), .init(name: "user_id", value: "eq." + session.userID)], session: session)
        guard case .array = rows, rows.array.count <= 1 else { throw NativeClientError.invalidResponse }
        return NativeServerOrganization(folders: NativeServerOrganization.decodeFolders(rows.array.first?["folders"] ?? .null), order: order)
    }

    func nativeSaveServerOrganization(_ items: [NativeServerOrganizationItem], knownServerIDs: [String], previous: NativeServerOrganization, foldersEnabled: Bool, session: NativeSession) async throws -> NativeServerOrganization {
        try Self.serverOrganizationID(session.userID)
        let value = try NativeServerOrganization.validate(items, knownServerIDs: knownServerIDs)
        guard foldersEnabled || value.folders.isEmpty else { throw NativeClientError.invalidResponse }
        if foldersEnabled { try await nativeWriteServerFolders(value.folders, session: session) }
        do {
            try Task.checkCancellation()
            let rows = try await table("profiles", query: [.init(name: "id", value: "eq." + session.userID), .init(name: "select", value: "id")], method: "PATCH", values: .object(["server_order": .array(value.order.map(NativeJSON.string))]), session: session, prefer: "return=representation")
            guard rows.rows.count == 1, rows.rows[0]["id"].string == session.userID else { throw NativeClientError.api(status: 403, message: "Die Serverreihenfolge konnte nicht gespeichert werden.") }
            return value
        } catch {
            // Same compensating folder rollback as the upstream two-write flow.
            if foldersEnabled { try? await nativeWriteServerFolders(previous.folders, session: session) }
            throw error
        }
    }

    private func nativeWriteServerFolders(_ folders: [NativeServerFolder], session: NativeSession) async throws {
        _ = try await table("user_server_folders", method: "POST", values: .object(["user_id": .string(session.userID), "folders": .array(folders.map(\.wire))]), session: session, prefer: "resolution=merge-duplicates,return=minimal")
    }

    private static func serverOrganizationID(_ id: String) throws { guard UUID(uuidString: id) != nil else { throw NativeClientError.invalidResponse } }
}

@MainActor @Observable final class NativeServerOrganizationModel {
    private(set) var value = NativeServerOrganization(folders: [], order: [])
    private(set) var isBusy = false
    private(set) var isLoaded = false
    var error: String?
    private var revision = UUID()
    private var ownerID: String?

    func load(store: NativeStore, servers: [NativeServer], readOnly: Bool) async {
        let current = UUID(); revision = current
        if ownerID != store.user?.id { value = NativeServerOrganization(folders: [], order: []); ownerID = store.user?.id }
        isLoaded = false
        guard !readOnly else { value = NativeServerOrganization(folders: [], order: servers.map(\.id)); isLoaded = true; return }
        do {
            let enabled = store.capabilities.flagOn("server_folders", userID: store.user?.id)
            let next = try await store.withAuthenticatedSession { api, session in try await api.nativeServerOrganization(foldersEnabled: enabled, session: session) }
            guard revision == current else { return }; value = next; error = nil; isLoaded = true
        } catch is CancellationError { } catch { if revision == current { self.error = error.localizedDescription } }
    }

    func save(_ items: [NativeServerOrganizationItem], store: NativeStore, servers: [NativeServer], readOnly: Bool) async -> Bool {
        guard !readOnly, !isBusy, isLoaded, ownerID == store.user?.id else { return false }
        isBusy = true; error = nil; revision = UUID()
        defer { isBusy = false }
        do {
            let old = value, ids = servers.map(\.id), enabled = store.capabilities.flagOn("server_folders", userID: store.user?.id)
            value = try await store.withAuthenticatedSession { api, session in try await api.nativeSaveServerOrganization(items, knownServerIDs: ids, previous: old, foldersEnabled: enabled, session: session) }
            return true
        } catch is CancellationError { return false } catch { self.error = error.localizedDescription; return false }
    }
}

nonisolated enum NativeServerNotificationLevel: String, CaseIterable, Identifiable, Sendable {
    case all, mentions, none
    var id: String { rawValue }
    var label: String { switch self { case .all: "Alle Nachrichten"; case .mentions: "Nur Erwähnungen"; case .none: "Keine Benachrichtigungen" } }
}

nonisolated enum NativeServerNotificationTarget: Hashable, Sendable {
    case server(String), channel(serverID: String, channelID: String), category(serverID: String, categoryID: String)
    var serverID: String { switch self { case let .server(id), let .channel(id, _), let .category(id, _): id } }
    var key: String { switch self { case let .server(id), let .channel(_, id), let .category(_, id): id } }
}

nonisolated struct NativeServerNotificationState: Sendable {
    var levels: [String: NativeServerNotificationLevel] = [:]
    var muted: Set<String> = []
    var until: [String: Date] = [:]
    func isMuted(_ id: String, now: Date = Date()) -> Bool { muted.contains(id) && (until[id].map { $0 > now } ?? true) }
}

extension NativeAPI {
    func nativeCloseServerTicket(channel: NativeServerChannel, session: NativeSession) async throws {
        guard channel.kind == "text", let owner = channel.ticketBy,
              UUID(uuidString: owner) != nil, UUID(uuidString: channel.id) != nil else { throw NativeClientError.invalidResponse }
        _ = try await rpc("close_ticket", arguments: ["cid": .string(channel.id)], session: session)
    }

    func nativeServerNotificationState(session: NativeSession) async throws -> NativeServerNotificationState {
        let settings = try await rpc("my_notify_settings", session: session)
        let servers = try await table("server_mutes", query: [.init(name: "select", value: "server_id,muted_until")], session: session)
        let unread = try await rpc("unread_counts_v2", session: session)
        guard case .array = settings, case .array = servers, case .array = unread else { throw NativeClientError.invalidResponse }
        var state = NativeServerNotificationState()
        for row in unread.array where row["muted"].bool == true { if let id = row["channel_id"].string { state.muted.insert(id) } }
        for row in servers.array {
            guard let id = row["server_id"].string else { throw NativeClientError.invalidResponse }
            state.muted.insert(id)
            if let value = row["muted_until"].string { state.until[id] = try NativeDate.parse(value) }
        }
        for row in settings.array {
            guard let id = row["channel_id"].string ?? row["server_id"].string else { throw NativeClientError.invalidResponse }
            if let level = row["level"].string { guard let parsed = NativeServerNotificationLevel(rawValue: level) else { throw NativeClientError.invalidResponse }; state.levels[id] = parsed }
            if let value = row["muted_until"].string { state.until[id] = try NativeDate.parse(value) }
            if row["lifted"].bool == true { state.muted.remove(id) }
        }
        return state
    }

    func nativeSetServerNotificationLevel(_ level: NativeServerNotificationLevel?, target: NativeServerNotificationTarget, session: NativeSession) async throws {
        try Self.validateNotificationTarget(target)
        let value = level.map { NativeJSON.string($0.rawValue) } ?? .null
        switch target {
        case let .category(_, category): _ = try await rpc("set_category_level", arguments: ["cat": .string(category), "lvl": value], session: session)
        case let .server(server):
            guard level != nil else { throw NativeClientError.invalidResponse }
            _ = try await rpc("set_notify_level", arguments: ["sid": .string(server), "cid": .null, "lvl": value], session: session)
        case let .channel(server, channel): _ = try await rpc("set_notify_level", arguments: ["sid": .string(server), "cid": .string(channel), "lvl": value], session: session)
        }
    }

    func nativeMuteServerNotifications(_ duration: NativeConversationMuteDuration, target: NativeServerNotificationTarget, session: NativeSession) async throws {
        try Self.validateNotificationTarget(target)
        let minutes = duration.minutes.map { NativeJSON.number(Double($0)) } ?? .null
        switch target {
        case let .server(id): _ = try await rpc("set_server_mute", arguments: ["sid": .string(id), "mins": minutes], session: session)
        case let .channel(_, id): _ = try await rpc("set_notify_mute", arguments: ["cid": .string(id), "mins": minutes], session: session)
        case let .category(_, id): _ = try await rpc("set_category_mute", arguments: ["cat": .string(id), "mins": minutes], session: session)
        }
    }

    private static func validateNotificationTarget(_ target: NativeServerNotificationTarget) throws {
        guard UUID(uuidString: target.serverID) != nil, UUID(uuidString: target.key) != nil else { throw NativeClientError.invalidResponse }
    }
}
