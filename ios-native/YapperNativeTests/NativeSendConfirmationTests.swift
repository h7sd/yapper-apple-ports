import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeSendConfirmationTests {
    // Letters matter: all-digit fixtures cannot reproduce Swift/Postgres UUID casing.
    private let messageID = "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"
    private let channelID = "BCDEFABC-DEFA-4BCD-8EFA-BCDEFABCDEFA"
    private let authorID = "CDEFABCD-EFAB-4CDE-8FAB-CDEFABCDEFAB"
    private let otherID = "DEFABCDE-FABC-4DEF-8ABC-DEFABCDEFABC"

    private var session: NativeSession {
        NativeSession(accessToken: "synthetic-send-token", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: authorID)
    }

    private func row(id: String? = nil, channel: String? = nil, author: String? = nil, date: String = "2026-11-01T12:00:00.123Z") -> NativeJSON {
        .object(["id": .string(id ?? messageID.lowercased()), "channel_id": .string(channel ?? channelID.lowercased()),
                 "author_id": .string(author ?? authorID.lowercased()), "content": .string("Hello"), "created_at": .string(date)])
    }

    private func response(_ request: URLRequest, data: Data, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
        return (data, http)
    }

    private func response(_ request: URLRequest, json: NativeJSON, status: Int = 200) throws -> (Data, HTTPURLResponse) {
        try response(request, data: JSONEncoder().encode(json), status: status)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    private func expectIdentityLookup(_ request: URLRequest) {
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/rest/v1/messages")
        #expect(query(request, "id") == "eq.\(messageID)")
        #expect(query(request, "channel_id") == "eq.\(channelID)")
        #expect(query(request, "author_id") == "eq.\(authorID)")
        #expect(query(request, "select") == "*")
    }

    @Test(arguments: [false, true])
    func `A full acknowledgement confirms UUID identity regardless of letter case or row container`(array: Bool) async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            return try response(request, json: array ? .array([row()]) : row(), status: 201)
        })
        let confirmed = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session)
        #expect(confirmed.id == messageID.lowercased())
        #expect(confirmed.confirmsSend(id: messageID, channelID: channelID, authorID: authorID))
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.pgrst.object+json")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "return=representation")
        let body = try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))
        #expect(body["id"].string == messageID)
        #expect(body["created_at"] == .null)
    }

    @Test(arguments: ["empty201", "empty204", "null", "brokenJSON", "partialRow", "wrongID", "wrongChannel", "wrongAuthor", "multipleRows", "invalidDate"])
    func `An ambiguous successful insert is confirmed by one exact lookup without another insert`(kind: String) async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            guard request.httpMethod == "POST" else { return try response(request, json: .array([row()])) }
            switch kind {
            case "empty201": return try response(request, data: Data(), status: 201)
            case "empty204": return try response(request, data: Data(), status: 204)
            case "null": return try response(request, json: .null)
            case "brokenJSON": return try response(request, data: Data("{broken".utf8))
            case "partialRow": return try response(request, json: .object(["id": .string(messageID.lowercased())]))
            case "wrongID": return try response(request, json: row(id: otherID))
            case "wrongChannel": return try response(request, json: row(channel: otherID))
            case "wrongAuthor": return try response(request, json: row(author: otherID))
            case "multipleRows": return try response(request, json: .array([row(), row()]))
            default: return try response(request, json: row(date: "invalid"))
            }
        })
        let confirmed = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session)
        #expect(confirmed.confirmsSend(id: messageID, channelID: channelID, authorID: authorID))
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        expectIdentityLookup(try #require(requests.last))
    }

    @Test(arguments: ["empty", "wrongID", "wrongChannel", "wrongAuthor", "multipleRows", "invalidDate", "missingIdentity"])
    func `Reconciliation never turns an absent malformed or foreign row into success`(kind: String) async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.httpMethod == "POST" { return try response(request, data: Data(), status: 204) }
            let value: NativeJSON = switch kind {
            case "empty": .array([])
            case "wrongID": .array([row(id: otherID)])
            case "wrongChannel": .array([row(channel: otherID)])
            case "wrongAuthor": .array([row(author: otherID)])
            case "multipleRows": .array([row(), row()])
            case "invalidDate": .array([row(date: "invalid")])
            default: .array([.object(["id": .string(messageID)])])
            }
            return try response(request, json: value)
        })
        await #expect(throws: NativeClientError.invalidResponse) {
            _ = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session)
        }
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        expectIdentityLookup(try #require(requests.last))
    }

    @Test func `A real permission failure remains an error without a reconciliation request`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            return try response(request, json: .object(["message": .string("Permission denied")]), status: 403)
        })
        await #expect(throws: NativeClientError.api(status: 403, message: "Permission denied")) {
            _ = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session)
        }
        #expect(requests.map(\.httpMethod) == ["POST"])
    }

    @Test func `A retry after a lost response keeps its UUID and confirms a duplicate without another insert`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if requests.count == 1 { throw URLError(.networkConnectionLost) }
            if request.httpMethod == "POST" { return try response(request, json: .object(["message": .string("duplicate"), "code": .string("23505")]), status: 409) }
            return try response(request, json: .array([row()]))
        })
        await #expect(throws: URLError.self) { _ = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session) }
        let confirmed = try await api.send(id: messageID, text: "Hello", channelID: channelID, session: session)
        #expect(confirmed.confirmsSend(id: messageID, channelID: channelID, authorID: authorID))
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "GET"])
        let sentIDs = try requests.filter { $0.httpMethod == "POST" }.map { request in
            try JSONDecoder().decode(NativeJSON.self, from: #require(request.httpBody))["id"].string
        }
        #expect(sentIDs == [messageID, messageID])
        expectIdentityLookup(try #require(requests.last))
    }

    @Test func `Replies share identity checked empty acknowledgement reconciliation`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            if request.httpMethod == "POST" { return try response(request, data: Data(), status: 204) }
            return try response(request, json: .array([row()]))
        })
        try await api.sendReply(id: messageID, text: " Hello ", replyToID: otherID, channelID: channelID, session: session)
        #expect(requests.map(\.httpMethod) == ["POST", "GET"])
        let body = try JSONDecoder().decode(NativeJSON.self, from: #require(requests.first?.httpBody))
        #expect(body["reply_to_id"].string == otherID)
        #expect(body["content"].string == "Hello")
        expectIdentityLookup(try #require(requests.last))
    }

    @Test func `An already accepted attachment with normalized UUIDs is not uploaded or sent again`() async throws {
        var requests: [URLRequest] = []
        let api = NativeAPI(transport: { request in
            requests.append(request)
            return try response(request, json: .array([row()]))
        })
        try await api.sendAttachment(id: messageID, text: "Hello", data: Data(), filename: "fixture.png", contentType: "image/png", channelID: channelID, replyToID: nil, session: session)
        #expect(requests.count == 1)
        expectIdentityLookup(try #require(requests.first))
    }
}
