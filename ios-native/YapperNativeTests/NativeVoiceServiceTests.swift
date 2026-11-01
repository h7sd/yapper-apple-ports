import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeVoiceServiceTests {
    private let sid = "11111111-1111-4111-8111-111111111111"
    private let uid = "22222222-2222-4222-8222-222222222222"
    private let target = "33333333-3333-4333-8333-333333333333"
    private let cid = "44444444-4444-4444-8444-444444444444"
    private let destination = "55555555-5555-4555-8555-555555555555"
    private var session: NativeSession { NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: uid) }

    private func snapshot(owner: String? = nil) throws -> NativeServerSnapshot {
        let server = try NativeServer(.object(["id": .string(sid), "name": .string("Synthetic"), "owner_id": .string(owner ?? uid)]))
        let channels = try [cid, destination].map { id in try NativeServerChannel(.object(["id": .string(id), "server_id": .string(sid), "name": .string("Voice"), "kind": .string("voice")]), serverID: sid) }
        return NativeServerSnapshot(server: server, channels: channels, categories: [], members: [], roles: [], memberRoles: [:])
    }

    private func http(_ request: URLRequest, _ json: NativeJSON = .null) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (try JSONEncoder().encode(json), response)
    }

    @Test func `Voice move targets an authorized same-server voice channel and canonical endpoint`() async throws {
        let api = NativeAPI(transport: { request in
            #expect(request.url?.absoluteString == "https://www.yapin.gg/api/voice/moderate")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
            let data = try #require(request.httpBody)
            let body = try JSONDecoder().decode(NativeJSON.self, from: data)
            #expect(body == .object(["channelId": .string(cid), "userId": .string(target), "action": .string("move"), "toChannelId": .string(destination)]))
            return try http(request)
        })
        try await NativeVoiceService(api: api).moderate(.move, channelID: cid, userID: target, snapshot: snapshot(), destination: destination, session: session)
    }

    @Test func `Missing permissions self targeting and foreign destinations never reach transport`() async throws {
        let api = NativeAPI(transport: { request in Issue.record("Invalid moderation reached transport"); return try http(request) })
        let service = NativeVoiceService(api: api)
        await #expect(throws: (any Error).self) { try await service.moderate(.kick, channelID: cid, userID: target, snapshot: snapshot(owner: target), session: session) }
        await #expect(throws: (any Error).self) { try await service.moderate(.mute, channelID: cid, userID: uid, snapshot: snapshot(), session: session) }
        await #expect(throws: (any Error).self) { try await service.moderate(.move, channelID: cid, userID: target, snapshot: snapshot(), destination: target, session: session) }
    }

    @Test func `Voice bans use server scope while ordinary mute uses channel scope`() async throws {
        let log = VoiceRequestLog()
        let api = NativeAPI(transport: { request in
            let data = try #require(request.httpBody)
            log.bodies.append(try JSONDecoder().decode(NativeJSON.self, from: data))
            return try http(request)
        })
        let service = NativeVoiceService(api: api)
        try await service.moderate(.voiceban, channelID: cid, userID: target, snapshot: snapshot(), minutes: 60, reason: "Synthetic reason", session: session)
        try await service.moderate(.mute, channelID: cid, userID: target, snapshot: snapshot(), minutes: 10, session: session)
        #expect(log.bodies[0] == .object(["serverId": .string(sid), "userId": .string(target), "action": .string("voiceban"), "minutes": .number(60), "reason": .string("Synthetic reason")]))
        #expect(log.bodies[1] == .object(["channelId": .string(cid), "userId": .string(target), "action": .string("mute"), "minutes": .number(10)]))
    }

    @Test func `A voice report uses the observed RPC before best effort enforcement without recording`() async throws {
        let log = VoiceRequestLog()
        let api = NativeAPI(transport: { request in
            log.paths.append(request.url!.path)
            let data = try #require(request.httpBody)
            log.bodies.append(try JSONDecoder().decode(NativeJSON.self, from: data))
            return try http(request, .string(target))
        })
        try await NativeVoiceService(api: api).report(channelID: cid, userID: target, reason: "other", details: "Synthetic report", session: session)
        #expect(log.paths == ["/rest/v1/rpc/report_voice", "/api/voice/moderate"])
        #expect(log.bodies[0] == .object(["uid": .string(target), "vchannel": .string(cid), "why": .string("other"), "more": .string("Synthetic report")]))
        #expect(log.bodies[1]["action"].string == "enforce")
    }

    @Test func `Expired voice bans are filtered and unban remains permission and server scoped`() async throws {
        let log = VoiceRequestLog()
        let api = NativeAPI(transport: { request in
            log.paths.append(request.url!.path)
            if request.url!.lastPathComponent == "server_voice_bans" {
                return try http(request, .array([.object(["user_id": .string(target), "until": .null]), .object(["user_id": .string(uid), "until": .string("2000-01-01T00:00:00Z")])]))
            }
            let data = try #require(request.httpBody)
            let body = try JSONDecoder().decode(NativeJSON.self, from: data)
            #expect(body == .object(["sid": .string(sid), "uid": .string(target)]))
            return try http(request)
        })
        let service = NativeVoiceService(api: api)
        #expect(try await service.bans(serverID: sid, session: session).count == 1)
        try await service.unban(userID: target, snapshot: snapshot(), session: session)
        #expect(log.paths.last == "/rest/v1/rpc/voice_unban")
    }
}

@MainActor private final class VoiceRequestLog { var bodies: [NativeJSON] = []; var paths: [String] = [] }
