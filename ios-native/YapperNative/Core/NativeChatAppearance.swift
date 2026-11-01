import Foundation
import Observation

/// Account colour themes from the official user_prefs.prefs payload (module 65254).
nonisolated struct NativeChatTint: Equatable, Sendable {
    let key: String
    let a: NativeAppearanceRGB
    let b: NativeAppearanceRGB
    let c: NativeAppearanceRGB
    let intensity: Double

    init(_ value: NativeJSON) throws {
        guard value.object != nil, let key = value["key"].string, !key.isEmpty else { throw NativeClientError.invalidResponse }
        let preset = Self.presets.first { $0.key == key }
        func color(_ key: String, fallback: NativeAppearanceRGB) throws -> NativeAppearanceRGB {
            if value[key] == .null { return fallback }
            guard let text = value[key].string, let color = NativeAppearanceRGB(hex: text) else { throw NativeClientError.invalidResponse }
            return color
        }
        self.key = key
        a = try color("a", fallback: preset?.a ?? NativeAppearanceRGB(0xff6b4a))
        b = try color("b", fallback: preset?.b ?? NativeAppearanceRGB(0x9b59ff))
        c = try color("c", fallback: b)
        if value["k"] != .null, value["k"].number == nil { throw NativeClientError.invalidResponse }
        let intensity = value["k"].number ?? 0.75
        guard intensity.isFinite else { throw NativeClientError.invalidResponse }
        self.intensity = min(1, max(0.15, intensity))
    }

    struct Preset: Equatable, Sendable {
        let key: String
        let name: String
        let a: NativeAppearanceRGB
        let b: NativeAppearanceRGB
        init(_ key: String, _ name: String, _ a: UInt32, _ b: UInt32) { self.key = key; self.name = name; self.a = NativeAppearanceRGB(a); self.b = NativeAppearanceRGB(b) }
    }

    static let presets: [Preset] = [
        .init("mint", "Mint Apple", 0x7ee2a8, 0x5aa9e6), .init("citrus", "Citrus Sherbert", 0xffb86b, 0xffe08a),
        .init("retro", "Retro Raincloud", 0x8fb8ff, 0xc7a4ff), .init("hanami", "Hanami", 0xff9ecb, 0xffd36b),
        .init("sunrise", "Sunrise", 0xff8a65, 0xffcc66), .init("cotton", "Cotton Candy", 0xf4a4ff, 0x8ec5ff),
        .init("lofi", "Lofi Vibes", 0x8ad3ff, 0xa8e6a1), .init("desert", "Desert Khaki", 0xe6c88a, 0xb8c08a),
        .init("sunset", "Sunset", 0xff7eb3, 0xff9966), .init("chroma", "Chroma Glow", 0x5be3ff, 0xc56bff),
        .init("forest", "Forest", 0x4fb37a, 0x4f8ad9), .init("crimson", "Crimson Moon", 0xe0304a, 0x4a0f1c),
        .init("midnight", "Midnight Blurple", 0x5865f2, 0x8b45d9), .init("mars", "Mars", 0xd95f4a, 0x7a3f3f),
        .init("dusk", "Dusk", 0x8a93d9, 0xc58ad9), .init("under", "Under the Sea", 0x3fc1a8, 0x3f7fd9),
        .init("strawberry", "Strawberry Lemonade", 0xff5c8a, 0xffd34d), .init("aurora", "Aurora", 0x3fe0b8, 0x7a5cff),
        .init("neon", "Neon Nights", 0xff4fd8, 0x33e6ff), .init("ocean", "Deep Ocean", 0x2b5bd9, 0x0e2a6b)
    ]
}

nonisolated struct NativeAppearanceRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    init(_ value: UInt32) {
        red = Double((value >> 16) & 255) / 255
        green = Double((value >> 8) & 255) / 255
        blue = Double(value & 255) / 255
    }
    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }
    init?(hex: String) {
        guard hex.count == 7, hex.first == "#", hex.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(value)
    }
    func mixed(with other: Self, amount: Double) -> Self {
        let amount = min(1, max(0, amount))
        return Self(red: red * (1 - amount) + other.red * amount, green: green * (1 - amount) + other.green * amount, blue: blue * (1 - amount) + other.blue * amount)
    }
    var luminance: Double {
        let values = [red, green, blue].map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    /// Same luminance range and binary-search HSL correction as official module 31691.
    func legibleAccent(dark: Bool) -> Self {
        let lower = dark ? 0.1 : 0.05, upper = dark ? 0.4 : 0.3
        guard luminance < lower || luminance > upper else { return self }
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum, lightness = (maximum + minimum) / 2
        let saturation = delta == 0 ? 0 : lightness > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        let hue: Double = delta == 0 ? 0 : maximum == red ? ((green - blue) / delta + (green < blue ? 6 : 0)) / 6 : maximum == green ? ((blue - red) / delta + 2) / 6 : ((red - green) / delta + 4) / 6
        func color(_ l: Double) -> Self {
            func component(_ offset: Double) -> Double {
                let k = (offset + hue * 12).truncatingRemainder(dividingBy: 12)
                return (255 * (l - saturation * min(l, 1 - l) * max(-1, min(k - 3, 9 - k, 1)))).rounded() / 255
            }
            return Self(red: component(0), green: component(8), blue: component(4))
        }
        let target = luminance < lower ? lower : upper
        var lo = 0.0, hi = 1.0
        for _ in 0..<20 { let mid = (lo + hi) / 2; if color(mid).luminance < target { lo = mid } else { hi = mid } }
        return color(luminance < lower ? hi : lo)
    }
}

nonisolated struct NativeAccountAppearance: Equatable, Sendable {
    let ownerID: String
    let theme: String
    let color: NativeChatTint?
    let serverThemes: Bool

    init(ownerID: String, prefs: NativeJSON) throws {
        guard prefs == .null || prefs.object != nil else { throw NativeClientError.invalidResponse }
        self.ownerID = ownerID
        if let theme = prefs["theme"].string { guard ["dark", "light"].contains(theme) else { throw NativeClientError.invalidResponse }; self.theme = theme }
        else { theme = "dark" }
        color = prefs["color"] == .null ? nil : try NativeChatTint(prefs["color"])
        serverThemes = prefs["serverThemes"].bool ?? true
    }
}

nonisolated struct NativeServerAppearance: Equatable, Sendable {
    let accent: NativeAppearanceRGB?
    let tint: NativeAppearanceRGB?
    init(_ row: NativeJSON) {
        accent = row["accent"].string.flatMap(NativeAppearanceRGB.init(hex:))
        tint = row["tint"].string.flatMap(NativeAppearanceRGB.init(hex:))
    }
}

nonisolated enum NativeAppearanceToken: Equatable, Sendable {
    case rail, sidebar, main, elevated, input, border, hover, active, faint, secondary, accent, accentFill, accentSoft, floating
}

nonisolated struct NativeAppearanceRGBA: Equatable, Sendable {
    let rgb: NativeAppearanceRGB
    let alpha: Double
    init(_ rgb: NativeAppearanceRGB, alpha: Double = 1) { self.rgb = rgb; self.alpha = min(1, max(0, alpha)) }
    init(_ hex: UInt32, alpha: Double = 1) { self.init(NativeAppearanceRGB(hex), alpha: alpha) }
}

nonisolated enum NativeAppearanceColors {
    static func resolve(_ token: NativeAppearanceToken, dark: Bool, base: NativeAppearanceRGBA, tint: NativeChatTint?, server: NativeServerAppearance?) -> NativeAppearanceRGBA {
        if let accent = server?.accent, [.accent, .accentFill, .accentSoft].contains(token) {
            return NativeAppearanceRGBA(accent.legibleAccent(dark: dark), alpha: token == .accentSoft ? 0.14 : 1)
        }
        if let tint {
            let panel = 1 - tint.intensity * 0.62
            switch token {
            case .rail: return dark ? .init(0x0e0f13, alpha: panel + 0.05) : .init(0xffffff, alpha: panel - 0.08)
            case .sidebar: return dark ? .init(0x16171c, alpha: panel) : .init(0xffffff, alpha: panel)
            case .main: return dark ? .init(0x1e1f25, alpha: panel - 0.04) : .init(0xffffff, alpha: panel + 0.14)
            case .elevated, .hover: return dark ? .init(0xffffff, alpha: 18 / 255) : .init(0, alpha: 13 / 255)
            case .active: return dark ? .init(0xffffff, alpha: 33 / 255) : .init(0, alpha: 26 / 255)
            case .input: return dark ? .init(0, alpha: 71 / 255) : .init(0xffffff, alpha: 0.6)
            case .border: return dark ? .init(0xffffff, alpha: 26 / 255) : .init(0, alpha: 23 / 255)
            case .faint: return .init(dark ? 0xa9aab8 : 0x464850)
            case .secondary: return .init(dark ? 0xb9bac6 : 0x3e4047)
            case .floating: return .init(NativeAppearanceRGB(dark ? 0x1b1c21 : 0xffffff).mixed(with: tint.b, amount: 0.12))
            default: return base
            }
        }
        if let tint = server?.tint {
            let fraction: Double? = switch token {
            case .rail: dark ? 0.08 : 0.09
            case .sidebar: dark ? 0.08 : 0.07
            case .main: dark ? 0.06 : 0.04
            case .elevated: 0.07
            case .hover: 0.08
            case .active: 0.10
            case .input: 0.06
            case .floating: dark ? 0.08 : 0.04
            default: nil
            }
            if let fraction { return .init(base.rgb.mixed(with: tint, amount: fraction), alpha: base.alpha) }
        }
        return base
    }
}

extension NativeAPI {
    func nativeAccountAppearance(session: NativeSession) async throws -> NativeAccountAppearance {
        let value = try await table("user_prefs", query: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)"), URLQueryItem(name: "select", value: "prefs")], session: session)
        guard case .array(let rows) = value, rows.count <= 1,
              rows.first == nil || rows[0].object != nil else { throw NativeClientError.invalidResponse }
        return try NativeAccountAppearance(ownerID: session.userID, prefs: rows.first?["prefs"] ?? .null)
    }
}

/// One active web-like appearance context, with nested views leased by identity.
/// Removing a conversation/settings scope restores its still-mounted parent scope.
@MainActor @Observable final class NativeAppearanceState {
    static let shared = NativeAppearanceState()
    private(set) var ownerID: String?
    private(set) var account: NativeAccountAppearance?
    private(set) var errorMessage: String?
    private(set) var isRefreshing = false
    private(set) var localThemeOverride: String?
    private var scopes: [Scope] = []
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    private struct Scope { let id: UUID; let serverID: String?; let theme: NativeServerAppearance? }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var tint: NativeChatTint? { account?.color }
    var preferredTheme: String? { localThemeOverride ?? account?.theme }
    var server: NativeServerAppearance? { account?.serverThemes == false ? nil : scopes.last?.theme }

    func prepare(ownerID: String?) {
        guard self.ownerID != ownerID else { return }
        revision += 1
        self.ownerID = ownerID; account = nil; errorMessage = nil; isRefreshing = false; scopes = []
        localThemeOverride = ownerID.flatMap { defaults.dictionary(forKey: "native.accountThemeOverrides")?[$0] as? String }
    }
    func setLocalTheme(_ value: String) {
        guard let ownerID, ["dark", "light", "system"].contains(value) else { return }
        localThemeOverride = value
        var values = defaults.dictionary(forKey: "native.accountThemeOverrides") ?? [:]
        values[ownerID] = value; defaults.set(values, forKey: "native.accountThemeOverrides")
    }
    func useAccountTheme() {
        localThemeOverride = nil
        guard let ownerID else { return }
        var values = defaults.dictionary(forKey: "native.accountThemeOverrides") ?? [:]
        values.removeValue(forKey: ownerID); defaults.set(values, forKey: "native.accountThemeOverrides")
    }
    func setScope(id: UUID, ownerID: String?, serverID: String?, theme: NativeServerAppearance?) {
        guard let ownerID, ownerID == self.ownerID else { return }
        let scope = Scope(id: id, serverID: serverID, theme: serverID == nil ? nil : theme)
        if let index = scopes.firstIndex(where: { $0.id == id }) { scopes[index] = scope }
        else { scopes.append(scope) }
    }
    func removeScope(id: UUID) { scopes.removeAll { $0.id == id } }

    /// No preference upsert: this client must not overwrite unrelated website settings.
    func refresh(ownerID: String?, load: @MainActor () async throws -> NativeAccountAppearance) async {
        guard let ownerID, ownerID == self.ownerID, !Task.isCancelled else { return }
        revision += 1; let operation = revision
        isRefreshing = true
        defer { if revision == operation { isRefreshing = false } }
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard revision == operation, self.ownerID == ownerID, result.ownerID == ownerID else { return }
            account = result; errorMessage = nil
        } catch is CancellationError {} catch {
            guard revision == operation, self.ownerID == ownerID else { return }
            errorMessage = "Das gespeicherte Website-Design konnte nicht geladen werden."
        }
    }
}
