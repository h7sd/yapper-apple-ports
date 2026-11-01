import SwiftUI

private extension NativeAppearanceRGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

/// Native equivalent of the official .app gradient. No remote image or HTML is loaded.
struct NativeChatBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    private let appearance = NativeAppearanceState.shared
    var body: some View {
        if let tint = appearance.tint {
            let dark = colorScheme == .dark
            let base = NativeAppearanceRGB(dark ? 0x15161a : 0xffffff)
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: [base.mixed(with: tint.a, amount: tint.intensity * (dark ? 0.7 : 0.5)).color,
                                            base.mixed(with: tint.b, amount: tint.intensity * (dark ? 0.7 : 0.5)).color],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if dark { glow(tint.b, base: base, fraction: tint.intensity * 0.85, center: CGPoint(x: 0.55, y: 0.95), radii: CGSize(width: 0.8, height: 0.6), fade: 0.6, size: geometry.size) }
                    glow(tint.c, base: base, fraction: tint.intensity * (dark ? 1 : 0.85), center: CGPoint(x: 1, y: 1), radii: CGSize(width: 1.1, height: 0.8), fade: 0.62, size: geometry.size)
                    glow(tint.a, base: base, fraction: tint.intensity * (dark ? 1 : 0.85), center: .zero, radii: CGSize(width: 1.1, height: 0.8), fade: 0.62, size: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        } else { YapperPalette.background.accessibilityHidden(true).allowsHitTesting(false) }
    }

    private func glow(_ tint: NativeAppearanceRGB, base: NativeAppearanceRGB, fraction: Double,
                      center: CGPoint, radii: CGSize, fade: CGFloat, size: CGSize) -> some View {
        let color = base.mixed(with: tint, amount: fraction).color
        return EllipticalGradient(stops: [.init(color: color, location: 0), .init(color: color.opacity(0), location: fade)],
                                  center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
            .frame(width: max(1, size.width * radii.width * 2), height: max(1, size.height * radii.height * 2))
            .position(x: size.width * center.x, y: size.height * center.y)
    }
}

private struct NativeServerAppearanceScope: ViewModifier {
    let ownerID: String?
    let serverID: String?
    let theme: NativeServerAppearance?
    @State private var scopeID = UUID()
    private let appearance = NativeAppearanceState.shared
    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: ownerID) { _, _ in update() }
            .onChange(of: appearance.ownerID) { _, _ in update() }
            .onChange(of: serverID) { _, _ in update() }
            .onChange(of: theme) { _, _ in update() }
            .onDisappear { appearance.removeScope(id: scopeID) }
    }
    private func update() { appearance.setScope(id: scopeID, ownerID: ownerID, serverID: serverID, theme: theme) }
}

extension View {
    /// A nil server scope explicitly restores personal colours for DMs and settings.
    func nativeServerAppearance(ownerID: String?, serverID: String?, theme: NativeJSON) -> some View {
        modifier(NativeServerAppearanceScope(ownerID: ownerID, serverID: serverID, theme: serverID == nil ? nil : NativeServerAppearance(theme)))
    }
}

struct NativeChatAppearanceSettings: View {
    let store: NativeStore
    private let appearance = NativeAppearanceState.shared
    var body: some View {
        OriginalSettingsSection("Website-Design") {
            Text("Farben und Hintergrund werden aus den gespeicherten Einstellungen deines Yapper-Kontos übernommen.")
                .font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary)
            if let account = appearance.account {
                HStack {
                    if let tint = account.color { LinearGradient(colors: [tint.a.color, tint.b.color, tint.c.color], startPoint: .topLeading, endPoint: .bottomTrailing).frame(width: 40, height: 40).clipShape(.rect(cornerRadius: 8)) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.color.map { tint in NativeChatTint.presets.first { $0.key == tint.key }?.name ?? "Eigene Farben" } ?? "Kein Farbthema")
                        Text(account.theme == "light" ? "Helles Kontodesign" : "Dunkles Kontodesign").font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary)
                    }
                    Spacer()
                }
            }
            Button {
                appearance.useAccountTheme()
                Task { await appearance.refresh(ownerID: store.user?.id) { try await store.withAuthenticatedSession { api, session in try await api.nativeAccountAppearance(session: session) } } }
            } label: {
                HStack { if appearance.isRefreshing { ProgressView() }; Text("Website-Design neu laden") }.frame(minHeight: 44)
            }
            .buttonStyle(.plain).foregroundStyle(YapperPalette.accent)
            .disabled(appearance.isRefreshing)
            .accessibilityIdentifier("native.appearance.reloadAccount")
            if let error = appearance.errorMessage { NativeErrorBanner(message: error) }
        }
    }
}
