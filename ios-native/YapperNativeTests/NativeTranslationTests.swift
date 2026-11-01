import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeTranslationTests {
    @Test func `Code URLs mentions and custom emoji survive translated placeholder changes`() throws {
        let source = "Hallo `let x = 1` https://example.invalid <@nova> <:happy:abc-def>"
        let content = try NativeTranslationContent(source)
        #expect(content.text == "Hallo {{0}} {{1}} {{2}} {{3}}")
        #expect(content.restore("Hello {{ 0 }} {{1}} {{2}} {{3}}") == "Hello `let x = 1` https://example.invalid <@nova> <:happy:abc-def>")
        #expect(content.restore("Hello {{0}} {{8}}") == "Hello `let x = 1` {{8}} https://example.invalid <@nova> <:happy:abc-def>")
    }

    @Test func `Only protected content has nothing to translate`() {
        #expect(throws: (any Error).self) { try NativeTranslationContent("https://example.invalid `hello` <@nova> 123") }
    }

    @Test(arguments: [("de-DE", "de"), ("zh-Hant-TW", "zh-TW"), ("zh-SG", "zh-CN"), ("pt_BR", "pt")])
    func `Target language follows the device language contract`(input: String, expected: String) {
        #expect(NativeTranslationContent.targetLanguage(input) == expected)
    }

    @Test func `Native translation sends protected text and bearer only to the canonical API`() async throws {
        let session = NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: "11111111-1111-4111-8111-111111111111")
        let api = NativeAPI(transport: { request in
            #expect(request.url?.absoluteString == "https://www.yapin.gg/api/translate")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
            let data = try #require(request.httpBody)
            let body = try JSONDecoder().decode(NativeJSON.self, from: data)
            #expect(body["text"].string == "Hello {{0}}")
            #expect(body["to"].string == "de")
            return (Data(#"{"text":"Hallo {{0}}","from":"en"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = try await NativeMessageTranslationService(api: api).translate("Hello `x`", language: "de-DE", session: session)
        #expect(result == "Hallo `x`")
    }
}
