import UIKit
import Security

// Compiled only by test-simulator-keychain.sh with the unmodified shipping Core sources.
// The probe has its own application identifier and sole Keychain access group.
@main @MainActor final class KeychainProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: controller.view.bounds)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.text = "Simulator Keychain probe"
        controller.view.addSubview(label)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        run()
        return true
    }

    private func run() {
        let vault: any SessionVault = KeychainSessionVault()
        var report = ProbeReport()
        do { try vault.clear(); report.preflight = true } catch { report.preflight_status = status(error) }
        let first = NativeSession(accessToken: "synthetic-probe-access-first", refreshToken: "synthetic-probe-refresh-first", expiresAt: Date(timeIntervalSince1970: 2_000_000_000), userID: "11111111-1111-4111-8111-111111111111")
        let second = NativeSession(accessToken: "synthetic-probe-access-updated", refreshToken: "synthetic-probe-refresh-updated", expiresAt: Date(timeIntervalSince1970: 2_000_003_600), userID: first.userID)
        if report.preflight {
            do { try vault.save(first); report.write = true } catch { report.write_status = status(error) }
            do { report.read = try vault.read() == first } catch { report.read_status = status(error) }
            do { try vault.save(second); report.update = try vault.read() == second } catch { report.update_status = status(error) }
            do { try vault.clear(); report.delete = try vault.read() == nil } catch { report.delete_status = status(error) }
        }
        // Cleanup is restricted to the same exact shipping query in the probe's sole access group.
        do { try vault.clear(); report.cleanup = try vault.read() == nil } catch { report.cleanup_status = status(error) }
        report.all_passed = report.preflight && report.write && report.read && report.update && report.delete && report.cleanup
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: documents.appendingPathComponent("keychain-report.json"), options: .atomic)
        } catch { /* No tokens, raw errors, or account data are logged. A missing report fails the driver. */ }
    }

    private func status(_ error: any Error) -> Int32 {
        if case let NativeClientError.keychain(value) = error { return value }
        return -1
    }
}

private struct ProbeReport: Encodable {
    var preflight = false
    var write = false
    var read = false
    var update = false
    var delete = false
    var cleanup = false
    var all_passed = false
    var preflight_status: Int32 = errSecSuccess
    var write_status: Int32 = errSecSuccess
    var read_status: Int32 = errSecSuccess
    var update_status: Int32 = errSecSuccess
    var delete_status: Int32 = errSecSuccess
    var cleanup_status: Int32 = errSecSuccess
}
