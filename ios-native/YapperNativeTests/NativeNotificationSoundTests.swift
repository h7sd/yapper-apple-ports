import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeNotificationSoundTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private let peer = "22222222-2222-4222-8222-222222222222"
    private let channel = "33333333-3333-4333-8333-333333333333"
    private func message(_ id: String = "message", channelID: String? = nil, authorID: String? = nil) -> ChatMessage {
        ChatMessage(id: id, channelID: channelID ?? channel, author: YapperUser(id: authorID ?? peer, username: "peer"),
                    content: "Hello", createdAt: Date(timeIntervalSince1970: 0), attachments: [], isEdited: false)
    }
    private func policy(ownerID: String? = nil, status: String = "online", blocked: Set<String> = [], muted: Set<String> = []) -> NativeNotificationSoundPolicy {
        NativeNotificationSoundPolicy(ownerID: ownerID ?? own, status: status, blockedIDs: blocked, mutedIDs: muted)
    }
    private func defaults() throws -> UserDefaults {
        let name = "NativeNotificationSoundTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func `Sounds default on and the persisted switch disables playback`() throws {
        let preferences = try defaults()
        var plays = 0
        let sound = NativeNotificationSound(defaults: preferences, play: { plays += 1 })
        #expect(sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        preferences.set(false, forKey: NativeNotificationSound.preferenceKey)
        #expect(!sound.receive(message: message("next"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        #expect(plays == 1)
    }

    @Test func `Foreground ownership focus DND mute hide and block gates stay silent`() throws {
        let preferences = try defaults()
        var plays = 0
        let sound = NativeNotificationSound(defaults: preferences, play: { plays += 1 })
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: false, policy: policy()))
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: channel, isActive: true, policy: policy()))
        #expect(!sound.receive(message: message(authorID: own), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy(ownerID: peer)))
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy(status: "dnd")))
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy(blocked: [peer])))
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy(muted: [channel])))
        #expect(plays == 0)
        #expect(sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy(status: "invisible")))
        #expect(plays == 1)
    }

    @Test func `Global and per channel author throttles honor their exact boundaries`() throws {
        var instant = Date(timeIntervalSince1970: 0)
        var plays = 0
        let sound = NativeNotificationSound(defaults: try defaults(), now: { instant }, play: { plays += 1 })
        #expect(sound.receive(message: message("first"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = instant.addingTimeInterval(0.119)
        #expect(!sound.receive(message: message("global", channelID: "another"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 0.12)
        #expect(sound.receive(message: message("boundary", channelID: "another"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 4.999)
        #expect(!sound.receive(message: message("same-sender"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 5)
        #expect(sound.receive(message: message("sender-boundary"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 5.12)
        #expect(sound.receive(message: message("other-author", authorID: "other-peer"), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        #expect(plays == 4)
    }

    @Test func `Message IDs deduplicate for 120 seconds and reset clears account history`() throws {
        var instant = Date(timeIntervalSince1970: 0)
        var plays = 0
        let sound = NativeNotificationSound(defaults: try defaults(), now: { instant }, play: { plays += 1 })
        #expect(sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 119.999)
        #expect(!sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        instant = Date(timeIntervalSince1970: 120)
        #expect(sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        sound.reset()
        #expect(sound.receive(message: message(), currentUserID: own, currentConversationID: nil, isActive: true, policy: policy()))
        #expect(plays == 3)
    }

    @Test func `Policy reads only authenticated original status and RLS blocked IDs`() async throws {
        let session = NativeSession(accessToken: "synthetic-sound-access", refreshToken: "synthetic-sound-refresh", expiresAt: Date().addingTimeInterval(3600), userID: own)
        var paths: [String] = []
        let api = NativeAPI { request in
            let url = try #require(request.url)
            paths.append(url.lastPathComponent)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-sound-access")
            #expect(request.value(forHTTPHeaderField: "apikey") == NativeConfiguration.anonymousKey)
            let value: NativeJSON
            if url.lastPathComponent == "my_status_pref" {
                #expect(request.httpMethod == "POST")
                #expect(try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) == .object([:]))
                value = .string("dnd")
            } else {
                #expect(url.lastPathComponent == "blocks" && request.httpMethod == "GET")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "select", value: "blocked")])
                value = .array([.object(["blocked": .string(peer)])])
            }
            return (try JSONEncoder().encode(value), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let result = try await api.nativeNotificationSoundPolicy(mutedIDs: [channel], session: session)
        #expect(result == policy(status: "dnd", blocked: [peer], muted: [channel]))
        #expect(paths == ["my_status_pref", "blocks"])
    }

    @Test func `Unknown or malformed status fails closed without a fallback write`() async throws {
        var calls = 0
        let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: own)
        let api = NativeAPI { request in
            calls += 1
            #expect(request.url?.lastPathComponent == "my_status_pref" && request.httpMethod == "POST")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (try JSONEncoder().encode(NativeJSON.string("unknown")), response)
        }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeNotificationSoundPolicy(mutedIDs: [], session: session) }
        #expect(calls == 1)
    }
}
