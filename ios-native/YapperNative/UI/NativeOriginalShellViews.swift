import SwiftUI

enum NativeRecentUnreadRail {
    /// Caller supplies visible chats after the observed hidden_at/revival policy.
    static func select(_ visible: [Conversation], activeID: String?, mutedIDs: Set<String>, mentionCounts: [String: Int] = [:], at now: Date = Date()) -> [Conversation] {
        let cutoff = now.addingTimeInterval(-86_400)
        return Array(visible.enumerated().filter { _, conversation in
            conversation.serverID == nil && conversation.id != activeID && conversation.unreadCount > 0
                && (!mutedIDs.contains(conversation.id) || (mentionCounts[conversation.id] ?? 0) > 0)
                && conversation.lastMessageAt.map { $0 >= cutoff } == true
        }.sorted {
            let left = $0.element.lastMessageAt ?? .distantPast, right = $1.element.lastMessageAt ?? .distantPast
            return left == right ? $0.offset < $1.offset : left > right
        }.prefix(4).map(\.element))
    }
}

/// Yapper's server rail retained beside the user-pinned messages arrangement.
struct NativeOriginalRail: View {
    let servers: [NativeServer]
    let recentConversations: [Conversation]
    let selectedServerID: String?
    let compact: Bool
    let unread: Int
    let showDiscovery: Bool
    var bottomContentInset: CGFloat = 90
    var serverUnreadCounts: [String: Int] = [:]
    var serverMentionCounts: [String: Int] = [:]
    let onHome: () -> Void
    let onServer: (NativeServer) -> Void
    let onConversation: (Conversation) -> Void
    let onAdd: () -> Void
    let onDiscover: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var actionInk: Color {
        colorScheme == .light ? Color(red: 32.0 / 255, green: 139.0 / 255, blue: 88.0 / 255) : YapperPalette.success
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                railItem(selected: selectedServerID == nil, badge: unread, label: "Home", action: onHome) {
                    Image("AppMark").resizable().scaledToFit()
                }
                ForEach(recentConversations) { conversation in
                    railItem(selected: false, badge: conversation.unreadCount, label: "Ungelesene Nachrichten von \(conversation.title)", action: { onConversation(conversation) }) {
                        NativeAvatar(name: conversation.title, identity: conversation.participants.first?.id ?? conversation.id,
                                     username: conversation.participants.first?.username ?? conversation.title, url: conversation.avatarURL, presence: conversation.isGroup ? nil : conversation.participants.first?.presence, size: 48)
                    }.accessibilityIdentifier("native.rail.dm.\(conversation.id)")
                }
                Rectangle().fill(YapperPalette.active).frame(width: 32, height: 2).padding(.vertical, 2)
                ForEach(servers) { server in
                    railItem(selected: selectedServerID == server.id, badge: serverMentionCounts[server.id] ?? 0,
                             hasUnread: (serverUnreadCounts[server.id] ?? 0) > 0, label: server.name, action: { onServer(server) }) {
                        if server.iconURL != nil { NativeAvatar(name: server.name, url: server.iconURL, size: 48) }
                        else { Text(server.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()).font(OriginalYapper.fixedFont(16, numericWeight: 700)) }
                    }
                    .accessibilityValue("\(serverUnreadCounts[server.id] ?? 0) ungelesene Nachrichten, \(serverMentionCounts[server.id] ?? 0) Erwähnungen")
                    .accessibilityIdentifier("native.server.\(server.id)")
                }
                railItem(selected: false, badge: 0, label: "Server hinzufügen", action: onAdd) { OriginalYapperIcon("plus", size: 24).foregroundStyle(actionInk) }
                if showDiscovery { railItem(selected: false, badge: 0, label: "Server entdecken", action: onDiscover) { OriginalYapperIcon("compass", size: 24).foregroundStyle(actionInk) } }
            }
            .padding(.top, compact ? 10 : 12)
            .padding(.bottom, bottomContentInset)
        }
        .scrollIndicators(.hidden)
        .frame(width: 72)
        .background(YapperPalette.rail.ignoresSafeArea(.container, edges: .top))
        .accessibilityIdentifier("native.original.rail")
    }

    private func railItem<Content: View>(selected: Bool, badge: Int, hasUnread: Bool = false, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                content()
                    .frame(width: 48, height: 48)
                    .background(selected ? YapperPalette.accentFill : YapperPalette.elevated)
                    .clipShape(.rect(cornerRadius: selected ? 16 : 18))
                if badge > 0 { NativeOriginalBadge(count: badge).offset(x: 2, y: 2) }
            }
            .frame(width: 72, height: 48)
            .overlay(alignment: .leading) {
                if selected { Capsule().fill(YapperPalette.text).frame(width: 4, height: 36).offset(x: -2) }
                else if hasUnread { Capsule().fill(YapperPalette.text).frame(width: 4, height: 8).offset(x: -2).accessibilityHidden(true) }
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
    var profile: NativeProfileDetail? = nil
    let compact: Bool
    let mentions: Int
    let showInbox: Bool
    var showCustomStatus = false
    let onIdentity: () -> Void
    let onInbox: () -> Void
    let onSettings: () -> Void
    let onLogout: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasArtwork: Bool { compact && profile?.bannerURL != nil }
    private var themed: Bool { compact && Color.originalProfileHex(profile?.accentColor) != nil }
    private var light: Bool { OriginalProfileContrast.isLight(profile?.accentColor, profile?.accentColor2) }
    private var ink: Color { hasArtwork ? .white : themed ? (light ? .black : .white) : YapperPalette.text }
    private var secondaryInk: Color { hasArtwork ? .white.opacity(0.86) : themed ? (light ? .black.opacity(0.72) : .white.opacity(0.86)) : YapperPalette.secondary }
    private var status: String {
        if compact, showCustomStatus, let profile, !profile.customStatus.isEmpty,
           profile.customStatusUntil.map({ $0 > Date() }) ?? true { return profile.customStatus }
        return user.presence.nativeOriginalPresenceLabel
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onIdentity) {
                HStack(spacing: compact ? 12 : 8) {
                    NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: compact ? 48 : 32, decorationURL: user.avatarDecorationURL, crop: user.avatarCrop)
                    VStack(alignment: .leading, spacing: compact ? 3 : 1) {
                        HStack(spacing: 6) {
                            NativeDisplayName(name: user.displayName, bannerURL: user.nameBannerURL)
                                .font(OriginalYapper.font(compact ? 16 : 14, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(ink)
                            if compact { OriginalYapperIcon("chevronDown", size: 14).foregroundStyle(secondaryInk) }
                        }
                        Text(verbatim: status).font(OriginalYapper.font(compact ? 13 : 12)).foregroundStyle(secondaryInk)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(compact ? 0 : 4).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityLabel("Konto: \(user.displayName), \(status)").accessibilityHint("Profil, Status und Einstellungen öffnen").accessibilityIdentifier("native.account")
            if showInbox { Button(action: onInbox) {
                OriginalYapperIcon(compact ? "bell" : "at", size: compact ? 18 : 22).frame(width: compact ? 32 : 36, height: compact ? 32 : 44)
                    .background(compact ? (hasArtwork || themed ? Color.black.opacity(light && !hasArtwork ? 0.1 : 0.3) : YapperPalette.elevated) : .clear, in: .rect(cornerRadius: 12))
                    .padding(compact ? 6 : 0)
                    .contentShape(.interaction, Rectangle().inset(by: compact ? 0 : -4))
                    .overlay(alignment: .topTrailing) { if mentions > 0 { NativeOriginalBadge(count: mentions).offset(x: 1, y: 0) } }
            }.buttonStyle(.plain).accessibilityLabel("Mitteilungen & Erwähnungen").accessibilityIdentifier("native.home.inbox") }
            if !compact {
                Button(action: onSettings) { OriginalYapperIcon("settings", size: 20).frame(width: compact ? 40 : 36, height: compact ? 40 : 44).contentShape(.interaction, Rectangle().inset(by: compact ? -2 : -4)) }
                    .buttonStyle(.plain).accessibilityLabel("Konto und Einstellungen").accessibilityIdentifier("native.settings")
            }
            if !compact {
                Button(action: onLogout) { OriginalYapperIcon("logout", size: 21).frame(width: 36, height: 44).contentShape(.interaction, Rectangle().inset(by: -4)) }
                    .buttonStyle(.plain).accessibilityLabel("Abmelden").accessibilityIdentifier("native.account.signOut")
            }
        }
        .foregroundStyle(compact ? ink : YapperPalette.secondary)
        .padding(.horizontal, compact ? 12 : 10)
        .frame(minHeight: compact ? 56 : 66)
        .background {
            bannerBackground
                .clipShape(.rect(cornerRadius: compact ? 18 : 16))
                .overlay(RoundedRectangle(cornerRadius: compact ? 18 : 16).strokeBorder(YapperPalette.border, lineWidth: compact ? 1 : 0))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.original.accountBar")
    }

    @ViewBuilder private var bannerBackground: some View {
        ZStack {
            if compact, let first = Color.originalProfileHex(profile?.accentColor) {
                OriginalProfileGradient(first: first, second: Color.originalProfileHex(profile?.accentColor2) ?? first)
            } else { YapperPalette.sidebar }
            if compact, let profile, let banner = profile.bannerURL {
                NativeCroppedImage(url: banner, crop: NativeImageCrop(x: profile.bannerX, y: profile.bannerY, zoom: profile.bannerZoom), maximumPixelSize: 1600, placeholder: "")
                    .overlay(Color.black.opacity(0.5))
                    .allowsHitTesting(false)
            }
            if compact, let effect = user.profileEffectURL {
                NativeRemoteImage(url: effect, mode: .fill, placeholder: "").allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

extension String {
    var nativeOriginalPresenceLabel: String {
        switch self {
        case "online": "Online"
        case "idle", "away": "Abwesend"
        case "dnd", "busy": "Bitte nicht stören"
        case "invisible": "Unsichtbar"
        case "offline": "Offline"
        default: "Status nicht verfügbar"
        }
    }
}
