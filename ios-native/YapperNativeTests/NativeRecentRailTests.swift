import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeRecentRailTests {
    private func chat(_ id: String, age: TimeInterval?, unread: Int = 1, serverID: String? = nil, now: Date) -> Conversation {
        Conversation(id: id, title: id, participants: [], unreadCount: unread, serverID: serverID, lastMessageAt: age.map { now.addingTimeInterval(-$0) })
    }

    @Test func `Recent unread rail caps and sorts visible inactive unmuted DM or group chats`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let excluded = [chat("old", age: 86_401, now: now), chat("unknown", age: nil, now: now), chat("read", age: 0, unread: 0, now: now),
                        chat("active", age: 0, now: now), chat("muted", age: 0, now: now), chat("server", age: 0, serverID: "server", now: now)]
        let recent = (1...6).reversed().map { chat("recent-\($0)", age: Double($0), now: now) }
        let result = NativeRecentUnreadRail.select(excluded + recent, activeID: "active", mutedIDs: ["muted"], at: now)
        #expect(result.map(\.id) == ["recent-1", "recent-2", "recent-3", "recent-4"])
    }

    @Test func `Recent unread rail includes the exact source day boundary and retains stable ties`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [chat("a", age: 86_400, now: now), chat("b", age: 86_400, now: now), chat("outside", age: 86_400.001, now: now)]
        #expect(NativeRecentUnreadRail.select(rows, activeID: nil, mutedIDs: [], at: now).map(\.id) == ["a", "b"])
    }
}
