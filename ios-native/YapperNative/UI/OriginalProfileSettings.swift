import SwiftUI

/// Geometry and labels follow the frozen Yapper PC2/profile and settings styles.
struct OriginalSettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(OriginalYapper.font(11, weight: .heavy)).tracking(0.66).foregroundStyle(YapperPalette.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
    }
}

struct OriginalSettingsField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(OriginalYapper.font(11, weight: .bold)).tracking(0.55).foregroundStyle(YapperPalette.secondary)
            content
        }
    }
}

struct OriginalSettingsRow: View {
    let title: String
    var subtitle: String? = nil
    var icon = "settings"
    var destructive = false
    var disclosure = true
    var body: some View {
        HStack(spacing: 14) {
            OriginalYapperIcon(icon, size: 20).foregroundStyle(destructive ? YapperPalette.danger : YapperPalette.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(OriginalYapper.font(14.5, weight: .semibold)).foregroundStyle(destructive ? YapperPalette.danger : YapperPalette.text)
                if let subtitle { Text(subtitle).font(OriginalYapper.font(12)).foregroundStyle(YapperPalette.secondary) }
            }
            Spacer(minLength: 4)
            if disclosure { OriginalYapperIcon("chevronRight", size: 16).foregroundStyle(YapperPalette.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(YapperPalette.elevated, in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
    }
}

struct OriginalProfileSection<Content: View>: View {
    let title: String
    var themed = false
    var light = false
    let content: Content
    init(_ title: String, themed: Bool = false, light: Bool = false, @ViewBuilder content: () -> Content) { self.title = title; self.themed = themed; self.light = light; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(OriginalYapper.font(11, weight: .heavy)).tracking(0.66).foregroundStyle(themed ? (light ? .black.opacity(0.66) : .white.opacity(0.78)) : YapperPalette.secondary)
            content.font(OriginalYapper.font(14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(themed ? (light ? Color.white.opacity(0.55) : Color.black.opacity(0.42)) : YapperPalette.rail, in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(themed ? (light ? .black.opacity(0.1) : .white.opacity(0.1)) : YapperPalette.border, lineWidth: 1))
    }
}

enum OriginalProfileContrast {
    /// Shipped module6999 U: average sRGB relative luminance above0.3.
    static func isLight(_ first: String?, _ second: String?) -> Bool {
        guard let a = luminance(first) else { return false }
        return (a + (luminance(second) ?? a)) / 2 > 0.3
    }
    private static func luminance(_ value: String?) -> Double? {
        guard let value else { return nil }
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let hex = UInt32(digits, radix: 16) else { return nil }
        let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { channel in
            let normalized = channel / 255
            return normalized <= 0.03928 ? normalized / 12.92 : pow((normalized + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}

extension Color {
    static func originalProfileHex(_ value: String?) -> Color? {
        guard let value, value.count == 7, value.first == "#", let hex = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

/// The original identity popover, rendered natively. Every presented action is wired.
struct OriginalAccountMenuView: View {
    let store: NativeStore
    let onOpenProfile: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    @AppStorage("native.notificationSounds") private var notificationSounds = true
    @State private var profile: NativeProfileDetail?
    @State private var showingStatus = false
    @State private var showingEditor = false
    @State private var busy = false
    @State private var error: String?

    private var fixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }
    private var enabledFlags: Set<String> { Set(["server_tags", "tag_icons", "temp_avatar"].filter { store.capabilities.flagOn($0, userID: store.user?.id) }) }
    var body: some View {
        VStack(spacing: 0) {
            if let user = store.user {
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let profile, let url = profile.bannerURL { NativeCroppedImage(url: url, crop: NativeImageCrop(x: profile.bannerX, y: profile.bannerY, zoom: profile.bannerZoom)) }
                            else if let accent = Color.originalProfileHex(profile?.accentColor) { LinearGradient(colors: [accent, Color.originalProfileHex(profile?.accentColor2) ?? accent], startPoint: .topLeading, endPoint: .bottomTrailing) }
                            else { YapperPalette.accent }
                        }.aspectRatio(3, contentMode: .fit).clipped()
                        Button { showingEditor = true } label: { OriginalYapperIcon("edit", size: 16).frame(width: 30, height: 30).contentShape(.interaction, Rectangle().inset(by: -7)).foregroundStyle(.white).background(.black.opacity(0.45), in: .circle) }.buttonStyle(.plain).padding(8).accessibilityLabel("Profil bearbeiten").disabled(profile == nil)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        NativeDisplayName(name: user.displayName, bannerURL: user.nameBannerURL).font(OriginalYapper.font(20, weight: .heavy)).lineLimit(1).frame(minHeight: 24, alignment: .leading)
                        Text("@\(user.username)").font(OriginalYapper.font(13)).foregroundStyle(YapperPalette.secondary).frame(minHeight: 18.2, alignment: .leading)
                        if store.capabilities.flagOn("activity", userID: user.id), let profile, !profile.customStatus.isEmpty { Text(profile.customStatus).font(OriginalYapper.font(13)).lineLimit(1).padding(.vertical, 6).padding(.horizontal, 10).background(YapperPalette.sidebar, in: .rect(cornerRadius: 8)).padding(.top, 6) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 46).padding(.horizontal, 16).padding(.bottom, 12)
                }
                .background(YapperPalette.elevated)
                .overlay(alignment: .topLeading) {
                    NativeAvatar(name: user.displayName, identity: user.id, username: user.username, url: user.avatarURL, presence: user.presence, size: 76, decorationURL: user.avatarDecorationURL, crop: user.avatarCrop).padding(5).background(YapperPalette.elevated, in: .circle).padding(.leading, 14).padding(.top, 52)
                }
                VStack(spacing: 0) {
                    Button { showingStatus.toggle() } label: {
                        HStack(spacing: 10) { NativeOriginalPresenceDot(presence: user.presence, size: 12); Text(presenceLabel(user.presence)); Spacer(); OriginalYapperIcon("chevronRight", size: 16) }.frame(minHeight: 19.6).padding(.vertical, 7).padding(.horizontal, 8).contentShape(.interaction, Rectangle().inset(by: -5.2))
                    }
                    if showingStatus {
                        ForEach(["online", "idle", "dnd", "invisible"], id: \.self) { status in
                            Button { Task { await setPresence(status) } } label: { HStack(spacing: 10) { NativeOriginalPresenceDot(presence: status == "invisible" ? "offline" : status, size: 12); Text(presenceLabel(status)); Spacer() }.frame(minHeight: 19.6).padding(.vertical, 7).padding(.horizontal, 8).contentShape(.interaction, Rectangle().inset(by: -5.2)) }
                        }
                    }
                    if store.capabilities.flagOn("activity", userID: user.id) { Button { showingEditor = true } label: { menuRow("Eigenen Status festlegen", icon: "servers") }.disabled(profile == nil) }
                    Rectangle().fill(YapperPalette.border).frame(height: 1).padding(.horizontal, 6).padding(.vertical, 4)
                    Button { notificationSounds.toggle() } label: {
                        HStack(spacing: 10) {
                            OriginalYapperIcon("bell", size: 14)
                            Text("Benachrichtigungstöne").frame(maxWidth: .infinity, alignment: .leading)
                            Capsule().fill(notificationSounds ? YapperPalette.success : Color(red: 78/255, green: 80/255, blue: 88/255)).frame(width: 30, height: 18).overlay(alignment: notificationSounds ? .trailing : .leading) { Circle().fill(.white).frame(width: 12, height: 12).padding(3) }
                        }.frame(minHeight: 19.6).padding(.vertical, 7).padding(.horizontal, 8).contentShape(.interaction, Rectangle().inset(by: -5.2))
                    }.accessibilityRepresentation { Toggle("Benachrichtigungstöne", isOn: $notificationSounds).toggleStyle(.switch) }
                    Button { onClose(); onOpenProfile() } label: { menuRow("Mein Profil anzeigen", icon: "H") }
                }.font(OriginalYapper.font(14)).padding(6).background(YapperPalette.sidebar, in: .rect(cornerRadius: 10)).padding(.horizontal, 8).padding(.bottom, 8)
            }
            if let error { NativeErrorBanner(message: error) }
        }
        .padding(1)
        .foregroundStyle(YapperPalette.text)
        .background(YapperPalette.sidebar, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(YapperPalette.border, lineWidth: 1))
        .frame(maxWidth: 300).buttonStyle(.plain).disabled(busy)
        .task {
            guard let id = store.user?.id else { return }
            do {
                #if DEBUG
                if fixture { profile = try NativeSocialModel(store: store).fixtureProfile(userID: id); return }
                #endif
                profile = try await store.withAuthenticatedSession { api, session in try await api.socialProfiles(ids: [id], session: session).first }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $showingEditor) {
            if let profile { NavigationStack { NativeProfileEditor(store: store, profile: profile, featureFlags: enabledFlags) { self.profile = $0 } } }
        }
    }
    private func menuRow(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) { OriginalYapperIcon(icon, size: 14); Text(title); Spacer() }.frame(maxWidth: .infinity, minHeight: 19.6, alignment: .leading).padding(.vertical, 7).padding(.horizontal, 8).contentShape(.interaction, Rectangle().inset(by: -5.2)).contentShape(.rect)
    }
    private func presenceLabel(_ status: String) -> String {
        switch status { case "online": "Online"; case "idle": "Abwesend"; case "dnd": "Nicht stören"; case "invisible": "Unsichtbar"; default: "Offline" }
    }
    private func setPresence(_ status: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if fixture { return }
            try await store.withAuthenticatedSession { api, session in try await api.setSocialPresence(status, session: session) }
            await store.refreshOwnProfile()
            await store.refreshNotificationSoundContext()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct OriginalModalPage<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String?
    let onClose: @MainActor () -> Void
    let content: Content
    let footer: Footer
    init(_ title: String, subtitle: String? = nil, onClose: @escaping @MainActor () -> Void, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title; self.subtitle = subtitle; self.onClose = onClose; self.content = content(); self.footer = footer()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(OriginalYapper.font(20, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    if let subtitle { Text(subtitle).font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                Button(action: onClose) { OriginalYapperIcon("close", size: 20).frame(width: 40, height: 40).contentShape(.interaction, Rectangle().inset(by: -2)) }.buttonStyle(.plain).accessibilityLabel("Schließen")
            }.padding(.leading, 20).padding(.top, 20).padding(.trailing, 10).padding(.bottom, 8)
            ScrollView { VStack(alignment: .leading, spacing: 16) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).padding(.horizontal, 20) }
            HStack(spacing: 8) { Spacer(minLength: 0); footer }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
        }
        .frame(maxWidth: 440).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(OriginalYapper.font(14)).foregroundStyle(YapperPalette.text)
        .background(YapperPalette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// CSS linear-gradient(165deg,...) projected onto the actual rectangular box.
struct OriginalProfileGradient: View {
    let first: Color
    let second: Color
    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = max(geometry.size.height, 1)
            let dx = sin(165.0 * .pi / 180)
            let dy = -cos(165.0 * .pi / 180)
            let length = abs(width * dx) + abs(height * dy)
            LinearGradient(colors: [first, second], startPoint: UnitPoint(x: 0.5 - dx * length / (2 * width), y: 0.5 - dy * length / (2 * height)), endPoint: UnitPoint(x: 0.5 + dx * length / (2 * width), y: 0.5 + dy * length / (2 * height)))
        }
    }
}

struct OriginalInlineFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }
        return arrangement(sizes: sizes, width: width).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = arrangement(sizes: sizes, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.points[index].x, y: bounds.minY + result.points[index].y), anchor: .topLeading, proposal: ProposedViewSize(width: min(sizes[index].width, bounds.width), height: sizes[index].height))
        }
    }
    private func arrangement(sizes: [CGSize], width: CGFloat) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var points: [CGPoint] = []
        for size in sizes {
            let itemWidth = min(size.width, max(width, 1))
            if x > 0 && x + itemWidth > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y)); x += itemWidth + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
