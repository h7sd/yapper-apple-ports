import SwiftUI

enum NativePresenceLabel {
    static func text(_ value: String) -> String {
        switch value {
        case "online": "Online"
        case "idle", "away": "Abwesend"
        case "dnd", "busy": "Nicht stören"
        case "offline", "invisible": "Offline"
        default: ""
        }
    }
}

/// An in-app mention notice. It does not register or imitate remote push delivery.
struct NativeIncomingMentionBanner: View {
    let store: NativeStore
    let notice: NativeIncomingMention
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: open) {
                HStack(spacing: 10) {
                    NativeAvatar(name: notice.author.displayName, identity: notice.author.id,
                                 username: notice.author.username, url: notice.author.avatarURL, size: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(notice.author.displayName) hat dich erwähnt")
                            .font(OriginalYapper.font(13, weight: .semibold)).lineLimit(2)
                        Text(verbatim: NativeMentionRendering.plainText(notice.content, store: store, snapshot: nil)).font(OriginalYapper.font(12))
                            .foregroundStyle(YapperPalette.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 56).padding(.leading, 12).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("native.mention.notice.open")
            Button(action: dismiss) { OriginalYapperIcon("close", size: 18).frame(width: 44, height: 56).contentShape(.rect) }
                .buttonStyle(.plain).accessibilityLabel("Erwähnung schließen")
                .accessibilityIdentifier("native.mention.notice.dismiss")
        }
        .foregroundStyle(YapperPalette.text)
        .background(YapperPalette.elevated, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YapperPalette.border, lineWidth: 1))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("native.mention.notice")
    }
}
