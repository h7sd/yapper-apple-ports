import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeCallLifecycleTests {
    private let userID = "11111111-1111-4111-8111-111111111111"
    private let channelID = "22222222-2222-4222-8222-222222222222"
    private func signedInStore(log: NativeCallRequestLog, ticket: NativeCallHTTPGate? = nil, firstEnd: NativeCallHTTPGate? = nil) async -> NativeStore {
        let api = NativeAPI(transport: { request in
            let path = request.url!.path
            log.paths.append(path)
            var data = Data("null".utf8), status = 200
            switch path {
            case "/rest/v1/rpc/bootstrap":
                data = Data("{\"profiles\":[{\"id\":\"\(userID)\",\"username\":\"synthetic\"}],\"dm_channels\":[],\"dm_members\":[]}".utf8)
            case "/api/livekit-token":
                if let ticket, log.paths.filter({ $0 == path }).count == 1 { return await ticket.wait(request) }
                data = Data("{\"error\":\"Synthetic ticket failure\"}".utf8); status = 503
            case "/rest/v1/rpc/end_call":
                if let firstEnd, log.paths.filter({ $0 == path }).count == 1 { return await firstEnd.wait(request) }
            default: break
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: userID)
        let store = NativeStore(api: api, vault: MemorySessionVault(session: session), realtime: nil)
        await store.restoreSession()
        return store
    }

    @Test func `Ticket failure closes a successfully started outgoing ring without creating media`() async {
        let log = NativeCallRequestLog()
        let store = await signedInStore(log: log)
        let call = NativeCallController()
        await call.join(store: store, channelID: channelID, title: "Synthetic")
        #expect(log.count("start_call") == 1)
        #expect(log.count("end_call") == 1)
        #expect(call.room == nil)
        #expect(!call.isConnecting)
        #expect(call.errorMessage != nil)
    }

    @Test func `Leaving one connected group member preserves an ongoing published call`() {
        #expect(!NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: true, didConnect: true, finishConnectedCall: true, remoteParticipants: [NativeCallPresence(identity: userID, audioTrackCount: 1)]))
        #expect(NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: false, didConnect: true, finishConnectedCall: true, remoteParticipants: [NativeCallPresence(identity: userID + ":screen", audioTrackCount: 0)]))
        #expect(NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: true, didConnect: false, finishConnectedCall: false, remoteParticipants: []))
        #expect(!NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: false, didConnect: true, finishConnectedCall: false, remoteParticipants: []))
        #expect(!NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: userID, startedRing: true, didConnect: true, finishConnectedCall: true, remoteParticipants: []))
    }

    @Test func `Muted native listeners and unknown identities preserve a connected group call`() {
        for identity in [userID, "unknown:screen", nil] {
            #expect(!NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: true, didConnect: true, finishConnectedCall: true, remoteParticipants: [NativeCallPresence(identity: identity, audioTrackCount: 0)]))
        }
        #expect(!NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: true, didConnect: true, finishConnectedCall: true, remoteParticipants: [NativeCallPresence(identity: userID + ":screen", audioTrackCount: 1)]))
        #expect(NativeCallLifecyclePolicy.shouldEndGlobalCall(serverID: nil, startedRing: true, didConnect: true, finishConnectedCall: true, remoteParticipants: []))
    }

    @Test func `Only UUID screen companions are excluded from no-answer participant counting`() {
        #expect(NativeCallLifecyclePolicy.isScreenCompanion(userID + ":screen"))
        #expect(!NativeCallLifecyclePolicy.isScreenCompanion(userID))
        #expect(!NativeCallLifecyclePolicy.isScreenCompanion("stranger:screen"))
    }

    @Test func `Cancel while the ticket is pending ends the ring once and cannot resurrect it`() async {
        let log = NativeCallRequestLog(), ticket = NativeCallHTTPGate()
        let store = await signedInStore(log: log, ticket: ticket)
        let call = NativeCallController()
        let joining = Task { await call.join(store: store, channelID: channelID, title: "Synthetic") }
        await ticket.started()
        await call.leave()
        #expect(log.count("end_call") == 1)
        ticket.finish(status: 503)
        await joining.value
        #expect(log.count("end_call") == 1)
        #expect(call.channelID == nil)
        #expect(call.room == nil)
        #expect(!call.isConnecting)
    }

    @Test func `A replacement cannot start before the previous end request finishes`() async {
        let log = NativeCallRequestLog(), ticket = NativeCallHTTPGate(), ending = NativeCallHTTPGate()
        let store = await signedInStore(log: log, ticket: ticket, firstEnd: ending)
        let call = NativeCallController()
        let first = Task { await call.join(store: store, channelID: channelID, title: "First synthetic") }
        await ticket.started()
        let leaving = Task { await call.leave() }
        await ending.started()
        let replacement = Task { await call.join(store: store, channelID: channelID, title: "Second synthetic") }
        await Task.yield()
        #expect(log.count("start_call") == 1)
        ending.finish(status: 200)
        await leaving.value
        await replacement.value
        ticket.finish(status: 503)
        await first.value
        #expect(log.count("start_call") == 2)
        #expect(log.count("end_call") == 2)
        #expect(call.title == "Second synthetic")
        #expect(call.room == nil)
        #expect(!call.isConnecting)
    }
}

@MainActor private final class NativeCallRequestLog {
    var paths: [String] = []
    func count(_ rpc: String) -> Int { paths.filter { $0 == "/rest/v1/rpc/" + rpc }.count }
}

@MainActor private final class NativeCallHTTPGate {
    private var request: URLRequest?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    func wait(_ request: URLRequest) async -> (Data, HTTPURLResponse) {
        self.request = request
        startedContinuation?.resume(); startedContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    func finish(status: Int) {
        guard let request, let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        let data = Data((status == 200 ? "null" : "{\"error\":\"Synthetic delayed failure\"}").utf8)
        continuation?.resume(returning: (data, response)); continuation = nil
    }
}
