import SwiftUI
import UIKit
import WebKit
import UserNotifications
import AVFAudio
import Observation
import os

private let logger = Logger(subsystem: "website.yapper.ios", category: "WebClient")

struct WebSurface: UIViewRepresentable {
    let client: WebClient
    func makeUIView(context: Context) -> WKWebView { client.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@Observable final class WebClient: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var loading = true
    private(set) var failure: String?
    private var lastURL = URLPolicy.home
    private var loadDeadline: Task<Void, Never>?
    private var popup: PopupController?
    private let notificationDelegate = NotificationDelegate()
    private var notificationSettingsRevision = 0
    private let preferences: UserDefaults
    private let ephemeralSession: Bool
    private var scriptSettingsRevision = 0
    private(set) var yapperCordEnabled: Bool
    private(set) var yapperCordError: String?
    private(set) var enhancedProfileLayoutEnabled: Bool
    private(set) var appearanceError: String?
    @ObservationIgnored private var handler: NativeHandler?

    @ObservationIgnored lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = ephemeralSession ? .nonPersistent() : .default()
        #if DEBUG
        // UI tests use a fresh in-memory session without touching the owner's cookies.
        if ProcessInfo.processInfo.arguments.contains("--yapper-uitest-ephemeral-session") {
            config.websiteDataStore = .nonPersistent()
        }
        #endif
        config.applicationNameForUserAgent = "YapperIOS/1.1.0"
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        let handler = NativeHandler(client: self)
        self.handler = handler
        config.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "yapperNative")
        installUserScripts(in: config.userContentController)
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.isOpaque = false
        view.backgroundColor = UIColor(red: 0.055, green: 0.055, blue: 0.065, alpha: 1)
        view.scrollView.backgroundColor = view.backgroundColor
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.keyboardDismissMode = .interactive
        view.accessibilityIdentifier = "yapperWebView"
        #if DEBUG
        view.isInspectable = true
        #endif
        view.load(URLRequest(url: lastURL))
        return view
    }()

    init(preferences: UserDefaults = .standard, ephemeralSession: Bool = false) {
        self.preferences = preferences
        self.ephemeralSession = ephemeralSession
        yapperCordEnabled = preferences.bool(forKey: YapperCordSupport.preferenceKey)
        enhancedProfileLayoutEnabled = YapperAppearanceSupport.isEnabled(in: preferences)
        super.init()
        if yapperCordEnabled && YapperCordSupport.bundledSource() == nil {
            yapperCordEnabled = false
            preferences.set(false, forKey: YapperCordSupport.preferenceKey)
            yapperCordError = "YapperCord is missing from this app. Reinstall the YapperCord build."
        }
        if enhancedProfileLayoutEnabled && YapperAppearanceSupport.bundledSource() == nil {
            enhancedProfileLayoutEnabled = false
            appearanceError = "The enhanced profile layout is missing from this app. Reinstall this build."
        }
        notificationDelegate.client = self
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    private func installUserScripts(in controller: WKUserContentController) {
        controller.removeAllUserScripts()
        if let url = Bundle.main.url(forResource: "NativeBridge", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        } else { logger.error("Native bridge resource is missing") }
        if enhancedProfileLayoutEnabled, let source = YapperAppearanceSupport.bundledSource() {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if yapperCordEnabled, let source = YapperCordSupport.bundledSource() {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    @discardableResult func setEnhancedProfileLayoutEnabled(_ enabled: Bool) -> Bool {
        guard enabled != enhancedProfileLayoutEnabled else { return true }
        guard !enabled || YapperAppearanceSupport.bundledSource() != nil else {
            appearanceError = "The enhanced profile layout is missing from this app. Reinstall this build."
            return false
        }
        scriptSettingsRevision += 1
        let revision = scriptSettingsRevision
        enhancedProfileLayoutEnabled = enabled
        preferences.set(enabled, forKey: YapperAppearanceSupport.preferenceKey)
        appearanceError = nil
        loading = true
        let view = webView
        installUserScripts(in: view.configuration.userContentController)
        if !enabled, URLPolicy.isTrusted(view.url) {
            view.callAsyncJavaScript("window.YapperAppearance?.destroy?.();", arguments: [:], in: nil, in: .page, completionHandler: { [weak self] _ in
                guard let self, scriptSettingsRevision == revision else { return }
                retry()
            })
        } else { retry() }
        return true
    }

    @discardableResult func setYapperCordEnabled(_ enabled: Bool) -> Bool {
        guard enabled != yapperCordEnabled else { return true }
        guard !enabled || YapperCordSupport.bundledSource() != nil else {
            yapperCordError = "YapperCord is missing from this app. Reinstall the YapperCord build."
            return false
        }
        scriptSettingsRevision += 1
        let revision = scriptSettingsRevision
        yapperCordEnabled = enabled
        preferences.set(enabled, forKey: YapperCordSupport.preferenceKey)
        yapperCordError = nil
        loading = true
        let view = webView
        installUserScripts(in: view.configuration.userContentController)
        if !enabled, URLPolicy.isTrusted(view.url) {
            view.callAsyncJavaScript("window.YapperCord?.destroy?.();", arguments: [:], in: nil, in: .page, completionHandler: { [weak self] _ in
                guard let self, scriptSettingsRevision == revision else { return }
                retry()
            })
        } else { retry() }
        return true
    }

    func openYapperCordManager() {
        guard yapperCordEnabled, !loading, URLPolicy.isTrusted(webView.url) else {
            yapperCordError = "Enable YapperCord and wait for Yapper to finish loading."
            return
        }
        webView.callAsyncJavaScript("if (typeof window.YapperCord?.open !== 'function') return false; window.YapperCord.open(); return true;", arguments: [:], in: nil, in: .page, completionHandler: { [weak self] result in
            if case .success(let value) = result, value as? Bool == true { self?.yapperCordError = nil }
            else { self?.yapperCordError = "The plugin manager could not open. Reload Yapper and try again." }
        })
    }

    func open(_ url: URL) {
        guard let target = URLPolicy.deepLink(url) else { return }
        lastURL = target
        failure = nil
        webView.load(URLRequest(url: target))
    }

    func retry() {
        failure = nil
        webView.load(URLRequest(url: lastURL))
    }

    func lifecycle(_ state: String) {
        guard URLPolicy.isTrusted(webView.url) else { return }
        webView.callAsyncJavaScript("window.__yapperNativeEvent?.('lifecycle', {state})", arguments: ["state": state], in: nil, in: .page, completionHandler: { _ in })
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failure = nil
        loadDeadline?.cancel()
        loadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, loading else { return }
            webView.stopLoading()
            loading = false
            failure = "Check your internet connection, then try again."
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadDeadline?.cancel()
        loading = false
        failure = nil
        if let url = webView.url, URLPolicy.isTrusted(url) { lastURL = url }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    private func failed(_ error: any Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadDeadline?.cancel()
        loading = false
        failure = "Check your internet connection, then try again."
        logger.error("Web navigation failed: \((error as NSError).code)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        failure = "Yapper stopped responding. Tap Retry to reload."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if URLPolicy.isTrusted(url) { return .allow }
        if url.scheme == "yapper" { open(url); return .cancel }
        // Subframes can contain embeds but never receive a native bridge or native media access.
        if navigationAction.targetFrame?.isMainFrame == false, ["https", "about", "blob"].contains(url.scheme ?? "") { return .allow }
        if URLPolicy.canOpenExternally(url) { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
        return .cancel
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard trusted(origin), URLPolicy.isTrusted(webView.url), frame.isMainFrame else { return .deny }
        // WebKit and iOS ask the user for each requested device. No automatic grants.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        return .prompt
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        // Preserve the original Discord import popup without granting it the native bridge.
        if navigationAction.request.url?.absoluteString == "about:blank" {
            configuration.userContentController = WKUserContentController()
            let popup = PopupController(configuration: configuration)
            self.popup = popup
            present(popup)
            return popup.webView
        }
        if let url = navigationAction.request.url {
            if URLPolicy.isTrusted(url) { webView.load(URLRequest(url: url)) }
            else if URLPolicy.canOpenExternally(url) { UIApplication.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let alert = UIAlertController(title: "Yapper", message: String(message.prefix(2000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert)
    }

    private func present(_ controller: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }

    func trusted(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "https" && URLPolicy.trustedHosts.contains(origin.host.lowercased()) && (origin.port == 0 || origin.port == 443)
    }

    func setNotifications(_ enabled: Bool) async -> Bool {
        notificationSettingsRevision += 1
        let revision = notificationSettingsRevision
        if !enabled { UserDefaults.standard.set(false, forKey: "nativeNotifications"); return false }
        let center = UNUserNotificationCenter.current()
        let permitted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        guard notificationSettingsRevision == revision else { return UserDefaults.standard.bool(forKey: "nativeNotifications") }
        UserDefaults.standard.set(permitted, forKey: "nativeNotifications")
        return permitted
    }

    func receive(_ method: String, args: [String: Any]) async -> Any? {
        switch method {
        case "setBadge":
            let count = min(9999, max(0, (args["count"] as? NSNumber)?.intValue ?? 0))
            guard UserDefaults.standard.bool(forKey: "nativeNotifications") else { return false }
            do { try await UNUserNotificationCenter.current().setBadgeCount(count); return true }
            catch { return false }
        case "getSettings": return settings()
        case "setSettings":
            guard let enabled = args["nativeNotifications"] as? Bool else { return false }
            return await setNotifications(enabled) == enabled
        case "notify":
            guard UserDefaults.standard.bool(forKey: "nativeNotifications") else { return false }
            let center = UNUserNotificationCenter.current()
            let authorization = await center.notificationSettings()
            guard UserDefaults.standard.bool(forKey: "nativeNotifications") else { return false }
            guard authorization.authorizationStatus == .authorized || authorization.authorizationStatus == .provisional else { return false }
            let content = UNMutableNotificationContent()
            content.title = String((args["title"] as? String ?? "Yapper").prefix(180))
            content.body = String((args["body"] as? String ?? "").prefix(2000))
            content.userInfo = ["path": args["url"] as? String ?? "/"]
            do { try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)); return true }
            catch { return false }
        default: return nil
        }
    }

    private func settings() -> [String: Any] {
        ["platform": "ios", "nativeNotifications": UserDefaults.standard.bool(forKey: "nativeNotifications"),
         "closeToTray": false, "startMinimized": false, "openAtLogin": false, "hwAccel": true, "hwAccelNow": true,
         "activity": false, "customGames": []]
    }

    func openNotification(path: String) {
        lastURL = URLPolicy.siteURL(for: path)
        retry()
    }
}

private final class NativeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var client: WebClient?
    init(client: WebClient) { self.client = client }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let client, message.frameInfo.isMainFrame, client.trusted(message.frameInfo.securityOrigin),
              URLPolicy.isTrusted(message.webView?.url), let body = message.body as? [String: Any],
              let method = body["method"] as? String, ["setBadge", "notify", "getSettings", "setSettings"].contains(method),
              let args = body["args"] as? [String: Any] else { replyHandler(nil, "Unsupported native request"); return }
        Task {
            let result = await client.receive(method, args: args)
            // A page may have navigated while waiting for OS consent.
            guard URLPolicy.isTrusted(message.webView?.url) else { replyHandler(nil, "Navigation changed"); return }
            replyHandler(result, nil)
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var client: WebClient?
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo["path"] as? String ?? "/"
        await client?.openNotification(path: path)
    }
}

private final class PopupController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        view = webView
        let close = UIButton(type: .system)
        close.setTitle("Done", for: .normal)
        close.addTarget(self, action: #selector(closePopup), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.topAnchor, constant: 8), close.trailingAnchor.constraint(equalTo: webView.safeAreaLayoutGuide.trailingAnchor, constant: -16)])
    }
    @objc private func closePopup() { dismiss(animated: true) }
    func webViewDidClose(_ webView: WKWebView) { dismiss(animated: true) }
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.absoluteString == "about:blank" || URLPolicy.isTrusted(url) || (url.scheme == "https" && url.host == "discord.com" && url.user == nil && url.password == nil) { return .allow }
        return .cancel
    }
}
