import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeAccountDataTests {
    private let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: "11111111-1111-4111-8111-111111111111")

    @Test func `Export preserves original bytes and exposes incomplete sections`() async throws {
        let data = Data(#"{"export_complete":true,"complete":false,"cut_short":["messages"],"could_not_load":["media"],"sections":{}}"#.utf8)
        let log = AccountDataRequestLog()
        let api = NativeAPI(transport: { request in
            log.requests.append(request)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await NativeAccountDataService(api: api).export(session: session)
        #expect(result.data == data)
        #expect(!result.complete)
        #expect(result.cutShort == ["messages"])
        #expect(result.couldNotLoad == ["media"])
        let request = try #require(log.requests.first)
        #expect(request.url?.absoluteString == "https://www.yapin.gg/api/me/export")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
        #expect(request.value(forHTTPHeaderField: "apikey") == nil)
    }

    @Test func `Interrupted export cannot become a downloadable complete file`() throws {
        #expect(throws: (any Error).self) { try NativeAccountExport(data: Data(#"{"complete":true}"#.utf8)) }
    }

    @Test func `A failed password check prevents all media and deletion requests`() async {
        let log = AccountDataRequestLog()
        let api = NativeAPI(transport: { request in
            log.requests.append(request)
            return (Data(#""Password incorrect""#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do { try await NativeAccountDataService(api: api).deleteAccount(password: "synthetic-password", gdprDelete: true, session: session); Issue.record("Deletion must fail") }
        catch { }
        #expect(log.requests.map { $0.url!.path } == ["/rest/v1/rpc/reauth_check"])
    }

    @Test(arguments: [true, false]) func `Deletion uses the selected observed contract only after reauthentication and scoped media cleanup`(gdpr: Bool) async throws {
        let log = AccountDataRequestLog()
        let uid = session.userID
        let api = NativeAPI(transport: { request in
            log.requests.append(request)
            let path = request.url!.path
            let body = if path == "/storage/v1/object/list/avatars" { #"[{"id":"file","name":"avatar.png"},{"name":"subfolder"}]"# }
                       else if path.contains("/storage/v1/object/list/") { "[]" }
                       else { "null" }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await NativeAccountDataService(api: api).deleteAccount(password: "synthetic-password", gdprDelete: gdpr, session: session)
        #expect(log.requests.first?.url?.path == "/rest/v1/rpc/reauth_check")
        let cleanup = try #require(log.requests.first { $0.httpMethod == "DELETE" })
        let data = try #require(cleanup.httpBody)
        let json = try JSONDecoder().decode(NativeJSON.self, from: data)
        #expect(json["prefixes"] == .array([.string(uid + "/avatar.png")]))
        let deletionPaths = log.requests.map { $0.url!.path }.filter { $0.contains("/account/delete") || $0.contains("/rpc/delete_my_account") }
        #expect(deletionPaths == [gdpr ? "/api/account/delete" : "/rest/v1/rpc/delete_my_account"])
        #expect(log.requests.last?.url?.path == "/auth/v1/logout")
        #expect(log.requests.filter { $0.url!.path.contains("/storage/") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" })
    }
}

@MainActor private final class AccountDataRequestLog { var requests: [URLRequest] = [] }
