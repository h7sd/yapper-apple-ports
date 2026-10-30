import Foundation
import Testing
import WebKit
@testable import Yapper

struct URLPolicyTests {
    @MainActor @Test func liveWebKitBridgeRoundTripUsesNativeHandler() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.bool(forKey: "nativeNotifications")
        defaults.set(false, forKey: "nativeNotifications")
        defer { defaults.set(previous, forKey: "nativeNotifications") }
        let client = WebClient(ephemeralSession: true)
        let webView = client.webView
        let deadline = ContinuousClock.now + .seconds(40)
        while client.loading && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(200)) }
        try #require(client.failure == nil, "The actual trusted Yapper document must load for this integration check.")
        let text: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("return JSON.stringify({settings: await window.yapperDesktop.getSettings(), refusedBadge: await window.yapperDesktop.setBadge(1), noHotkeys: await window.yapperDesktop.setHotkeys({ptt: 'KeyA'}), members: Object.keys(window.yapperDesktop)});", arguments: [:], in: nil, in: .page, completionHandler: { result in
                switch result {
                case .success(let value):
                    if let value = value as? String { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: NSError(domain: "BridgeTest", code: 1)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            })
        }
        let data = try #require(text.data(using: .utf8))
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try #require(result["settings"] as? [String: Any])
        #expect(settings["platform"] as? String == "ios")
        #expect(settings["nativeNotifications"] as? Bool == false)
        #expect(result["refusedBadge"] as? Bool == false)
        #expect((result["members"] as? [String])?.count == 17)
        #expect((result["noHotkeys"] as? [String: Bool]) == ["ptt": false, "keys": false])
    }

    @Test(arguments: ["https://www.yapper.website/", "https://yapper.website:443/invite/abc", "https://yapin.gg/?channel=abc", "https://lk.yapper.website/"])
    func permitsTrustedHTTPS(_ string: String) { #expect(URLPolicy.isTrusted(URL(string: string))) }

    @Test(arguments: ["http://www.yapper.website/", "https://yapper.website.evil.example/", "https://www.yapper.website:444/", "https://account@www.yapper.website/", "https://user:pass@yapper.website/", "file:///etc/passwd", "javascript:alert(1)", "https://evil.example/?https://www.yapper.website"])
    func rejectsUntrustedNativeOrigins(_ string: String) { #expect(!URLPolicy.isTrusted(URL(string: string))) }

    @Test func preservesInviteQueryAndFragment() throws {
        let input = try #require(URL(string: "yapper://invite/abc?source=ios#join"))
        let output = try #require(URLPolicy.deepLink(input))
        #expect(output.absoluteString == "https://www.yapper.website/invite/abc?source=ios#join")
    }

    @Test(arguments: ["yapper://user:pass@evil.example/", "https://www.yapper.website/invite/abc", "file:///invite/abc", "yapper://invite:444/abc"])
    func rejectsMalformedDeepLinks(_ string: String) throws { #expect(URLPolicy.deepLink(try #require(URL(string: string))) == nil) }

    @Test(arguments: ["//evil.example/path", "\\\\evil.example/path", "@evil.example", "https://evil.example", "/?next=https://evil.example", "%2F%2Fevil.example"])
    func notificationPathsCannotChangeOrigin(_ path: String) {
        let url = URLPolicy.siteURL(for: path)
        #expect(URLPolicy.isTrusted(url))
        #expect(url.host == "www.yapper.website")
        #expect(url.user == nil)
    }

    @Test(arguments: ["javascript:alert(1)", "file:///private/data", "tel:+1234", "data:text/html,test", "https://user:password@example.com"])
    func externalURLsCannotInvokeNativeSchemes(_ string: String) throws { #expect(!URLPolicy.canOpenExternally(try #require(URL(string: string)))) }
}
