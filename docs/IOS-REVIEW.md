# iOS source review and verification limits

This is a bounded review of the iOS port's application-owned source. It is not a malware-free certification, an audit of all WebKit code, or a guarantee about the live Yapper service. The app is an unofficial port; the upstream names, artwork, website, account system, and service remain controlled by their respective owners.

## Scope and evidence

Reviewed source: `ios/Yapper/WebClient.swift`, `URLPolicy.swift`, `YapperApp.swift`, `resources/NativeBridge.js`, and `Info.plist`, together with `ios/tests/native-bridge.test.cjs` and `ios/YapperTests/URLPolicyTests.swift`. The review used source inspection and the bridge's 12 passing Node tests. The hosted Swift test also loads the live trusted document and calls the actual WKWebView reply handler; its execution status is recorded in VALIDATION.md. It did not log into an account, inspect private messages, grant camera/microphone permissions, place a real call, exercise real notification delivery, or perform a network penetration test. Build and simulator results are recorded separately in [VALIDATION.md](VALIDATION.md). The commit-pinned iOS workflow reproduces the Node bridge tests, an unsigned Release simulator build, and the scheme's hosted Swift/WebKit and original-login UI checks on a dynamically selected available iPhone simulator. Those live checks need the public service; CI does not convert a service outage into a passing test.

Source snapshot reviewed on **2026-10-30** (SHA-256; repository-relative paths):

```text
1fdac9e462526976c318d9a1c499a09ecc3fbd715f2f475f4bd21aaba773f29d  ios/Yapper/WebClient.swift
18e9dfd871bd5e8272ad68d063e47c68a6a01faf107fbcaaa359254d33251221  ios/Yapper/URLPolicy.swift
743abc741dab4ae9e651d87d9a472ea85b5f2e59273ac667dab0078d01acc408  ios/Yapper/YapperApp.swift
0dedd00a5aa704bb115b79b9b8d440c93d511ffe3e19306d5d26f6821a4dc002  ios/Yapper/resources/NativeBridge.js
b6c56cb06e75982b7fffb4cb9c35773164aed35ad59b498d5f1053f8d35ecc45  ios/Yapper/Info.plist
e6c8d72b56abe37cac634782a3c5c8f80b237f1b7f88a596a6be68e57190f10d  ios/tests/native-bridge.test.cjs
d2319a82b6a5d12a1b8b27e1872dd7ab162682694c4d07f447abe47cf9bb1f82  ios/YapperTests/URLPolicyTests.swift
```

## Trust boundaries

The interface loads the original responsive `https://www.yapper.website` in a persistent WKWebView. The view requests mobile content and adds the suffix `YapperIOS/1.1.0` to WebKit's user agent. It does not masquerade as Windows or Electron. Login sessions, page scripts, messages, media features, and server behavior come from the live website and can change independently of the native application release.

Both JavaScript and Swift constrain native requests. JavaScript is installed only in the main frame and gates its compatibility API on an exact HTTPS host set and the standard HTTPS port. Swift independently checks the message frame, the frame's security origin, the current web-view URL, the method allowlist, and the argument shape. The accepted hosts are `www.yapper.website`, `yapper.website`, `www.yapin.gg`, `yapin.gg`, `rt.yapper.website`, and `lk.yapper.website`. URL trust rejects embedded usernames/passwords and nonstandard ports. This is a native-privilege boundary, not an outgoing-network allowlist: the page can load third-party resources and make ordinary browser requests.

The native message handler accepts only `setBadge`, `notify`, `getSettings`, and `setSettings`. There is no application-owned generic shell, command execution, arbitrary native file read, process-list, global-input hook, or credential-export method in this iOS bridge. That observation is limited to the reviewed native interface, not the remote site's JavaScript or every system component.

The original 17-member `window.yapperDesktop` API is retained for compatibility with the website, with `platform: "ios"`. Screen capture/picking, process enumeration, global hotkeys, system idle, desktop activity detection, and binary auto-updates explicitly return unsupported results. `window.yapperIOS.capabilities` describes those limits; it does not claim background push or a system-wide activity monitor. Missing or rejected native requests resolve to safe failure values in the JavaScript wrapper.

## Navigation and popup behavior

Custom `yapper:` deep links are rebuilt on the fixed HTTPS home origin. Notification destinations are resolved as contained paths on that origin, and JavaScript discards cross-origin or credential-bearing notification destinations. The URL-policy tests include origin-lookalike hosts, nonstandard ports, embedded credentials, external schemes, and slash/backslash notification-path cases.

Ordinary external HTTP/HTTPS/mail links are handed to the operating system. There is no application-owned TLS-validation bypass or arbitrary URL-scheme launcher in the reviewed code. A permitted remote page can still direct users to external web pages; this review does not assess those destinations.

The Discord-import popup receives a new, empty user-content controller instead of the main view's bridge handler or injected script. Its navigation policy permits the intended blank/import/trusted-site/Discord flow. Its media delegate explicitly denies camera and microphone requests. This explicit denial matters because [WebKit otherwise defaults to prompting for media permission](https://developer.apple.com/documentation/webkit/wkuidelegate/webview(_:requestmediacapturepermissionfor:initiatedbyframe:type:decisionhandler:)). Cross-origin popup content remains subject to WebKit's normal browser-origin rules.

## Native permissions and local state

Camera and microphone access is available only to a trusted main-frame origin and returns WebKit's `.prompt` decision. No reviewed branch automatically grants these permissions. The native code configures the audio session for a voice call, including speaker/Bluetooth routing. Actual call behavior, permission denial recovery, Bluetooth devices, backgrounding, and locked-device behavior still require device testing.

Local notifications default to off. Enabling them is an explicit setting change that requests normal iOS notification authorization. Sending a notification does not itself request authorization; it requires the stored opt-in and an authorized/provisional system status. Native notification/badge failures return false rather than claiming successful delivery. There is no APNs registration, push provider, or background-push entitlement in this port. Normal iOS suspension can stop web-session work; continuous background calls and message delivery are not established by the current checks.

The app uses WKWebView's default persistent website data store and keeps its native notification preference in UserDefaults. Account cookies and other site storage therefore live in the app's normal WebKit container. Those sessions, provisioning profiles, signing keys, credentials, and private chat captures are not repository inputs.

## Findings addressed during source review

The initial native implementation returned success even when notification authorization or scheduling failed. The reviewed implementation was changed to report native permission/operation failure. The import popup initially relied on WebKit's default media behavior; an explicit deny delegate was added. These are source-level corrections, not claims that real-device permission and delivery scenarios have passed.

The opt-in operation now increments a settings revision before awaiting system consent. A completed older request cannot overwrite a newer stored preference. Notification sending rechecks the stored opt-in after awaiting the system authorization status. These guards were inspected in source; the Node tests do not exercise Swift actor scheduling or the system authorization dialog.

The handler checks the current trusted URL again before replying after an asynchronous operation. This is a host-level check, not a per-document navigation-generation token: a request already accepted from a trusted document can finish after navigation, and moving between trusted hosts does not invalidate it. The reply API returns operation results/preferences, not cookies or account tokens; no credential leak was established by this review. A stronger cancel-on-navigation guarantee is not claimed.

## Remaining limits

The remotely served website/backend, WebKit's implementation, the complete Apple frameworks, the App Store distribution process, and the original Linux dependency tree were not exhaustively audited here. A simulator smoke test cannot establish camera, microphone, audio routing, background behavior, push delivery, or real authentication compatibility. Signed installation and testing on an iPhone/iPad require an appropriate Apple signing profile; an unsigned IPA alone is not installable as an ordinary App Store app.

Checksums identify particular bytes relative to their published values. A successful build, a green test run, source visibility, or a valid local signature does not prove that a client or its remote service is harmless. Changes to trust hosts, permissions, bridge methods, popup handling, navigation, settings persistence, or signing capabilities require a new review.
