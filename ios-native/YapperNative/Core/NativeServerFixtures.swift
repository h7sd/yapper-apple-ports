#if DEBUG
import Foundation

/// Synthetic, read-only data for explicit UI-test launches. Never included in Release.
nonisolated enum NativeServerFixtures {
    static let serverID = "66666666-6666-4666-8666-666666666666"
    static let textChannelID = "77777777-7777-4777-8777-777777777777"
    static let voiceChannelID = "88888888-8888-4888-8888-888888888888"
    static let forumChannelID = "99999999-9999-4999-8999-999999999999"
    static let readOnlyChannelID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    static let privateChannelID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    static let selfID = "11111111-1111-4111-8111-111111111111"
    static let novaID = "33333333-3333-4333-8333-333333333333"
    private static let categoryID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private static let roleID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    static func isEnabled(userID: String?) -> Bool {
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures") && userID == selfID
    }

    static func server() throws -> NativeServer {
        try NativeServer(.object([
            "id": .string(serverID), "name": .string("Demo Community"),
            "owner_id": .string(novaID), "member_count": .number(3),
            "description": .string("Synthetische UI-Vorschau · nur Lesen · keine Serververbindung"),
            "discoverable": .bool(false), "tags": .array([.string("Demo")]),
            "everyone_perms": .object(["create_invite": .bool(false)])
        ]))
    }

    static func snapshot() throws -> NativeServerSnapshot {
        let channels = try [
            (textChannelID, "allgemein", "text"),
            (readOnlyChannelID, "Ankündigungen", "text"),
            (privateChannelID, "Team", "text"),
            (voiceChannelID, "Lounge", "voice"),
            (forumChannelID, "Ideen", "forum")
        ].enumerated().map { index, item in
            try NativeServerChannel(.object([
                "id": .string(item.0), "server_id": .string(serverID),
                "name": .string(item.1), "kind": .string(item.2),
                "category_id": .string(categoryID), "position": .number(Double(index)),
                "created_at": .string("2026-10-31T12:00:00Z"),
                "read_only": .bool(item.0 == readOnlyChannelID),
                "private": .bool(item.0 == privateChannelID),
                "allowedRoles": item.0 == privateChannelID ? .array([.string(roleID)]) : .array([]),
                "forum_tags": item.2 == "forum" ? .array([.object(["id": .string("idea"), "name": .string("Idee"), "mod_only": .bool(false)])]) : .array([])
            ]), serverID: serverID)
        }
        let category = try NativeServerCategory(.object([
            "id": .string(categoryID), "server_id": .string(serverID),
            "name": .string("Community"), "position": .number(0)
        ]), serverID: serverID)
        let role = try NativeServerRole(.object([
            "id": .string(roleID), "server_id": .string(serverID),
            "name": .string("Moderation"), "position": .number(10), "auto": .string("none"),
            "color": .string("#F15970"),
            "perms": .object(["manage_messages": .bool(true), "timeout_members": .bool(true)])
        ]), serverID: serverID)
        let members = [
            NativeServerMember(user: YapperUser(id: selfID, username: "yapper-demo", displayName: "Yapper Demo", presence: "online"), nickname: nil, joinedAt: "2026-10-01T12:00:00Z"),
            NativeServerMember(user: YapperUser(id: novaID, username: "nova", displayName: "Nova", presence: "online"), nickname: nil, joinedAt: "2026-10-02T12:00:00Z"),
            NativeServerMember(user: YapperUser(id: "44444444-4444-4444-8444-444444444444", username: "milo", displayName: "Milo", presence: "idle"), nickname: nil, joinedAt: "2026-10-03T12:00:00Z")
        ]
        return NativeServerSnapshot(server: try server(), channels: channels, categories: [category], members: members, roles: [role], memberRoles: [novaID: [roleID], selfID: [roleID]])
    }
}
#endif
