import SwiftUI

struct NativeRenderedMention {
    let token: NativeMentionToken
    let label: String
    let color: Color
}

enum NativeMentionRendering {
    static func mentions(in text: String, store: NativeStore?, snapshot: NativeServerSnapshot?) -> [NativeRenderedMention] {
        NativeMentionTokens.matches(in: text).map { token in
            let id = token.target.targetID ?? ""
            let label: String
            var color = YapperPalette.accent
            switch token.target.kind {
            case .user:
                let member = snapshot?.members.first { $0.id == id }
                label = "@" + (member?.displayName ?? store?.knownUser(id: id)?.displayName ?? "Unbekannter Nutzer")
                color = Color.originalProfileHex(snapshot?.nameColor(userID: id)) ?? color
            case .role:
                let role = snapshot?.roles.first { $0.id == id }
                label = "@" + (role?.name ?? "Unbekannte Rolle")
                color = Color.originalProfileHex(role?.color) ?? color
            case .channel:
                label = "#" + (snapshot?.channels.first { $0.id == id }?.name ?? store?.conversations.first { $0.id == id }?.title.trimmingCharacters(in: CharacterSet(charactersIn: "#")) ?? "Kanal")
            case .everyone: label = "@everyone"
            case .here: label = "@here"
            }
            return NativeRenderedMention(token: token, label: label, color: color)
        }
    }

    static func plainText(_ text: String, store: NativeStore?, snapshot: NativeServerSnapshot?) -> String {
        let result = NSMutableString(string: text)
        for mention in mentions(in: text, store: store, snapshot: snapshot).reversed() {
            result.replaceCharacters(in: mention.token.range, with: mention.label)
        }
        return result as String
    }
}

struct NativeMentionDestination: View {
    let store: NativeStore
    let target: NativeMentionTarget
    let snapshot: NativeServerSnapshot?
    @Environment(\.dismiss) private var dismiss
    @State private var openedConversation: Conversation?

    var body: some View {
        NavigationStack {
            Group {
                if target.kind == .user, let id = target.targetID {
                    NativeProfileView(store: store, userID: id, onOpenConversation: { openedConversation = $0 })
                } else if target.kind == .channel, let id = target.targetID,
                          let channel = snapshot?.channels.first(where: { $0.id == id }) {
                    if channel.kind == "forum", let snapshot { NativeServerForumView(store: store, channel: channel, snapshot: snapshot) }
                    else { NativeConversationView(store: store, conversation: channel.conversation, serverSnapshot: snapshot) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if target.kind == .role, let id = target.targetID, let role = snapshot?.roles.first(where: { $0.id == id }) {
                                NativeServerRoleName(name: "@" + role.name, role: role).font(OriginalYapper.font(20, weight: .bold))
                                Text("Mitglieder aus der geladenen Serverliste").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
                                ForEach(snapshot?.members.filter { snapshot?.roleIDs(for: $0.id).contains(id) == true } ?? []) { member in
                                    HStack(spacing: 10) {
                                        NativeAvatar(name: member.displayName, identity: member.id, username: member.user.username, url: member.user.avatarURL, presence: store.peerPresence(userID: member.id), size: 32)
                                        NativeServerRoleName(name: member.displayName, role: snapshot?.colorRole(userID: member.id))
                                    }.frame(minHeight: 44)
                                }
                            } else {
                                Text(target.kind == .everyone ? "@everyone erwähnt alle Mitglieder." : target.kind == .here ? "@here erwähnt die vom Server bestimmten anwesenden Mitglieder." : "Diese Erwähnung ist nicht verfügbar.")
                                    .font(OriginalYapper.font(15))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.background(YapperPalette.background.ignoresSafeArea())
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() }.frame(minHeight: 44) } }
            .navigationDestination(item: $openedConversation) { conversation in NativeConversationView(store: store, conversation: conversation) }
        }
    }
}
