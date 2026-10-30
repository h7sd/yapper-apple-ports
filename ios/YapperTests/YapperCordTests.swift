import Foundation
import Testing
import WebKit
@testable import Yapper

struct YapperCordTests {
    @Test func disabledUntilExplicitlyEnabled() throws {
        let suite = "YapperCordTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: YapperAppearanceSupport.preferenceKey)
        let client = WebClient(preferences: preferences, ephemeralSession: true)
        #expect(!client.yapperCordEnabled)
        #expect(!preferences.bool(forKey: YapperCordSupport.preferenceKey))
        #expect(client.webView.configuration.userContentController.userScripts.count == 2)
        #expect(client.webView.scrollView.contentInsetAdjustmentBehavior == .never)
        #expect(!client.webView.scrollView.automaticallyAdjustsScrollIndicatorInsets)
        #expect(client.webView.configuration.userContentController.userScripts.first?.isForMainFrameOnly == true)
    }

    @Test(arguments: [
        ("https://www.yapper.website/", false, true),
        ("https://yapin.gg/", false, true),
        ("https://example.com/", false, false),
        ("https://www.yapper.website.evil.example/", false, false),
        ("http://www.yapper.website/", false, false),
        ("https://www.yapper.website:444/", false, false),
        ("https://user:password@www.yapper.website/", false, false),
        ("https://www.yapper.website/", true, false)
    ])
    func originAndFrameGuardRunsInWebKit(_ input: (String, Bool, Bool)) async throws {
        let view = WKWebView()
        view.loadHTMLString("<!doctype html><html><body>Guard test</body></html>", baseURL: nil)
        try await waitUntilLoaded(view)
        let source = YapperCordSupport.guardedSource("window.scopeMarker = true;")
        let result: String = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript("const fake = {location:{href}}; fake.self = fake; fake.top = iframe ? {} : fake; new Function('window', source)(fake); return String(fake.scopeMarker === true);", arguments: ["href": input.0, "iframe": input.1, "source": source], in: nil, in: .page, completionHandler: { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            })
        }
        #expect(result == String(input.2))
    }

    @Test func liveRuntimeCanBeDisabledWithoutChangingDesktopBridge() async throws {
        let suite = "YapperCordTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(false, forKey: YapperAppearanceSupport.preferenceKey)
        let client = WebClient(preferences: preferences, ephemeralSession: true)
        #expect(client.setYapperCordEnabled(true))
        let view = client.webView
        try await waitUntilLoaded(view, client: client)
        let initial = try await run("return JSON.stringify({available: typeof window.YapperCord?.open === 'function', canonicalAlias: window.Yapinplugger === window.YapperCord, viewport: document.querySelector('meta[name=viewport]')?.content.includes('viewport-fit=cover') === true, members: Object.keys(window.yapperDesktop).length});", in: view)
        let result = try #require(JSONSerialization.jsonObject(with: Data(initial.utf8)) as? [String: Any])
        #expect(result["available"] as? Bool == true)
        #expect(result["canonicalAlias"] as? Bool == true)
        #expect(result["viewport"] as? Bool == true)
        #expect(result["members"] as? Int == 17)
        #expect(preferences.bool(forKey: YapperCordSupport.preferenceKey))
        let iframe = try await run("const frame = document.createElement('iframe'); frame.hidden = true; frame.srcdoc = '<!doctype html><html><body>Isolated frame</body></html>'; const loaded = new Promise(resolve => { frame.onload = () => resolve(true); setTimeout(() => resolve(false), 5000); }); document.body.append(frame); if (!await loaded) { frame.remove(); throw new Error('Iframe did not load'); } const result = JSON.stringify({cord: typeof frame.contentWindow.YapperCord, desktop: typeof frame.contentWindow.yapperDesktop, viewport: String(frame.contentDocument.documentElement.hasAttribute('data-yapper-ios-viewport'))}); frame.remove(); return result;", in: view)
        let frameResult = try #require(JSONSerialization.jsonObject(with: Data(iframe.utf8)) as? [String: String])
        #expect(frameResult == ["cord": "undefined", "desktop": "undefined", "viewport": "false"])
        #expect(client.setYapperCordEnabled(false))
        try await waitUntilLoaded(view, client: client)
        let disabled = try await run("return JSON.stringify({cord: typeof window.YapperCord, members: Object.keys(window.yapperDesktop).length});", in: view)
        let disabledResult = try #require(JSONSerialization.jsonObject(with: Data(disabled.utf8)) as? [String: Any])
        #expect(disabledResult["cord"] as? String == "undefined")
        #expect(disabledResult["members"] as? Int == 17)
        #expect(!preferences.bool(forKey: YapperCordSupport.preferenceKey))
    }

    @Test func externalDocumentCannotReceiveTheRuntime() async throws {
        let source = try #require(YapperCordSupport.bundledSource())
        let appearance = try #require(YapperAppearanceSupport.bundledSource())
        let viewport = TrustedDocumentScript.guardedSource(try #require(YapperViewportSupport.rawSource()))
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: appearance, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(URLRequest(url: URL(string: "https://example.com")!))
        try await waitUntilLoaded(view)
        let result = try await run("return JSON.stringify({origin: location.origin, cord: typeof window.YapperCord, appearance: typeof window.YapperAppearance, desktop: typeof window.yapperDesktop, viewport: String(document.documentElement.hasAttribute('data-yapper-ios-viewport'))});", in: view)
        let actual = try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
        #expect(actual["origin"] == "https://example.com")
        #expect(actual["cord"] == "undefined")
        #expect(actual["appearance"] == "undefined")
        #expect(actual["desktop"] == "undefined")
        #expect(actual["viewport"] == "false")
    }

    private func waitUntilLoaded(_ view: WKWebView, client: WebClient? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            if let client { if !client.loading { break } }
            else if !view.isLoading { break }
        } while ContinuousClock.now < deadline
        try #require(!view.isLoading)
        if let client { try #require(!client.loading && client.failure == nil) }
    }

    private func run(_ source: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page, completionHandler: { result in
                switch result {
                case .success(let value):
                    if let value = value as? String { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: NSError(domain: "YapperCordTests", code: 1)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            })
        }
    }
}
