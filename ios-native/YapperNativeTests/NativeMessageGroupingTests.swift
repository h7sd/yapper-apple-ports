import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeMessageGroupingTests {
    private func message(_ id: String, at time: Date, author: String = "author") -> ChatMessage {
        ChatMessage(id: id, channelID: "channel", author: YapperUser(id: author, username: author), content: "text", createdAt: time, attachments: [], isEdited: false)
    }
    @Test func `Grouping uses the shipped seven minute exclusive boundary and local day`() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = message("a", at: date)
        #expect(NativeMessageGrouping.groups(message("b", at: date.addingTimeInterval(419.999)), after: previous, calendar: calendar))
        #expect(!NativeMessageGrouping.groups(message("b", at: date.addingTimeInterval(420)), after: previous, calendar: calendar))
        let midnight = calendar.startOfDay(for: date)
        #expect(!NativeMessageGrouping.groups(message("b", at: midnight), after: message("a", at: midnight.addingTimeInterval(-1)), calendar: calendar))
    }
    @Test func `Replies system rows unread dividers and differing webhook identities split groups`() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = message("a", at: date)
        var next = message("b", at: date.addingTimeInterval(1))
        #expect(!NativeMessageGrouping.groups(next, after: nil))
        #expect(!NativeMessageGrouping.groups(next, after: previous, firstUnreadID: "b"))
        next.grouping.replyToID = "reply"; #expect(!NativeMessageGrouping.groups(next, after: previous))
        next.grouping.replyToID = nil; next.grouping.isSystem = true; #expect(!NativeMessageGrouping.groups(next, after: previous))
        next.grouping.isSystem = false; next.grouping.webhookName = "Another sender"; #expect(!NativeMessageGrouping.groups(next, after: previous))
        var matching = previous; matching.grouping.webhookName = next.grouping.webhookName
        #expect(NativeMessageGrouping.groups(next, after: matching))
    }
    @Test func `Full RPC message decoding retains system reply and webhook grouping metadata`() throws {
        let row: NativeJSON = .object(["id": .string("message"), "channel_id": .string("channel"), "created_at": .string("2026-10-31T12:00:00Z"), "system": .object(["kind": .string("join")]), "reply_to_id": .string("reply"), "webhook": .object(["id": .string("hook"), "name": .string("Sender"), "avatar_url": .string("https://example.invalid/avatar.png")])])
        let decoded = try NativeMessageResult(json: row, profiles: [:]).message.grouping
        #expect(decoded.isSystem && decoded.replyToID == "reply")
        #expect(decoded.webhookID == "hook" && decoded.webhookName == "Sender")
        #expect(decoded.webhookAvatarURL == "https://example.invalid/avatar.png" && decoded.webhookAvatarPath == nil)
    }
}
