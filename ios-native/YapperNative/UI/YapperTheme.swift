import SwiftUI
import UIKit

/// Colors follow Yapper's shipped dark and light theme tokens.
enum YapperPalette {
    static let rail = adaptive(dark: 0x141519, light: 0xE3E5E8)
    static let sidebar = adaptive(dark: 0x1B1C21, light: 0xF2F3F5)
    static let background = adaptive(dark: 0x222329, light: 0xFFFFFF)
    static let elevated = adaptive(dark: 0x2B2C33, light: 0xEBEDEF)
    static let input = adaptive(dark: 0x2D2E36, light: 0xEBEDEF)
    static let text = adaptive(dark: 0xECECF1, light: 0x1D1F23)
    static let secondary = adaptive(dark: 0xB2B3BE, light: 0x5B5D66)
    static let accent = Color(red: 1, green: 107 / 255, blue: 74 / 255)
    static let accentLabel = Color(red: 20 / 255, green: 21 / 255, blue: 25 / 255)
    static let success = Color(red: 63 / 255, green: 207 / 255, blue: 130 / 255)
    static let danger = adaptive(dark: 0xFF9297, light: 0xB82234)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1
            )
        })
    }
}

struct YapperPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(YapperPalette.accentLabel)
            .background(YapperPalette.accent.opacity(isEnabled ? 1 : 0.45), in: .rect(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct NativeAvatar: View {
    let name: String
    let url: URL?
    var presence: String? = nil
    var size: CGFloat = 46

    @AppStorage("native.showAvatars") private var showAvatars = true

    private var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Circle().fill(YapperPalette.elevated)
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(YapperPalette.accent)
                if showAvatars, let url {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: size, height: size)
                    .clipShape(.circle)
                }
            }
            .frame(width: size, height: size)
            if let presence, presence != "unknown" {
                Circle()
                    .fill(presence == "online" ? YapperPalette.success : YapperPalette.secondary)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(YapperPalette.sidebar, lineWidth: 3))
            }
        }
        .accessibilityHidden(true)
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
            .font(.subheadline)
            .foregroundStyle(YapperPalette.danger)
            if let retry {
                Button("common.retry", action: retry)
                    .font(.subheadline.weight(.semibold))
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
