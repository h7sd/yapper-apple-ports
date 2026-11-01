import Foundation
import Testing
@testable import YapperNative

@MainActor @Suite struct NativeChatAppearanceTests {
    private let uid = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let other = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    @Test(arguments: NativeChatTint.presets)
    func `All official colour presets resolve from their account key`(_ preset: NativeChatTint.Preset) throws {
        let tint = try NativeChatTint(.object(["key": .string(preset.key)]))
        #expect(tint.a == preset.a)
        #expect(tint.b == preset.b)
        #expect(tint.c == preset.b)
        #expect(tint.intensity == 0.75)
    }

    @Test func `Custom colours and strength follow official fallbacks and clamps`() throws {
        let custom = try NativeChatTint(.object(["key": .string("custom"), "a": .string("#123456"), "b": .string("#ABCDEF"), "c": .string("#102030"), "k": .number(2)]))
        #expect(custom.a == NativeAppearanceRGB(0x123456))
        #expect(custom.b == NativeAppearanceRGB(0xabcdef))
        #expect(custom.c == NativeAppearanceRGB(0x102030))
        #expect(custom.intensity == 1)
        #expect(try NativeChatTint(.object(["key": .string("custom"), "k": .number(-1)])).intensity == 0.15)
    }

    @Test(arguments: ["url(https://example.invalid/x)", "#123", "#12345678", "red", "#１２３４５６", "#gggggg"])
    func `Only six digit RGB colours enter the palette`(_ invalid: String) throws {
        #expect(NativeAppearanceRGB(hex: invalid) == nil)
        #expect(throws: NativeClientError.self) { try NativeChatTint(.object(["key": .string("custom"), "a": .string(invalid)])) }
    }

    @Test func `Account appearance request is authenticated scoped read only and preserves fields`() async throws {
        var count = 0
        let api = NativeAPI(transport: { request in
            count += 1
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/rest/v1/user_prefs")
            let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "user_id", value: "eq.\(uid)")))
            #expect(query.contains(URLQueryItem(name: "select", value: "prefs")))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access")
            return try response(request, "[{\"prefs\":{\"theme\":\"light\",\"color\":{\"key\":\"crimson\"},\"serverThemes\":false,\"unrelated\":\"preserved remotely\"}}]")
        })
        let value = try await api.nativeAccountAppearance(session: session())
        #expect(value.ownerID == uid)
        #expect(value.theme == "light")
        #expect(value.color?.key == "crimson")
        #expect(!value.serverThemes)
        #expect(count == 1)
    }

    @Test func `No saved account row uses the official fresh dark untinted defaults`() async throws {
        let api = NativeAPI(transport: { request in try response(request, "[]") })
        let value = try await api.nativeAccountAppearance(session: session())
        #expect(value.theme == "dark")
        #expect(value.color == nil)
        #expect(value.serverThemes)
    }

    @Test(arguments: ["null", "{}", "[{\"prefs\":{}},{\"prefs\":{}}]", "[{\"prefs\":[]}]", "[{\"prefs\":{\"color\":{\"key\":\"custom\",\"a\":\"bad\"}}}]"])
    func `Malformed preference responses never become verified appearance`(_ body: String) async throws {
        let api = NativeAPI(transport: { request in try response(request, body) })
        await #expect(throws: NativeClientError.self) { try await api.nativeAccountAppearance(session: session()) }
    }

    @Test func `Failed reads retain known colours and do not affect chat errors`() async throws {
        let (state, defaults, name) = try model()
        defer { defaults.removePersistentDomain(forName: name) }
        state.prepare(ownerID: uid)
        await state.refresh(ownerID: uid) { try appearance("crimson") }
        let initial = state.account
        await state.refresh(ownerID: uid) { throw URLError(.notConnectedToInternet) }
        #expect(state.account == initial)
        #expect(state.errorMessage != nil)
        #expect(!state.isRefreshing)
    }

    @Test func `Late appearance replies cannot cross account changes`() async throws {
        let (state, defaults, name) = try model()
        defer { defaults.removePersistentDomain(forName: name) }
        state.prepare(ownerID: uid)
        var ready: CheckedContinuation<Void, Never>?
        var finish: CheckedContinuation<Void, Never>?
        let task = Task {
            await state.refresh(ownerID: uid) {
                ready?.resume(); ready = nil
                await withCheckedContinuation { finish = $0 }
                return try appearance("crimson")
            }
        }
        await withCheckedContinuation { ready = $0 }
        state.prepare(ownerID: other)
        finish?.resume(); finish = nil
        await task.value
        #expect(state.ownerID == other)
        #expect(state.account == nil)
        #expect(state.tint == nil)
        var staleLoad = false
        await state.refresh(ownerID: uid) { staleLoad = true; return try appearance("crimson") }
        #expect(!staleLoad)
        #expect(state.ownerID == other)
    }

    @Test func `Nested server DM and settings scopes restore the still mounted parent`() throws {
        let (state, defaults, name) = try model()
        defer { defaults.removePersistentDomain(forName: name) }
        state.prepare(ownerID: uid)
        let parent = UUID(), child = UUID(), settings = UUID()
        let red = NativeServerAppearance(.object(["tint": .string("#ff0000")]))
        let green = NativeServerAppearance(.object(["tint": .string("#00ff00")]))
        state.setScope(id: parent, ownerID: uid, serverID: "one", theme: red)
        #expect(state.server == red)
        state.setScope(id: child, ownerID: uid, serverID: nil, theme: nil)
        #expect(state.server == nil)
        state.setScope(id: parent, ownerID: uid, serverID: "two", theme: green)
        #expect(state.server == nil, "Updating an obscured parent must not steal the foreground context.")
        state.removeScope(id: child)
        #expect(state.server == green)
        state.setScope(id: settings, ownerID: uid, serverID: nil, theme: nil)
        #expect(state.server == nil)
        state.removeScope(id: settings)
        #expect(state.server == green)
        state.setScope(id: child, ownerID: other, serverID: "foreign", theme: red)
        #expect(state.server == green)
        state.prepare(ownerID: other)
        #expect(state.server == nil)
    }

    @Test func `The website opt out disables server colours without changing personal colours`() async throws {
        let (state, defaults, name) = try model()
        defer { defaults.removePersistentDomain(forName: name) }
        state.prepare(ownerID: uid)
        state.setScope(id: UUID(), ownerID: uid, serverID: "one", theme: NativeServerAppearance(.object(["tint": .string("#ff0000")])))
        await state.refresh(ownerID: uid) { try appearance("crimson", serverThemes: false) }
        #expect(state.server == nil)
        #expect(state.tint?.key == "crimson")
    }

    @Test func `Local light dark or system overrides belong only to their account`() async throws {
        let (state, defaults, name) = try model()
        defer { defaults.removePersistentDomain(forName: name) }
        state.prepare(ownerID: uid)
        await state.refresh(ownerID: uid) { try appearance("crimson") }
        state.setLocalTheme("system")
        #expect(state.preferredTheme == "system")
        state.prepare(ownerID: other)
        #expect(state.preferredTheme == nil)
        state.prepare(ownerID: uid)
        #expect(state.preferredTheme == "system")
        state.useAccountTheme()
        await state.refresh(ownerID: uid) { try appearance("crimson") }
        #expect(state.preferredTheme == "dark")
    }

    @Test func `Tinted tokens match web panel alpha and retain personal tint over server backgrounds`() throws {
        let tint = try NativeChatTint(.object(["key": .string("crimson")]))
        let server = NativeServerAppearance(.object(["tint": .string("#00ff00"), "accent": .string("#408080")]))
        let main = NativeAppearanceColors.resolve(.main, dark: true, base: .init(0x222329), tint: tint, server: server)
        #expect(main.rgb == NativeAppearanceRGB(0x1e1f25))
        #expect(abs(main.alpha - 0.495) < 0.00001)
        let accent = NativeAppearanceColors.resolve(.accent, dark: true, base: .init(0xff6b4a), tint: tint, server: server)
        #expect(accent.rgb == NativeAppearanceRGB(0x408080))
        let plainServer = NativeAppearanceColors.resolve(.main, dark: true, base: .init(0x222329), tint: nil, server: server)
        #expect(plainServer.rgb == NativeAppearanceRGB(0x222329).mixed(with: NativeAppearanceRGB(0x00ff00), amount: 0.06))
    }

    @Test(arguments: [UInt32(0xffffff), 0x000000, 0xff0000, 0x00ff00, 0x408080])
    func `Server accent correction follows observed luminance windows`(_ color: UInt32) {
        for dark in [true, false] {
            let value = NativeAppearanceRGB(color).legibleAccent(dark: dark)
            #expect(value.luminance >= (dark ? 0.1 : 0.05) - 0.005)
            #expect(value.luminance <= (dark ? 0.4 : 0.3) + 0.005)
        }
    }

    private func appearance(_ key: String, serverThemes: Bool = true) throws -> NativeAccountAppearance {
        try NativeAccountAppearance(ownerID: uid, prefs: .object(["theme": .string("dark"), "color": .object(["key": .string(key)]), "serverThemes": .bool(serverThemes)]))
    }
    private func model() throws -> (NativeAppearanceState, UserDefaults, String) {
        let name = "NativeChatAppearanceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        return (NativeAppearanceState(defaults: defaults), defaults, name)
    }
    private func session() -> NativeSession { NativeSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: uid) }
    private func response(_ request: URLRequest, _ text: String) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        return (Data(text.utf8), try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)))
    }
}
