import Foundation
import Testing
import WebKit
@testable import Yapper

struct YapperAppearanceTests {
    @Test func profileLayoutDefaultsOnAndCanBeReverted() throws {
        let suite = "YapperAppearanceTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = WebClient(preferences: preferences, ephemeralSession: true)
        #expect(client.enhancedProfileLayoutEnabled)
        #expect(!client.yapperCordEnabled)
        #expect(client.setEnhancedProfileLayoutEnabled(false))
        #expect(!client.enhancedProfileLayoutEnabled)
        #expect(!preferences.bool(forKey: YapperAppearanceSupport.preferenceKey))
        let restored = WebClient(preferences: preferences, ephemeralSession: true)
        #expect(!restored.enhancedProfileLayoutEnabled)
        #expect(!restored.yapperCordEnabled)
    }

    @Test func liveLayoutCleanupAndCordPreferenceStayIndependent() async throws {
        let suite = "YapperAppearanceTests." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let client = WebClient(preferences: preferences, ephemeralSession: true)
        let view = client.webView
        try await wait(client)
        let initial = try await object("return JSON.stringify({appearance: typeof window.YapperAppearance?.destroy === 'function', disposed: window.YapperAppearance?.getState().disposed, cord: typeof window.YapperCord, members: Object.keys(window.yapperDesktop).length});", in: view)
        #expect(initial["appearance"] as? Bool == true)
        #expect(initial["disposed"] as? Bool == false)
        #expect(initial["cord"] as? String == "undefined")
        #expect(initial["members"] as? Int == 17)
        let frame = try await object("const frame = document.createElement('iframe'); frame.hidden = true; frame.srcdoc = '<!doctype html><html><body>Isolated frame</body></html>'; const loaded = new Promise(resolve => { frame.onload = () => resolve(true); setTimeout(() => resolve(false), 5000); }); document.body.append(frame); if (!await loaded) { frame.remove(); throw new Error('Iframe did not load'); } const result = JSON.stringify({appearance: typeof frame.contentWindow.YapperAppearance, cord: typeof frame.contentWindow.YapperCord, desktop: typeof frame.contentWindow.yapperDesktop}); frame.remove(); return result;", in: view)
        #expect(frame["appearance"] as? String == "undefined")
        #expect(frame["cord"] as? String == "undefined")
        #expect(frame["desktop"] as? String == "undefined")
        let cleanup = try await object("const retained = window.YapperAppearance; retained.destroy(); retained.refresh(); return JSON.stringify({disposed: retained.getState().disposed, appearance: typeof window.YapperAppearance});", in: view)
        #expect(cleanup["disposed"] as? Bool == true)
        #expect(cleanup["appearance"] as? String == "undefined")
        #expect(client.setEnhancedProfileLayoutEnabled(false))
        try await wait(client)
        let disabled = try await object("return JSON.stringify({appearance: typeof window.YapperAppearance, members: Object.keys(window.yapperDesktop).length});", in: view)
        #expect(disabled["appearance"] as? String == "undefined")
        #expect(disabled["members"] as? Int == 17)
        #expect(client.setEnhancedProfileLayoutEnabled(true))
        try await wait(client)
        #expect(client.setYapperCordEnabled(true))
        try await wait(client)
        let both = try await object("return JSON.stringify({appearance: typeof window.YapperAppearance?.destroy === 'function', cord: typeof window.YapperCord?.open === 'function'});", in: view)
        #expect(both["appearance"] as? Bool == true)
        #expect(both["cord"] as? Bool == true)
        #expect(client.setEnhancedProfileLayoutEnabled(false))
        try await wait(client)
        let independent = try await object("return JSON.stringify({appearance: typeof window.YapperAppearance, cord: typeof window.YapperCord?.open === 'function', members: Object.keys(window.yapperDesktop).length});", in: view)
        #expect(independent["appearance"] as? String == "undefined")
        #expect(independent["cord"] as? Bool == true)
        #expect(independent["members"] as? Int == 17)
        #expect(client.yapperCordEnabled)
        #expect(!client.enhancedProfileLayoutEnabled)
    }

    private func wait(_ client: WebClient) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        repeat { try await Task.sleep(for: .milliseconds(200)) }
        while client.loading && ContinuousClock.now < deadline
        try #require(!client.loading && client.failure == nil)
    }

    private func object(_ source: String, in view: WKWebView) async throws -> [String: Any] {
        let text: String = try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(source, arguments: [:], in: nil, in: .page, completionHandler: { result in
                switch result {
                case .success(let value):
                    if let value = value as? String { continuation.resume(returning: value) }
                    else { continuation.resume(throwing: NSError(domain: "YapperAppearanceTests", code: 1)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            })
        }
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
