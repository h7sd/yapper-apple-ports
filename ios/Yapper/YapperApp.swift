import SwiftUI
import UIKit

@Observable final class AppNavigation {
    static let shared = AppNavigation()
    var settingsPresented = false
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        AppNavigation.shared.settingsPresented = true
        completionHandler(true)
    }
}

@main struct YapperApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var client = WebClient()
    @State private var navigation = AppNavigation.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.055, green: 0.055, blue: 0.065).ignoresSafeArea()
                WebSurface(client: client)
                if let failure = client.failure {
                    VStack(spacing: 18) {
                        Image("AppMark").resizable().frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 16))
                        Text("Yapper is unavailable").font(.title2.bold())
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Retry", action: client.retry).buttonStyle(.borderedProminent).tint(.orange)
                        Button("Open in browser") { UIApplication.shared.open(URLPolicy.home) }
                        Button("App Settings") { navigation.settingsPresented = true }
                    }
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.055, green: 0.055, blue: 0.065))
                    .accessibilityIdentifier("connectionError")
                } else if client.loading {
                    ProgressView().tint(.orange).accessibilityLabel("Loading Yapper").allowsHitTesting(false)
                }
            }
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                if url.scheme == "yapper", url.host == "app-settings" { navigation.settingsPresented = true }
                else { client.open(url) }
            }
            .onChange(of: phase) { _, value in
                client.lifecycle(value == .active ? "active" : value == .background ? "background" : "inactive")
            }
            .sheet(isPresented: $navigation.settingsPresented) { NativeSettings(client: client) }
        }
    }
}

private struct NativeSettings: View {
    let client: WebClient
    @Environment(\.dismiss) private var dismiss
    @State private var notifications = UserDefaults.standard.bool(forKey: "nativeNotifications")
    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    Toggle("Local notifications", isOn: $notifications)
                        .onChange(of: notifications) { _, value in
                            Task { notifications = await client.setNotifications(value) }
                        }
                    Text("Notifications can be delivered while the web session is running. This build has no background push service.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Yapper") {
                    Button("Reload", action: client.retry)
                    Button("iOS permissions") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    Text("Unofficial iOS port of the Linux desktop client. The interface and your account are provided by Yapper.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("App Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
