import SwiftUI
import WebKit
import CryptoKit

struct WebLoginSheet: View {
    @State private var model: WebLoginModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(store: NativeStore) {
        _model = State(initialValue: WebLoginModel(store: store))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Label("yapin.gg", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("native.webLogin.origin")
                if model.awaitingTwoFactor {
                    Text("login.web.mfa")
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
                ZStack {
                    if model.isFixture {
                        fixture
                    } else if let flow = model.flowID {
                        OfficialLoginWebView(model: model, flowID: flow)
                            .id(flow)
                            .opacity(model.hideWebContent ? 0 : 1)
                            .accessibilityHidden(model.hideWebContent)
                    }
                    if !model.isFixture, model.isLoading && !model.hideWebContent {
                        ProgressView("login.web.loading")
                            .padding(16)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            .accessibilityIdentifier("native.webLogin.loading")
                            .allowsHitTesting(false)
                    }
                    if model.hideWebContent {
                        Color(uiColor: .systemBackground).ignoresSafeArea()
                        if model.isVerifying {
                            ProgressView("login.web.verifying")
                                .accessibilityIdentifier("native.webLogin.verifying")
                        } else if let error = model.errorMessage {
                            VStack(spacing: 20) {
                                Image(systemName: "exclamationmark.circle").font(.largeTitle)
                                    .accessibilityHidden(true)
                                Text(error).multilineTextAlignment(.center)
                                    .accessibilityIdentifier("native.webLogin.error")
                                Button("common.retry") { model.retry() }
                                    .buttonStyle(.borderedProminent)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("native.webLogin.retry")
                            }
                            .padding(24)
                        }
                    }
                }
            }
            .navigationTitle("login.web.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        model.cancel()
                        dismiss()
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("native.webLogin.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.restart()
                    } label: {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(String(localized: "common.retry"))
                    .accessibilityIdentifier("native.webLogin.reload")
                }
            }
        }
        .interactiveDismissDisabled(model.isVerifying)
        .task { model.start() }
        .onChange(of: model.isComplete) { _, completed in if completed { dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() }
            else { model.pause() }
        }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var fixture: some View {
        #if DEBUG
        VStack(spacing: 24) {
            Label("login.web.fixture", systemImage: "testtube.2")
                .foregroundStyle(.secondary)
            Button("login.web.fixture.complete") { model.completeFixture() }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("native.webLogin.fixture.complete")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

@MainActor @Observable final class WebLoginModel {
    let store: NativeStore
    private(set) var flowID: UUID?
    var isLoading = true
    private(set) var isVerifying = false
    private(set) var awaitingTwoFactor = false
    private(set) var isComplete = false
    private(set) var errorMessage: String?
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var latestQueuedTokens: BrowserLoginTokens?
    @ObservationIgnored private var retryTokens: BrowserLoginTokens?
    @ObservationIgnored private var seenTokens: Set<Data> = []
    @ObservationIgnored private var cancelled = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var beganAt: Date?

    init(store: NativeStore) { self.store = store }

    var isFixture: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--native-ui-fixtures")
        #else
        false
        #endif
    }

    var hideWebContent: Bool { isVerifying || errorMessage != nil }

    func start() {
        guard flowID == nil, !cancelled else { return }
        flowID = store.beginBrowserSignIn()
        beganAt = Date()
        if flowID == nil { isComplete = store.authState == .signedIn }
    }

    func receive(_ tokens: BrowserLoginTokens, flow: UUID) {
        guard !cancelled, !isComplete, flowID == flow, seenTokens.count < 32 else { return }
        let hash = Data(SHA256.hash(data: Data(tokens.accessToken.utf8)))
        guard seenTokens.insert(hash).inserted else { return }
        if isVerifying || suspended { latestQueuedTokens = tokens; return }
        validate(tokens, flow: flow)
    }

    private func validate(_ tokens: BrowserLoginTokens, flow: UUID) {
        guard !cancelled, flowID == flow else { return }
        isVerifying = true
        awaitingTwoFactor = false
        errorMessage = nil
        retryTokens = tokens
        validationTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.store.completeBrowserSignIn(tokens: tokens, flowID: flow)
            guard !Task.isCancelled, !self.cancelled, self.flowID == flow else { return }
            self.isVerifying = false
            switch result {
            case .signedIn:
                self.retryTokens = nil
                self.latestQueuedTokens = nil
                self.webView?.stopLoading()
                self.isComplete = true
            case .requiresTwoFactor:
                self.retryTokens = nil
                if let queued = self.latestQueuedTokens {
                    self.latestQueuedTokens = nil
                    self.validate(queued, flow: flow)
                } else {
                    self.awaitingTwoFactor = true
                    self.webView?.evaluateJavaScript(BrowserLoginScript.revealTwoFactor, in: nil, in: .page) { [weak self] result in
                        guard let self, !self.cancelled, self.flowID == flow else { return }
                        if case .failure = result { self.failedToLoad() }
                    }
                }
            case .rejected:
                if let queued = self.latestQueuedTokens {
                    self.latestQueuedTokens = nil
                    self.validate(queued, flow: flow)
                } else {
                    self.errorMessage = self.store.errorMessage ?? String(localized: "login.web.failed")
                }
            }
        }
    }

    func failedToLoad() {
        guard !cancelled, !isVerifying, retryTokens == nil else { return }
        isLoading = false
        errorMessage = String(localized: "login.web.failed")
    }

    func blockedNavigation() {
        guard !cancelled, !isVerifying, retryTokens == nil else { return }
        errorMessage = String(localized: "login.web.blocked")
    }

    func retry() {
        guard !cancelled, let flow = flowID else { return }
        if let retryTokens { validate(retryTokens, flow: flow) }
        else { restart() }
    }

    func restart() {
        guard !cancelled, !isComplete else { return }
        if let flow = flowID { store.cancelBrowserSignIn(flowID: flow) }
        validationTask?.cancel()
        validationTask = nil
        webView?.stopLoading()
        webView = nil
        latestQueuedTokens = nil
        retryTokens = nil
        seenTokens = []
        errorMessage = nil
        awaitingTwoFactor = false
        isVerifying = false
        isLoading = true
        flowID = store.beginBrowserSignIn()
        beganAt = Date()
    }

    func pause() {
        guard !cancelled, !isComplete, let flow = flowID else { return }
        suspended = true
        store.pauseBrowserSignIn(flowID: flow)
        validationTask?.cancel()
        validationTask = nil
        isVerifying = false
    }

    func resume() {
        guard !cancelled, !isComplete, suspended else { return }
        suspended = false
        store.setActive(true)
        if let beganAt, Date().timeIntervalSince(beganAt) >= 900 { restart(); return }
        guard let flow = flowID else { return }
        if let candidate = latestQueuedTokens ?? retryTokens {
            latestQueuedTokens = nil
            validate(candidate, flow: flow)
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let flow = flowID { store.cancelBrowserSignIn(flowID: flow) }
        validationTask?.cancel()
        validationTask = nil
        webView?.stopLoading()
        webView = nil
        flowID = nil
        retryTokens = nil
        latestQueuedTokens = nil
        seenTokens = []
        isVerifying = false
    }

    #if DEBUG
    func completeFixture() {
        guard isFixture, let flow = flowID, !cancelled else { return }
        isComplete = store.completeBrowserFixture(flowID: flow)
    }
    #endif
}

private struct OfficialLoginWebView: UIViewRepresentable {
    let model: WebLoginModel
    let flowID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(model: model, flowID: flowID) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        configuration.userContentController.add(context.coordinator, name: BrowserLoginPolicy.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(source: BrowserLoginScript.source(flowID: flowID), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        webView.accessibilityIdentifier = "native.webLogin.page"
        model.webView = webView
        webView.load(URLRequest(url: BrowserLoginPolicy.startURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.active = false
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: BrowserLoginPolicy.handlerName)
        uiView.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let model: WebLoginModel
        let flowID: UUID
        var active = true

        init(model: WebLoginModel, flowID: UUID) { self.model = model; self.flowID = flowID }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard active, model.flowID == flowID, message.name == BrowserLoginPolicy.handlerName,
                  let webView = message.webView, webView === model.webView,
                  let pageURL = webView.url,
                  BrowserLoginPolicy.acceptsFrame(isMainFrame: message.frameInfo.isMainFrame,
                      scheme: message.frameInfo.securityOrigin.protocol, host: message.frameInfo.securityOrigin.host,
                      port: message.frameInfo.securityOrigin.port, frameURL: message.frameInfo.request.url, currentURL: pageURL),
                  let tokens = try? BrowserLoginPolicy.tokens(from: message.body, flowID: flowID, pageURL: pageURL) else { return }
            model.receive(tokens, flow: flowID)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard active, model.flowID == flowID, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame?.isMainFrame != false {
                if BrowserLoginPolicy.isTrustedPage(url) { decisionHandler(.allow) }
                else {
                    decisionHandler(.cancel)
                    if navigationAction.navigationType == .linkActivated, url.scheme == "https", url.user == nil, url.password == nil {
                        UIApplication.shared.open(url)
                    } else { model.blockedNavigation() }
                }
            } else {
                // Turnstile's genuine challenge runs in cross-origin HTTPS subframes. They never receive our bridge script.
                decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" ? .allow : .cancel)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { if active { model.isLoading = true } }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if active { model.isLoading = false } }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if active, (error as NSError).code != NSURLErrorCancelled { model.failedToLoad() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if active, (error as NSError).code != NSURLErrorCancelled { model.failedToLoad() }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if active { model.failedToLoad() } }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard active, let url = navigationAction.request.url else { return nil }
            if BrowserLoginPolicy.isTrustedPage(url) { webView.load(navigationAction.request) }
            else if navigationAction.navigationType == .linkActivated, url.scheme == "https", url.user == nil, url.password == nil { UIApplication.shared.open(url) }
            else { model.blockedNavigation() }
            return nil
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}
