import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativePresenceTests {
    private let own = "11111111-1111-4111-8111-111111111111"
    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-presence-access", refreshToken: "synthetic-presence-refresh",
                      expiresAt: Date().addingTimeInterval(3600), userID: own)
    }

    @Test(arguments: NativePresencePreference.allCases)
    func `Own preference reads the exact authenticated RPC without notification prerequisites`(_ preference: NativePresencePreference) async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI { request in
            requests.append(request)
            let url = try #require(request.url)
            #expect(url.path == "/rest/v1/rpc/my_status_pref")
            #expect(url.query == nil)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-presence-access")
            #expect(request.value(forHTTPHeaderField: "apikey") == NativeConfiguration.anonymousKey)
            #expect(try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody)) == .object([:]))
            return (try JSONEncoder().encode(NativeJSON.string(preference.rawValue)),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let result = try await api.nativeOwnPresencePreference(session: session)
        #expect(result == NativeOwnPresencePreference(ownerID: own, preference: preference))
        #expect(result.status == preference.rawValue)
        #expect(requests.count == 1)
    }

    @Test(arguments: NativePresencePreference.allCases)
    func `Successful null retains the local default while a fresh account defaults online`(_ local: NativePresencePreference) async throws {
        var calls = 0
        let api = NativeAPI { request in
            calls += 1
            let url = try #require(request.url)
            #expect(url.lastPathComponent == "my_status_pref")
            return (Data("null".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let retained = try await api.nativeOwnPresencePreference(session: session, defaultPreference: local)
        #expect(retained.preference == local)
        let fresh = try await api.nativeOwnPresencePreference(session: session)
        #expect(fresh.preference == .online)
        #expect(calls == 2)
    }

    @Test func `Successful null sound policy keeps cached DND silent and defaults a fresh account online`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in
            let url = try #require(request.url)
            paths.append(url.lastPathComponent)
            let data = switch url.lastPathComponent {
            case "my_status_pref": Data("null".utf8)
            case "blocks": Data("[]".utf8)
            default: throw NativeClientError.invalidEndpoint
            }
            return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        let cachedDND = try await api.nativeNotificationSoundPolicy(mutedIDs: [], session: session, defaultPreference: .dnd)
        #expect(cachedDND.status == "dnd")
        #expect(!cachedDND.canDisturb)
        let fresh = try await api.nativeNotificationSoundPolicy(mutedIDs: [], session: session)
        #expect(fresh.status == "online")
        #expect(fresh.canDisturb)
        #expect(paths == ["my_status_pref", "blocks", "my_status_pref", "blocks"])
    }

    @Test(arguments: [NativeJSON.string("unknown"), .string("offline"), .string("ONLINE"),
                      .string(" online"), .number(1), .array([.string("online")]), .object(["status": .string("online")])])
    func `Malformed preference never guesses online or writes a replacement`(_ value: NativeJSON) async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI { request in
            requests.append(request)
            let url = try #require(request.url)
            return (try JSONEncoder().encode(value),
                    try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: NativeClientError.invalidResponse) { try await api.nativeOwnPresencePreference(session: session) }
        #expect(requests.count == 1)
        #expect(requests.first?.url?.lastPathComponent == "my_status_pref")
    }

    @Test func `An empty successful body is malformed rather than a null default`() async throws {
        let api = NativeAPI { request in
            let url = try #require(request.url)
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: NativeClientError.malformedResponse("RPC response")) {
            try await api.nativeOwnPresencePreference(session: session, defaultPreference: .dnd)
        }
    }

    @Test func `Preference transport and server errors propagate without extra requests`() async throws {
        var calls = 0
        let offlineAPI = NativeAPI { request in
            calls += 1
            #expect(request.url?.lastPathComponent == "my_status_pref")
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: URLError.self) { try await offlineAPI.nativeOwnPresencePreference(session: session) }
        #expect(calls == 1)

        let deniedAPI = NativeAPI { request in
            calls += 1
            let url = try #require(request.url)
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: NativeClientError.self) { try await deniedAPI.nativeOwnPresencePreference(session: session) }
        #expect(calls == 2)

        let malformedAPI = NativeAPI { request in
            calls += 1
            let url = try #require(request.url)
            return (Data("not-json".utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
        await #expect(throws: NativeClientError.malformedResponse("RPC response")) {
            try await malformedAPI.nativeOwnPresencePreference(session: session)
        }
        #expect(calls == 3)
    }

    @Test func `Optional sound policy failure cannot prevent an independent DND preference read`() async throws {
        var paths: [String] = []
        let api = NativeAPI { request in
            let url = try #require(request.url)
            paths.append(url.lastPathComponent)
            let response: HTTPURLResponse
            let data: Data
            switch url.lastPathComponent {
            case "my_status_pref":
                response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                data = try JSONEncoder().encode(NativeJSON.string("dnd"))
            case "blocks":
                response = try #require(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil))
                data = Data()
            default:
                Issue.record("Unexpected presence request: \(url.path)")
                throw NativeClientError.invalidEndpoint
            }
            return (data, response)
        }
        let preference = try await api.nativeOwnPresencePreference(session: session)
        #expect(preference.preference == .dnd)
        #expect(paths == ["my_status_pref"])
        await #expect(throws: NativeClientError.self) {
            try await api.nativeNotificationSoundPolicy(mutedIDs: [], session: session)
        }
        #expect(preference.status == "dnd")
        #expect(paths == ["my_status_pref", "my_status_pref", "blocks"])
        let refreshed = try await api.nativeOwnPresencePreference(session: session)
        #expect(refreshed == preference)
        #expect(paths.last == "my_status_pref")
    }

    @Test func `Auto idle follows the ten minute activity boundary and respects explicit preferences`() {
        let activity = Date(timeIntervalSince1970: 100)
        #expect(!NativePresencePreference.online.isAutomaticallyIdle(lastActivityAt: activity, now: activity.addingTimeInterval(599.999)))
        #expect(NativePresencePreference.online.isAutomaticallyIdle(lastActivityAt: activity, now: activity.addingTimeInterval(600)))
        #expect(!NativePresencePreference.online.isAutomaticallyIdle(lastActivityAt: activity, now: activity.addingTimeInterval(-1)))
        #expect(NativePresencePreference.online.profileStatus(autoIdle: true) == "idle")
        #expect(NativePresencePreference.online.profileStatus(autoIdle: false) == "online")
        for preference in [NativePresencePreference.idle, .dnd, .invisible] {
            #expect(!preference.isAutomaticallyIdle(lastActivityAt: activity, now: activity.addingTimeInterval(3600)))
            #expect(preference.profileStatus(autoIdle: true) == preference.rawValue)
        }
        #expect(NativePresencePreference.invisible.profileStatus(autoIdle: false) == "invisible")
        #expect(NativePresencePreference.invisible.visibleStatus(autoIdle: false) == "offline")
        #expect(NativePresencePreference.dnd.visibleStatus(autoIdle: true) == "dnd")
    }
}
