import SwiftUI

enum NativeRecentUnreadRail {
    /// Caller supplies visible chats after the observed hidden_at/revival policy.
    static func select(_ visible: [Conversation], activeID: String?, mutedIDs: Set<String>, at now: Date = Date()) -> [Conversation] {
        let cutoff = now.addingTimeInterval(-86_400)
        return Array(visible.enumerated().filter { _, conversation in
            conversation.serverID == nil && conversation.id != activeID && conversation.unreadCount > 0
                && !mutedIDs.contains(conversation.id) && conversation.lastMessageAt.map { $0 >= cutoff } == true
        }.sorted {
            let left = $0.element.lastMessageAt ?? .distantPast, right = $1.element.lastMessageAt ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.prefix(4).map(\.element))
    }
}

/// Geometry and spacing mirror .rail/.chat-row/.user-bar/.nl-tabbar in the shipped CSS.
struct NativeOriginalRail: View {
    let servers: [NativeServer]
    let recentConversations: [Conversation]
    let selectedServerID: String?
    let compact: Bool
    let unread: Int
    let showDiscovery: Bool
    let onHome: () -> Void
    let onServer: (NativeServer) -> Void
    let onConversation: (Conversation) -> Void
    let onAdd: () -> Void
    let onDiscover: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                railItem(selected: selectedServerID == nil, badge: unread, label: "Home", action: onHome) {
                    Image("AppMark").resizable().scaledToFit()
                }
                ForEach(recentConversations) { conversation in
                    railItem(selected: false, badge: conversation.unreadCount, label: "Ungelesene Nachrichten von \(conversation.title)", action: { onConversation(conversation) }) {
                        NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id ?? conversation.id,
                                     username: conversation.participants.first?.username ?? conversation.title, url: conversation.avatarURL, size: compact ? 46 : 48)
                    }.accessibilityIdentifier("native.rail.dm.\(conversation.id)")
                }
                Rectangle().fill(YapperPalette.active).frame(width: 32, height: 2).padding(.vertical, 2)
                ForEach(servers) { server in
                    railItem(selected: selectedServerID == server.id, badge: 0, label: server.name, action: { onServer(server) }) {
                        if server.iconURL != nil { NativeAvatar(name: server.name, url: server.iconURL, size: compact ? 46 : 48) }
                        else { Text(server.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()).font(OriginalYapper.fixedFont(16, numericWeight: 700)) }
                    }
                    .accessibilityIdentifier("native.server.\(server.id)")
                }
                railItem(selected: false, badge: 0, label: "Server hinzufügen", action: onAdd) { OriginalYapperIcon("plus", size: 24).foregroundStyle(YapperPalette.success) }
                if showDiscovery { railItem(selected: false, badge: 0, label: "Server entdecken", action: onDiscover) { OriginalYapperIcon("compass", size: 24).foregroundStyle(YapperPalette.success) } }
            }
            .padding(.top, compact ? 10 : 12)
            .padding(.bottom, compact ? 10 : 90)
        }
        .scrollIndicators(.hidden)
        .frame(width: compact ? 64 : 72)
        .background(YapperPalette.rail.ignoresSafeArea(.container, edges: .top))
        .accessibilityIdentifier("native.original.rail")
    }

    private func railItem<Content: View>(selected: Bool, badge: Int, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                content()
                    .frame(width: compact ? 46 : 48, height: compact ? 46 : 48)
                    .background(selected ? YapperPalette.accentFill : YapperPalette.elevated)
                    .clipShape(.rect(cornerRadius: selected ? 16 : 24))
                if badge > 0 { NativeOriginalBadge(count: badge).offset(x: 2, y: 2) }
            }
            .frame(width: compact ? 64 : 72, height: compact ? 46 : 48)
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(YapperPalette.text).frame(width: 4, height: 36).offset(x: -2) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct NativeOriginalBadge: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(OriginalYapper.font(11, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
            .background(YapperPalette.danger, in: .capsule)
    }
}

struct NativeOriginalBottomBar: View {
    let unread: Int
    let serverSelected: Bool
    let serversAvailable: Bool
    let onHome: () -> Void
    let onServers: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            tab("Home", glyph: "home", selected: !serverSelected, badge: unread, action: onHome)
            tab("Server", glyph: "servers", selected: serverSelected, badge: 0, action: onServers).disabled(!serversAvailable)
            tab("Einstellungen", glyph: "settings", selected: false, badge: 0, action: onSettings).accessibilityIdentifier("native.settings")
        }
        .padding(.horizontal, 6)
        .frame(height: 56)
        .background(YapperPalette.rail.ignoresSafeArea(.container, edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(YapperPalette.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.app.tabs")
        .accessibilityElement(children: .contain)
    }

    private func tab(_ title: String, glyph: String, selected: Bool, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                OriginalYapperIcon(glyph, size: 24)
                    .overlay(alignment: .topTrailing) { if badge > 0 { NativeOriginalBadge(count: badge).offset(x: 8, y: -4) } }
                Text(title).font(OriginalYapper.font(11, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? YapperPalette.text : YapperPalette.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct NativeOriginalAccountBar: View {
    let user: YapperUser
    let compact: Bool
    let mentions: Int
    let showInbox: Bool
    let onIdentity: () -> Void
    let onInbox: () -> Void
    let onSettings: () -> Void
    let onLogout: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onIdentity) {
                HStack(spacing: 8) {
                    NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: compact ? 40 : 32, decorationURL: user.avatarDecorationURL, crop: user.avatarCrop)
                    VStack(alignment: .leading, spacing: 1) {
                        NativeDisplayName(name: user.displayName, bannerURL: user.nameBannerURL)
                            .font(OriginalYapper.font(14, weight: .semibold)).lineLimit(1)
                        Text(user.presence.nativeOriginalPresenceLabel).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(4).frame(maxWidth: .infinity, minHeight: compact ? 48 : 44, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("native.account")
            if showInbox { Button(action: onInbox) {
                OriginalYapperIcon("at", size: 22).frame(width: compact ? 40 : 36, height: compact ? 40 : 44).contentShape(.interaction, Rectangle().inset(by: compact ? -2 : -4))
                    .overlay(alignment: .topTrailing) { if mentions > 0 { NativeOriginalBadge(count: mentions).offset(x: 1, y: 0) } }
            }.buttonStyle(.plain).accessibilityLabel("Mitteilungen & Erwähnungen").accessibilityIdentifier("native.home.inbox") }
            if !compact {
                Button(action: onSettings) { OriginalYapperIcon("settings", size: 20).frame(width: compact ? 40 : 36, height: compact ? 40 : 44).contentShape(.interaction, Rectangle().inset(by: compact ? -2 : -4)) }
                    .buttonStyle(.plain).accessibilityLabel("Konto und Einstellungen").accessibilityIdentifier("native.settings")
            }
            Button(action: onLogout) { OriginalYapperIcon("logout", size: 21).frame(width: compact ? 40 : 36, height: compact ? 40 : 44).contentShape(.interaction, Rectangle().inset(by: compact ? -2 : -4)) }
                .buttonStyle(.plain).accessibilityLabel("Abmelden").accessibilityIdentifier("native.account.signOut")
        }
        .foregroundStyle(YapperPalette.secondary)
        .padding(.horizontal, compact ? 12 : 10)
        .frame(height: compact ? 64 : 66)
        .background(YapperPalette.sidebar, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.original.accountBar")
    }
}

extension String {
    var nativeOriginalPresenceLabel: String {
        switch self {
        case "online": "Online"
        case "idle", "away": "Abwesend"
        case "dnd", "busy": "Bitte nicht stören"
        case "invisible", "offline": "Offline"
        default: "Angemeldet"
        }
    }
}
