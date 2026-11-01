import Foundation

/// Current official module4421: server/category/channel rules, read-only post roles and threads.
nonisolated struct NativeChannelOverride: Equatable, Sendable {
    let channelID: String?
    let categoryID: String?
    let roleID: String?
    let allow: Set<String>
    let deny: Set<String>

    init(_ row: NativeJSON, serverID: String) throws {
        guard row["server_id"].string == serverID else { throw NativeClientError.invalidResponse }
        channelID = row["channel_id"].string; categoryID = row["category_id"].string; roleID = row["role_id"].string
        guard (channelID == nil) != (categoryID == nil),
              [channelID, categoryID, roleID].compactMap({ $0 }).allSatisfy({ UUID(uuidString: $0) != nil }),
              case .array = row["allow"], case .array = row["deny"],
              row["allow"].array.allSatisfy({ $0.string != nil }), row["deny"].array.allSatisfy({ $0.string != nil }) else { throw NativeClientError.invalidResponse }
        allow = Set(row["allow"].array.compactMap(\.string)); deny = Set(row["deny"].array.compactMap(\.string))
    }
}

nonisolated struct NativeChannelPostingAccess: Equatable, Sendable {
    let canSend: Bool
    let reason: String?
    static let allowed = Self(canSend: true, reason: nil)
    static func denied(_ reason: String) -> Self { Self(canSend: false, reason: reason) }
}

extension NativeServerSnapshot {
    /// Automatic roles affect appearance and channel overrides, never server management privileges.
    func roleIDs(for userID: String) -> Set<String> {
        var assigned = memberRoles[userID] ?? []
        guard let member = members.first(where: { $0.id == userID }) else { return assigned }
        let joined = member.joinedAt.flatMap { try? NativeDate.parse($0) }
        for role in roles {
            if role.auto == "all" { assigned.insert(role.id) }
            else if role.auto == "before", let joined,
                    let cutoff = role.autoBefore.flatMap({ try? NativeDate.parse($0) }), joined < cutoff { assigned.insert(role.id) }
        }
        return assigned
    }

    func colorRole(userID: String) -> NativeServerRole? {
        let assigned = roleIDs(for: userID)
        return roles.filter { role in
            guard assigned.contains(role.id), let color = role.color, !color.isEmpty else { return false }
            return color.lowercased() != "#000000" || role.color2?.isEmpty == false
        }.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position > $1.position }.first
    }

    func nameColor(userID: String) -> String? { colorRole(userID: userID)?.color }

    func includingChannel(_ channel: NativeServerChannel) -> NativeServerSnapshot {
        guard channel.serverID == server.id else { return self }
        return NativeServerSnapshot(server: server, channels: channels.filter { $0.id != channel.id } + [channel], categories: categories,
                                    members: members, roles: roles, memberRoles: memberRoles, channelOverrides: channelOverrides, overridesLoaded: overridesLoaded)
    }

    func includingMembers(_ additional: [NativeServerMember], memberRoles additionalRoles: [String: Set<String>] = [:]) -> NativeServerSnapshot {
        let added = Set(additional.map(\.id))
        let updatedRoles = memberRoles.merging(additionalRoles) { _, new in new }
        return NativeServerSnapshot(server: server, channels: channels, categories: categories,
                                    members: members.filter { !added.contains($0.id) } + additional,
                                    roles: roles, memberRoles: updatedRoles, channelOverrides: channelOverrides, overridesLoaded: overridesLoaded)
    }

    func canCreateForumPost(channelID: String, userID: String?, capabilities: NativeCapabilities) -> Bool {
        guard let userID, let channel = channels.first(where: { $0.id == channelID && $0.kind == "forum" }),
              hasChannelPermission("view_channel", channelID: channelID, userID: userID, capabilities: capabilities),
              hasChannelPermission("send_messages", channelID: channelID, userID: userID, capabilities: capabilities),
              hasChannelPermission("create_threads", channelID: channelID, userID: userID, capabilities: capabilities) else { return false }
        return !channel.readOnly || hasPermission("manage_server", userID: userID) || !roleIDs(for: userID).isDisjoint(with: channel.postRoles)
    }

    private func permissionChannel(_ channel: NativeServerChannel) -> NativeServerChannel? {
        guard channel.serverID == server.id else { return nil }
        if channel.kind == "thread" {
            guard let parentID = channel.parentID,
                  let parent = channels.first(where: { $0.id == parentID }), parent.kind != "thread" else { return nil }
            return parent
        }
        return channel
    }

    private func administrator(_ userID: String) -> Bool {
        server.ownerID == userID || roles.contains { role in
            (memberRoles[userID]?.contains(role.id) == true) && role.auto == "none" && role.permissions["administrator"] == true
        }
    }

    private func applying(_ base: Bool, rules: [NativeChannelOverride], assigned: Set<String>, permission: String) -> Bool {
        var allowed = base
        if let everyone = rules.first(where: { $0.roleID == nil }) {
            if everyone.deny.contains(permission) { allowed = false }
            if everyone.allow.contains(permission) { allowed = true }
        }
        let matching = rules.filter { $0.roleID.map(assigned.contains) == true }
        if matching.contains(where: { $0.deny.contains(permission) }) { allowed = false }
        if matching.contains(where: { $0.allow.contains(permission) }) { allowed = true }
        return allowed
    }

    func hasChannelPermission(_ permission: String, channelID: String, userID: String?, capabilities: NativeCapabilities) -> Bool {
        guard let userID, let channel = channels.first(where: { $0.id == channelID }),
              let effective = permissionChannel(channel) else { return false }
        if administrator(userID) { return true }
        let enabled = capabilities.flagOn("channel_perms", userID: userID, serverID: server.id)
        guard !enabled || overridesLoaded else { return false }
        let assigned = roleIDs(for: userID)
        var allowed = permission == "view_channel"
            ? (!effective.isPrivate || !effective.allowedRoles.isDisjoint(with: assigned) || hasPermission("manage_server", userID: userID))
            : hasPermission(permission, userID: userID)
        if enabled {
            if let category = effective.categoryID {
                allowed = applying(allowed, rules: channelOverrides.filter { $0.categoryID == category }, assigned: assigned, permission: permission)
            }
            allowed = applying(allowed, rules: channelOverrides.filter { $0.channelID == effective.id }, assigned: assigned, permission: permission)
        }
        return allowed
    }

    func postingAccess(channelID: String, userID: String?, capabilities: NativeCapabilities, now: Date = Date()) -> NativeChannelPostingAccess {
        guard let userID, let channel = channels.first(where: { $0.id == channelID }),
              let effective = permissionChannel(channel) else { return .denied("Die Kanalberechtigungen werden noch geprüft.") }
        if channel.kind == "voice", !capabilities.flagOn("voice_chat", userID: userID, serverID: server.id) {
            return .denied("Dies ist ein Sprachkanal. Tritt dem Anruf über die Kanalliste bei.")
        }
        if channel.kind == "voice", !hasChannelPermission("connect", channelID: channelID, userID: userID, capabilities: capabilities) {
            return .denied("Du darfst diesem Sprachkanal nicht beitreten.")
        }
        if channel.kind == "forum" { return .denied("Erstelle in diesem Forum einen Beitrag, um zu schreiben.") }
        if capabilities.flagOn("channel_perms", userID: userID, serverID: server.id), !overridesLoaded, !administrator(userID) {
            return .denied("Die Kanalberechtigungen konnten noch nicht vollständig geladen werden.")
        }
        guard hasChannelPermission("view_channel", channelID: channelID, userID: userID, capabilities: capabilities) else {
            return .denied("Du hast keinen Zugriff auf diesen Kanal.")
        }
        let managesMessages = hasChannelPermission("manage_messages", channelID: channelID, userID: userID, capabilities: capabilities)
        if let until = server.raw["locked_until"].string.flatMap({ try? NativeDate.parse($0) }), until > now, !managesMessages {
            return .denied("Dieser Server ist vorübergehend für neue Nachrichten gesperrt.")
        }
        if channel.kind == "thread" {
            guard hasChannelPermission("send_in_threads", channelID: channelID, userID: userID, capabilities: capabilities) else {
                return .denied("Du darfst in diesem Thread keine Nachrichten senden.")
            }
            let managesThread = hasChannelPermission("manage_threads", channelID: channelID, userID: userID, capabilities: capabilities)
                || managesMessages || hasPermission("manage_channels", userID: userID)
            if channel.locked && !managesThread { return .denied("Dieser Thread ist gesperrt.") }
        }
        guard hasChannelPermission("send_messages", channelID: channelID, userID: userID, capabilities: capabilities) else {
            return .denied("Du darfst in diesem Kanal keine Nachrichten senden.")
        }
        if capabilities.flagOn("rules_channel", userID: userID, serverID: server.id), server.raw["rules_channel_id"].string == effective.id,
           !hasPermission("manage_server", userID: userID) { return .denied("Dieser Regelkanal ist schreibgeschützt.") }
        if effective.readOnly, !hasPermission("manage_server", userID: userID), roleIDs(for: userID).isDisjoint(with: effective.postRoles) {
            return .denied("Dieser Kanal ist für deine Rollen schreibgeschützt.")
        }
        return .allowed
    }
}
