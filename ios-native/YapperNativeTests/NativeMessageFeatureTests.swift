import Foundation
import Testing
@testable import YapperNative
#if canImport(UIKit)
import UIKit
import ImageIO
#endif

@MainActor @Suite struct NativeMessageFeatureTests {
    @MainActor private final class PolicyFixtureState {
        var clock: Date
        var sends = 0
        var rolloutOn = true
        init(clock: Date) { self.clock = clock }
    }
    private let user = "11111111-1111-4111-8111-111111111111"
    private let channel = "22222222-2222-4222-8222-222222222222"
    private let messageID = "33333333-3333-4333-8333-333333333333"
    private let replyID = "44444444-4444-4444-8444-444444444444"

    private var session: NativeSession { NativeSession(accessToken: "synthetic-message-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: user) }
    private var message: ChatMessage { ChatMessage(id: messageID, channelID: channel, author: YapperUser(id: user, username: "fixture"), content: "Original", createdAt: Date(), attachments: [], isEdited: false) }

    private func response(_ request: URLRequest, _ value: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (try JSONEncoder().encode(value), http)
    }

    private func body(_ request: URLRequest) throws -> NativeJSON { try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) }
    private func query(_ request: URLRequest, _ name: String) -> String? { request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value } }

    @Test func `Plus 4000 requires a live own subscription and the actual rollout audience`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let joined = "55555555-5555-4555-8555-555555555555"
        let active = YapperUser(id: user, username: "fixture", plusUntil: now.addingTimeInterval(60))
        let everyone = NativeCapabilities(flags: .object(["plus_4000": .object(["mode": .string("everyone")])]))
        let policy = NativeMessagePolicy(user: active, capabilities: everyone)
        #expect(NativeMessagePolicy.standard.maximumLength(for: user, at: now) == 2000)
        #expect(NativeMessagePolicy(user: active).maximumLength(for: user, at: now) == 2000)
        #expect(policy.maximumLength(for: user, at: now) == 4000)
        #expect(policy.maximumLength(for: replyID, at: now) == 2000)
        #expect(policy.maximumLength(for: user, at: now.addingTimeInterval(60)) == 2000)
        #expect(NativeMessagePolicy(user: YapperUser(id: user, username: "no-plus"), capabilities: everyone).maximumLength(for: user, at: now) == 2000)

        func audience(users: [String] = [], servers: [String] = [], joinedIDs: Set<String> = []) -> NativeMessagePolicy {
            NativeMessagePolicy(user: active, capabilities: NativeCapabilities(flags: .array([.object(["key": .string("plus_4000"), "mode": .string("test"), "users": .array(users.map(NativeJSON.string)), "servers": .array(servers.map(NativeJSON.string))])]), joinedServerIDs: joinedIDs))
        }
        #expect(audience(users: [user]).maximumLength(for: user, at: now) == 4000)
        #expect(audience(users: [replyID]).maximumLength(for: user, at: now) == 2000)
        #expect(audience(servers: [joined], joinedIDs: [joined]).maximumLength(for: user, at: now) == 4000)
        #expect(audience(servers: [joined]).maximumLength(for: user, at: now) == 2000)
        #expect(audience(servers: [replyID], joinedIDs: [joined]).maximumLength(for: user, at: now) == 2000)
        let disabled = NativeCapabilities(flags: .object(["plus_4000": .object(["mode": .string("off"), "users": .array([.string(user)])])]))
        #expect(NativeMessagePolicy(user: active, capabilities: disabled).maximumLength(for: user, at: now) == 2000)
    }

    @Test func `Bootstrap preserves Plus expiry and only actual joined server IDs for rollout`() throws {
        let joined = "55555555-5555-4555-8555-555555555555"
        let payload = NativeJSON.object([
            "dm_channels": .array([]), "dm_members": .array([]),
            "profiles": .array([.object(["id": .string(user), "username": .string("fixture"), "plus_until": .string("2030-01-01T00:00:00.123Z")])]),
            "servers": .array([.object(["id": .string(joined)]), .object(["id": .string("malformed")])]),
            "flags": .array([.object(["key": .string("plus_4000"), "mode": .string("test"), "servers": .array([.string(joined)]), "users": .array([])])])
        ])
        let bootstrap = try JSONDecoder().decode(BootstrapResponse.self, from: JSONEncoder().encode(payload))
        let own = try #require(bootstrap.profiles.first).user()
        #expect(own.plusUntil == (try NativeDate.parse("2030-01-01T00:00:00.123Z")))
        #expect(bootstrap.capabilities.joinedServerIDs == [joined])
        #expect(NativeMessagePolicy(user: own, capabilities: bootstrap.capabilities).maximumLength(for: user, at: try NativeDate.parse("2029-12-31T23:59:59Z")) == 4000)
        let invalid = try JSONDecoder().decode(ProfileRow.self, from: Data("{\"id\":\"\(user)\",\"username\":\"fixture\",\"plus_until\":\"invalid\"}".utf8))
        #expect(invalid.user().plusUntil == nil)
    }

    @Test func `Text reply edit and attachment sends enforce the same identity bound UTF16 limits`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json" {
                var values = try #require(try body(request).object)
                values["created_at"] = .string("2026-10-31T12:00:00Z")
                return try response(request, .object(values))
            }
            return try response(request, .array([.object(["id": .string(messageID)])]))
        })
        let long = String(repeating: "a", count: 2001)
        await #expect(throws: NativeClientError.messageTooLong) { _ = try await api.send(id: messageID, text: long, channelID: channel, session: session) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.sendReply(id: messageID, text: long, replyToID: replyID, channelID: channel, session: session) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.editMessage(message, text: long, session: session) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.sendAttachment(id: messageID, text: long, data: Data(), filename: "fixture.png", contentType: "image/png", channelID: channel, replyToID: nil, session: session) }
        #expect(requests.isEmpty)

        let own = YapperUser(id: user, username: "fixture", plusUntil: Date().addingTimeInterval(3600))
        let policy = NativeMessagePolicy(user: own, capabilities: NativeCapabilities(flags: .object(["plus_4000": .object(["mode": .string("everyone")])])))
        let maximum = String(repeating: "🙂", count: 2000)
        #expect(maximum.utf16.count == 4000)
        _ = try await api.send(id: messageID, text: maximum, channelID: channel, session: session, messagePolicy: policy)
        try await api.sendReply(id: messageID, text: maximum, replyToID: replyID, channelID: channel, session: session, messagePolicy: policy)
        try await api.editMessage(message, text: maximum, session: session, messagePolicy: policy)
        // The identity lookup confirms an already accepted attachment; no upload is started.
        try await api.sendAttachment(id: messageID, text: maximum, data: Data(), filename: "fixture.png", contentType: "image/png", channelID: channel, replyToID: nil, session: session, messagePolicy: policy)
        #expect(requests.count == 4)
        let oversized = maximum + "a"
        await #expect(throws: NativeClientError.messageTooLong) { _ = try await api.send(id: messageID, text: oversized, channelID: channel, session: session, messagePolicy: policy) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.sendReply(id: messageID, text: oversized, replyToID: replyID, channelID: channel, session: session, messagePolicy: policy) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.editMessage(message, text: oversized, session: session, messagePolicy: policy) }
        await #expect(throws: NativeClientError.messageTooLong) { try await api.sendAttachment(id: messageID, text: oversized, data: Data(), filename: "fixture.png", contentType: "image/png", channelID: channel, replyToID: nil, session: session, messagePolicy: policy) }
        let foreign = YapperUser(id: replyID, username: "other", plusUntil: own.plusUntil)
        let wrongAccount = NativeMessagePolicy(user: foreign, capabilities: policy.capabilities)
        await #expect(throws: NativeClientError.messageTooLong) { try await api.editMessage(message, text: long, session: session, messagePolicy: wrongAccount) }
        #expect(requests.count == 4)
    }

    @Test func `Store applies bootstrap Plus policy to sends then expires and resets it`() async throws {
        let start = Date()
        let fixture = PolicyFixtureState(clock: start)
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("/bootstrap") == true {
                return try response(request, .object([
                    "profiles": .array([.object(["id": .string(user), "username": .string("fixture"), "plus_until": .string(start.addingTimeInterval(300).ISO8601Format())])]),
                    "dm_channels": .array([.object(["id": .string(channel), "kind": .string("dm")])]),
                    "dm_members": .array([.array([.string(channel), .string(user)])]),
                    "flags": .array([.object(["key": .string("plus_4000"), "mode": .string(fixture.rolloutOn ? "everyone" : "off")])])
                ]))
            }
            fixture.sends += 1
            var values = try #require(try body(request).object)
            values["created_at"] = .string(start.ISO8601Format())
            return try response(request, .object(values))
        })
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil, now: { fixture.clock })
        await store.restoreSession()
        let conversation = try #require(store.conversations.first)
        #expect(store.messageCharacterLimit == 4000)
        #expect(await store.sendMessage(String(repeating: "a", count: 4000), in: conversation))
        #expect(fixture.sends == 1)
        fixture.clock = start.addingTimeInterval(301)
        #expect(store.messageCharacterLimit == 2000)
        #expect(await store.sendMessage(String(repeating: "a", count: 2001), in: conversation) == false)
        #expect(fixture.sends == 1)
        fixture.clock = start
        fixture.rolloutOn = false
        await store.loadConversations()
        #expect(store.messageCharacterLimit == 2000)
        #expect(await store.sendMessage(String(repeating: "a", count: 2001), in: conversation) == false)
        #expect(fixture.sends == 1)
        store.signOut()
        #expect(store.messageCharacterLimit == 2000)
        #expect(store.capabilities.joinedServerIDs.isEmpty)
    }

    @Test func `Reply sends observed reply_to_id and keeps its UUID after an uncertain duplicate`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.httpMethod == "POST" { return try response(request, .object(["message": .string("duplicate")]), status: 409) }
            return try response(request, .array([.object(["id": .string(messageID)])]))
        })
        try await api.sendReply(id: messageID, text: " Reply ", replyToID: replyID, channelID: channel, session: session)
        #expect(requests.count == 2)
        let sent = try body(requests[0])
        #expect(sent["id"].string == messageID)
        #expect(sent["reply_to_id"].string == replyID)
        #expect(sent["channel_id"].string == channel)
        #expect(sent["content"].string == "Reply")
        #expect(query(requests[1], "author_id") == "eq.\(user)")
    }

    @Test func `Editing does not report success when row permissions return an empty result`() async throws {
        var captured: URLRequest?
        let api = NativeAPI(transport: { request in captured = request; return try response(request, .array([])) })
        await #expect(throws: (any Error).self) { try await api.editMessage(message, text: "Changed", session: session) }
        let request = try #require(captured)
        #expect(request.httpMethod == "PATCH")
        #expect(query(request, "id") == "eq.\(messageID)")
        #expect(try body(request) == .object(["content": .string("Changed")]))
    }

    @Test func `Own message mutation checks identity before transport and deletion confirms returned identity`() async throws {
        var count = 0
        let api = NativeAPI(transport: { request in count += 1; return try response(request, .array([])) })
        var other = message; other.author = YapperUser(id: replyID, username: "other")
        await #expect(throws: (any Error).self) { try await api.editMessage(other, text: "Changed", session: session) }
        await #expect(throws: (any Error).self) { try await api.deleteMessage(other, session: session) }
        #expect(count == 0)
        await #expect(throws: (any Error).self) { try await api.deleteMessage(message, session: session) }
        #expect(count == 1)
    }

    @Test func `Reaction removal filters the current user and the selected emoji`() async throws {
        var captured: URLRequest?
        let api = NativeAPI(transport: { request in captured = request; return try response(request, .array([])) })
        let reaction = try #require(NativeReaction(.object(["id": .string(replyID), "message_id": .string(messageID), "user_id": .string(user), "emoji": .string("❤️")])))
        try await api.toggleReaction(messageID: messageID, emoji: "❤️", existing: [reaction], session: session)
        let request = try #require(captured)
        #expect(request.httpMethod == "DELETE")
        #expect(query(request, "message_id") == "eq.\(messageID)")
        #expect(query(request, "user_id") == "eq.\(user)")
        #expect(query(request, "emoji") == "eq.❤️")
    }

    @Test func `Twenty distinct reactions still permit an existing emoji but refuse a new kind`() async throws {
        var calls = 0
        let api = NativeAPI(transport: { request in calls += 1; return try response(request, .array([.object(["id": .string(replyID)])])) })
        let rows = (0..<20).compactMap { NativeReaction(.object(["id": .string("reaction-\($0)"), "message_id": .string(messageID), "user_id": .string(replyID), "emoji": .string("emoji-\($0)")])) }
        await #expect(throws: (any Error).self) { try await api.toggleReaction(messageID: messageID, emoji: "new", existing: rows, session: session) }
        #expect(calls == 0)
        try await api.toggleReaction(messageID: messageID, emoji: "emoji-0", existing: rows, session: session)
        #expect(calls == 1)
        let grouped = NativeReactionGroup.groups(rows + [rows[0]], currentUserID: user)
        #expect(grouped.count == 20)
        #expect(grouped[0].count == 1)
    }

    @Test func `Search sends explicit optional parameters and does not mask permission failures with fallback`() async throws {
        var captured: [URLRequest] = []
        let api = NativeAPI(transport: { request in captured.append(request); return try response(request, .object(["message": .string("permission denied")]), status: 403) })
        await #expect(throws: (any Error).self) { try await api.searchMessages(NativeMessageSearch(query: "hello", pinned: true), channelID: channel, session: session) }
        #expect(captured.count == 1)
        let request = try #require(captured.first)
        #expect(request.url?.path.hasSuffix("/search_messages_v4") == true)
        let data = try body(request)
        #expect(data["cid"].string == channel)
        #expect(data["sid"] == .null)
        #expect(data["author"] == .null)
        #expect(data["mention"] == .null)
        #expect(data["pinned"].bool == true)
    }

    @Test func `Pin mutation and pin retrieval match the observed RPC and table contracts`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try response(request, request.httpMethod == "POST" ? .null : .array([])) })
        try await api.pinMessage(id: messageID, pinned: true, session: session)
        let pins = try await api.pinnedMessages(channelID: channel, session: session)
        #expect(pins.isEmpty)
        #expect(try body(requests[0]) == .object(["mid": .string(messageID), "pinned": .bool(true)]))
        #expect(query(requests[1], "pinned_at") == "not.is.null")
        #expect(query(requests[1], "channel_id") == "eq.\(channel)")
        #expect(query(requests[1], "limit") == "50")
    }

    @Test func `An accepted signed upload returns no path until the official scanner accepts it`() async throws {
        var scans = 0
        var uploaded = false
        let destination = URL(string: "https://files.yapper.website/synthetic-upload")!
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("upload-url") == true { return try response(request, .object(["url": .string(destination.absoluteString), "headers": .object(["authorization": .string("must-not-copy"), "x-amz-meta-test": .string("synthetic")])])) }
            if request.url?.path.hasSuffix("scan") == true { scans += 1; #expect(uploaded); return try response(request, .object(["verdict": .string("ok")])) }
            throw NativeClientError.invalidEndpoint
        })
        let path = try await api.uploadMedia(bucket: "avatars", data: Data([1, 2, 3]), filename: "test.png", contentType: "image/png", session: session, uploadTransport: { request in
            uploaded = true
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
            #expect(request.value(forHTTPHeaderField: "x-amz-meta-test") == "synthetic")
            return try #require(HTTPURLResponse(url: destination, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        })
        #expect(scans == 1)
        #expect(path.hasPrefix(user + "/r2-"))
        #expect(path.hasSuffix(".png"))
    }

    @Test func `Blocked scan cleans the uploaded object and refuses the path`() async throws {
        var removed = false
        let destination = URL(string: "https://files.yapper.website/synthetic-upload")!
        let api = NativeAPI(transport: { request in
            if request.url?.path.hasSuffix("upload-url") == true { return try response(request, .object(["url": .string(destination.absoluteString)])) }
            if request.url?.path.hasSuffix("scan") == true { return try response(request, .object(["verdict": .string("blocked")])) }
            if request.url?.path.hasSuffix("remove") == true { removed = true; return try response(request, .null) }
            throw NativeClientError.invalidEndpoint
        })
        await #expect(throws: (any Error).self) {
            try await api.uploadMedia(bucket: "attachments", data: Data([1, 2]), filename: "test.png", contentType: "image/png", session: session, uploadTransport: { _ in try #require(HTTPURLResponse(url: destination, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)) })
        }
        #expect(removed)
    }

    @Test func `Media upload rejects untrusted destinations and unsupported content before exposing files`() throws {
        #expect(NativeMediaUploadPolicy.signedDestination(URL(string: "https://bucket.account.r2.cloudflarestorage.com/file?X-Amz-Signature=synthetic")!))
        #expect(!NativeMediaUploadPolicy.signedDestination(URL(string: "http://files.yapper.website/file")!))
        #expect(!NativeMediaUploadPolicy.signedDestination(URL(string: "https://files.yapper.website.evil.invalid/file")!))
        #expect(!NativeMediaUploadPolicy.signedDestination(URL(string: "https://user:password@files.yapper.website/file")!))
        #expect(throws: (any Error).self) { try NativeMediaUploadPolicy.validate(bucket: "avatars", bytes: 2, contentType: "application/pdf") }
        #expect(throws: (any Error).self) { try NativeMediaUploadPolicy.validate(bucket: "attachments", bytes: 11 * 1024 * 1024, contentType: "image/png") }
        #expect(NativeMessageMedia.contentType(path: "a/voice.m4a") == "audio/mp4")
        #expect(NativeMessageMedia.contentType(path: "a/photo.JPG?version=1") == "image/jpeg")
    }

    @Test func `Search fallback still applies advanced filters instead of returning unrelated results`() {
        let audio = NativeJSON.object(["attachment_path": .string("user/voice.m4a"), "pinned_at": .string("2026-10-31T12:00:00Z"), "created_at": .string("2026-10-31T11:00:00Z")])
        let photo = NativeJSON.object(["attachment_path": .string("user/image.png"), "pinned_at": .null, "created_at": .string("2026-10-31T11:00:00Z")])
        let search = NativeMessageSearch(query: "hello", since: "2026-10-30T00:00:00Z", has: "sound", pinned: true)
        #expect(search.matches(audio))
        #expect(!search.matches(photo))
    }

    @Test func `Quiz creation sends source option IDs and validates a wrong answer before transport`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in requests.append(request); return try response(request, .null) })
        try await api.createPoll(channelID: channel, question: "Question?", options: ["Yes", "No"], multi: false, hours: 24, quiz: true, correct: [0], reveal: "close", anonymous: true, session: session)
        #expect(requests.count == 1)
        #expect(requests[0].url?.path.hasSuffix("create_poll_ex") == true)
        let payload = try body(requests[0])
        #expect(payload["correct"] == .array([.string("1")]))
        #expect(payload["opts"] == .array([.string("Yes"), .string("No")]))
        #expect(payload["anon"] == .bool(true))
        await #expect(throws: (any Error).self) {
            try await api.createPoll(channelID: channel, question: "Question?", options: ["Yes", "No"], multi: false, hours: 24, quiz: true, correct: [0, 1], reveal: "vote", anonymous: false, session: session)
        }
        #expect(requests.count == 1)
    }

    @Test func `Hidden quiz results never reveal the correct option before the server allows it`() async throws {
        let poll = try NativePoll(.object(["id": .string(replyID), "message_id": .string(messageID), "question": .string("Question?"), "quiz": .bool(true), "options": .array([.object(["id": .string("1"), "text": .string("Yes")]), .object(["id": .string("2"), "text": .string("No")])])]))
        let api = NativeAPI(transport: { request in
            try response(request, .object(["visible": .bool(false), "voted": .bool(true), "correct": .array([.string("1")]), "you_right": .bool(true), "total": .number(1), "results": .array([])]))
        })
        let state = try await api.pollState(poll, session: session)
        #expect(!state.visible)
        #expect(state.correct.isEmpty)
        #expect(state.youRight == nil)
        #expect(state.voted)
    }

    @Test func `Voice waveform uses the official compact alphabet and bounds nonfinite input`() {
        #expect(NativeMediaUploadPolicy.voiceWave([0, 0.25, 1]) == "Ag_")
        #expect(NativeMediaUploadPolicy.voiceWave(Array(repeating: 1, count: 100)).count == 64)
        #expect(NativeMediaUploadPolicy.voiceWave([.nan]).isEmpty)
        #expect(NativeMediaUploadPolicy.voiceWave([]).isEmpty)
    }

    @Test func `Private proof uploads stay on authenticated storage and never become a CDN URL`() async throws {
        var captured: URLRequest?
        let api = NativeAPI(transport: { request in
            captured = request
            let key = try #require(request.url?.path.components(separatedBy: "/storage/v1/object/").last)
            return try response(request, .object(["Key": .string(key)]))
        })
        let bytes = Data([1, 2, 3])
        let path = try await api.uploadProofImage(data: bytes, contentType: "image/png", session: session)
        let request = try #require(captured)
        #expect(request.url?.host == NativeConfiguration.apiHost)
        #expect(request.url?.path == "/storage/v1/object/proofs/" + path)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(request.value(forHTTPHeaderField: "x-upsert") == "false")
        #expect(request.httpBody == bytes)
        #expect(path.hasPrefix(user + "/"))
        #expect(!path.contains("://"))
    }

    @Test func `Custom emoji tokens preserve Unicode ranges and reject malformed identities`() throws {
        let token = "<a:wave:\(messageID)>"
        let text = "🧡 " + token
        let matches = NativeEmojiTokens.matches(text)
        let match = try #require(matches.first)
        #expect(matches.count == 1)
        #expect(match.id == messageID)
        #expect(match.name == "wave")
        #expect(match.range.location == 3)
        #expect((text as NSString).substring(with: match.range) == token)
        #expect(NativeEmojiTokens.matches("<:bad:not-an-id>").isEmpty)
    }

    @Test func `Older search RPC receives supported filters while native filtering preserves sound results`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.url?.path.hasSuffix("search_messages_v4") == true { return try response(request, .object(["message": .string("schema cache")]), status: 404) }
            return try response(request, .array([]))
        })
        let result = try await api.searchMessages(NativeMessageSearch(query: "hello", has: "sound"), channelID: channel, session: session)
        #expect(result.isEmpty)
        #expect(requests.count == 2)
        #expect(requests[1].url?.path.hasSuffix("search_messages_v3") == true)
        #expect(try body(requests[1])["has"] == .null)
    }

    #if canImport(UIKit)
    @Test func `Native ImageIO decoding retains animation frames with a bounded pixel budget`() async throws {
        let bytes = try #require(CFDataCreateMutable(nil, 0))
        let output = try #require(CGImageDestinationCreateWithData(bytes, "com.compuserve.gif" as CFString, 2, nil))
        for index in 0..<2 {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
            let image = renderer.image { context in
                (index == 0 ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            let cg = try #require(image.cgImage)
            CGImageDestinationAddImage(output, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 0 ? 0.05 : 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(output))
        let decoded = try await NativeImageDecoder.decode(bytes as Data, maximumPixelSize: 96)
        #expect((decoded.image.images?.count ?? 0) >= 2)
        #expect(abs(decoded.image.duration - 0.15) < 0.02)
        #expect(decoded.cost > 0 && decoded.cost <= 32_000_000)
    }
    #endif
}
