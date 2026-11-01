import SwiftUI
import UIKit

/// Colors follow Yapper's shipped dark and light theme tokens.
/// UIKit resolves dynamic colors on render queues; providers capture only Sendable scalar values.
enum YapperPalette {
    static var rail: Color { adaptive(.rail, dark: 0x141519, light: 0xE3E5E8) }
    static var sidebar: Color { adaptive(.sidebar, dark: 0x1B1C21, light: 0xF2F3F5) }
    static var background: Color { adaptive(.main, dark: 0x222329, light: 0xFFFFFF) }
    static var elevated: Color { adaptive(.elevated, dark: 0x2B2C33, light: 0xEBEDEF) }
    static var input: Color { adaptive(.input, dark: 0x2D2E36, light: 0xEBEDEF) }
    static let text = adaptive(dark: 0xECECF1, light: 0x1D1F23)
    static var secondary: Color { adaptive(.secondary, dark: 0xA6A7B4, light: 0x55575F) }
    static var accent: Color { adaptive(.accent, dark: 0xFF6B4A, light: 0xD4401E) }
    static var accentFill: Color { adaptive(.accentFill, dark: 0xD4401E, light: 0xD4401E) }
    static let onAccent = Color.white
    static var border: Color { adaptive(.border, dark: 0xFFFFFF, light: 0x000000, darkAlpha: 18 / 255, lightAlpha: 23 / 255) }
    static var hover: Color { adaptive(.hover, dark: 0x2F3038, light: 0xE6E7EA) }
    static var active: Color { adaptive(.active, dark: 0x383944, light: 0xD7D9DE) }
    static var faint: Color { adaptive(.faint, dark: 0x9A9CA9, light: 0x5F616A) }
    static var accentSoft: Color { adaptive(.accentSoft, dark: 0xFF6B4A, light: 0xFF6B4A, darkAlpha: 41 / 255, lightAlpha: 36 / 255) }
    static var floating: Color { adaptive(.floating, dark: 0x1B1C21, light: 0xFFFFFF) }
    static let accentLabel = Color.white
    static let success = Color(red: 63 / 255, green: 207 / 255, blue: 130 / 255)
    static let danger = adaptive(dark: 0xF2555A, light: 0xF2555A)

    private static func adaptive(_ token: NativeAppearanceToken? = nil, dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        let appearance = NativeAppearanceState.shared
        let tint = appearance.tint, server = appearance.server
        let darkBase = NativeAppearanceRGBA(dark, alpha: darkAlpha)
        let lightBase = NativeAppearanceRGBA(light, alpha: lightAlpha)
        let darkValue = token.map { NativeAppearanceColors.resolve($0, dark: true, base: darkBase, tint: tint, server: server) } ?? darkBase
        let lightValue = token.map { NativeAppearanceColors.resolve($0, dark: false, base: lightBase, tint: tint, server: server) } ?? lightBase
        // Dynamic providers may execute on UIKit rendering queues. Capture scalar values only.
        return Color(uiColor: UIColor { @Sendable traits in
            let value = traits.userInterfaceStyle == .dark ? darkValue : lightValue
            return UIColor(red: CGFloat(value.rgb.red), green: CGFloat(value.rgb.green), blue: CGFloat(value.rgb.blue), alpha: CGFloat(value.alpha))
        })
    }
}

struct YapperPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OriginalYapper.font(15, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(YapperPalette.accentLabel)
            .background(YapperPalette.accentFill.opacity(isEnabled ? 1 : 0.45), in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct NativeAvatar: View {
    let name: String
    var identity: String? = nil
    var username: String? = nil
    let url: URL?
    var presence: String? = nil
    var size: CGFloat = 46
    var initialsFontSize: CGFloat? = nil
    var decorationURL: URL? = nil
    var crop: NativeImageCrop = .centered

    @AppStorage("native.showAvatars") private var showAvatars = true

    private var initials: String { String((username ?? name).prefix(1)).uppercased() }
    private var fallbackColor: Color { OriginalAvatarFallback.color(identity: identity, username: username ?? name) }
    private var statusSize: CGFloat { size <= 40 ? max(10, size * 0.3) : (12 + (size - 40) * 0.14).rounded() }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(fallbackColor)
                Text(initials.isEmpty ? "?" : initials)
                    .font(OriginalYapper.fixedFont(initialsFontSize ?? size * 0.4, numericWeight: 700))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                if showAvatars, let url {
                    NativeCroppedImage(url: url, crop: crop, maximumPixelSize: Int(size * 3), placeholder: "")
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if showAvatars, let decorationURL {
                    NativeRemoteImage(url: decorationURL, maximumPixelSize: Int(size * 4), mode: .fit, placeholder: "")
                        .frame(width: size * 1.5, height: size * 1.5)
                        .allowsHitTesting(false)
                }
            }
            if let presence, presence != "unknown" {
                NativeOriginalPresenceDot(presence: presence, size: statusSize)
                    .offset(x: 2, y: 2)
            }

        }
        .accessibilityHidden(true)
    }
}

enum OriginalAvatarFallback {
    static func color(identity: String?, username: String?) -> Color {
        let palette: [UInt32] = [0xFF6B4A, 0x7B61FF, 0x2BB3A3, 0xE5487F, 0x3A8DFF, 0xF0A020, 0x4BBF5A]
        var hash: UInt32 = 0
        for unit in (identity ?? username ?? "").utf16 { hash = (hash &* 31) &+ UInt32(unit) }
        let value = palette[Int(hash % 7)]
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct NativeOriginalPresenceDot: View {
    let presence: String
    var size: CGFloat = 10
    var background: Color = YapperPalette.sidebar

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle().fill(color).frame(width: size, height: size)
            if presence == "offline" || presence == "invisible" {
                Circle().strokeBorder(Color(red: 128/255, green: 132/255, blue: 142/255), lineWidth: 3).frame(width: size, height: size)
            } else if presence == "idle" || presence == "away" {
                Circle().fill(background).frame(width: size * 0.6, height: size * 0.6).offset(x: -size * 0.06, y: -size * 0.06)
            } else if presence == "dnd" || presence == "busy" {
                RoundedRectangle(cornerRadius: 2).fill(background).frame(width: size * 0.56, height: size * 0.24).offset(x: size * 0.22, y: size * 0.38)
            }
        }.frame(width: size, height: size)
            .background(Circle().fill(background).frame(width: size + 6, height: size + 6))
            .accessibilityHidden(true)
    }
    private var color: Color {
        switch presence {
        case "online": YapperPalette.success
        case "idle", "away": Color(red: 240/255, green: 178/255, blue: 50/255)
        case "dnd", "busy": Color(red: 242/255, green: 63/255, blue: 67/255)
        default: background
        }
    }
}

struct NativeDisplayName: View {
    let name: String
    var bannerURL: URL? = nil
    var body: some View {
        Text(name)
            .padding(.horizontal, bannerURL == nil ? 0 : 4)
            .background {
                if let bannerURL {
                    NativeRemoteImage(url: bannerURL, maximumPixelSize: 640, mode: .fill, placeholder: "")
                        .clipShape(.rect(cornerRadius: 4))
                        .allowsHitTesting(false)
                }
            }
    }
}

struct NativeErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(OriginalYapper.font(14))
            .foregroundStyle(YapperPalette.danger)
            if let retry {
                Button("common.retry", action: retry)
                    .font(OriginalYapper.font(14, weight: .semibold))
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(YapperPalette.danger.opacity(0.08), in: .rect(cornerRadius: 12))
        .accessibilityIdentifier("native.error")
    }
}

extension View {
    func yapperNavigation() -> some View {
        self
            .toolbarBackground(YapperPalette.sidebar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(YapperPalette.accent)
    }
}
