# Yapper Native for iOS

An early, fully native SwiftUI client with **no WebView, embedded website, JavaScript UI or plugin runtime**. This is a separate application (`website.yapper.native.ios`) alongside the existing iOS client. It does not import that client's website session or replace its installation.

The first milestone implements sign-in with email or username, token refresh and observed TOTP verification, existing direct/group conversation lists, message history with pagination, text sending with retry, incoming message updates, and native account/appearance settings. Yapper's original app mark and palette are retained. The client uses native navigation, safe areas, keyboard behavior and Dynamic Type.

## Sign-in verification boundary

The direct authentication requests are implemented from the published web client. **A successful sign-in with a real account has not been verified.** The website requests Cloudflare Turnstile tokens. Public authentication settings do not establish whether the backend requires one for every password login. Cloudflare documents that Turnstile needs a browser environment; this native application does not bypass that verification or extract browser sessions. If the service requires a challenge, a supported native sign-in flow from Yapper's operator is needed. Opening the official website does not transfer its session into this app.

The [observed API contract](docs/API-CONTRACT.md) records the exact source evidence and remaining unknowns. Mocked native tests and screenshots use clearly marked synthetic conversations; they do not demonstrate a live account session.

## Scope

Text direct/group messages and viewing existing attachments are the current focus. This milestone does not implement server/channel management, new conversation creation, attachment upload, calls, voice recording, screen sharing, background push, presence synchronization, server-side read markers, message editing/deletion/reactions or the existing JavaScript plugins. Unread badges reflect the bootstrap snapshot and incoming events rather than verified server read receipts. It is not a claim of feature parity with the web client. The existing iOS wrapper remains available for those features.

## Build

Open `YapperNative.xcodeproj` in Xcode. The committed project requires no third-party runtime packages. Select your Apple development team to run on a physical device.

```sh
./scripts/build-native.sh simulator
./scripts/build-native.sh archive
SIMULATOR_ID=<dedicated-simulator-udid> ./scripts/build-native.sh test
```

The archive command produces an **unsigned IPA**. Sign it with your own Apple development/distribution profile before installing; it is not an App Store or TestFlight release. The Simulator ZIP runs only in Xcode's iOS Simulator. Optional project regeneration uses Ruby and `xcodeproj` 1.27.0: `ruby scripts/generate-project.rb`.

## Verification

The final source passed 16 Swift Testing tests (17 parameter cases) and three native UI flows on iPhone 17 Pro. An earlier Pro Max run passed the then-current 15 core tests and the same three UI flows. A final layout run passed on Pro Max with accessibility-extra-large text and iPad Pro 13-inch. All devices were iOS 26.4.1 simulators. Dark/light iPad and phone/keyboard screenshots use synthetic data. [Detailed test scope](reports/tests.json).

Both Release targets built successfully. [39 package inspections](reports/package-verification.json) passed, including archive integrity, separate app identity, excluded test data/signing material, and no directly linked WebKit/JavaScriptCore or embedded website resources. These are local results; hosted CI has an existing account-level restriction and is not claimed to be green.

Anonymous screenshots: [sign-in](docs/images/native-login-pro-max.png), [conversations](docs/images/native-conversations-pro-max.png), [messages and keyboard](docs/images/native-messages-pro-max.png), [large text](docs/images/native-conversations-pro-max-accessibility-xl.png), [iPad light](docs/images/native-conversations-ipad-light.png). Minor visual limitations remain: decorative avatar initials truncate at the tested large accessibility size, and the iPad navigation header does not show its large title. Primary labels and controls remain available.

## Credentials and data

Session tokens use the app's device-only Keychain item. Passwords are held only during sign-in; account tokens never enter appearance preferences, app groups, an analytics system or the repository. REST requests use an ephemeral URLSession with cookies/cache/credential storage disabled and all redirects rejected. Authentication and data requests are restricted to the observed service origins; TLS verification uses normal Apple defaults. The public anonymous Supabase project key is public client configuration, not a service-role key.

Signing out cancels pending operations, disconnects live updates and clears the local session and drafts. Service-side token revocation is not claimed. Messages and account details are sent to Yapper's own services as part of using the client. The privacy manifest declares access to the app's own appearance preferences under Apple's [UserDefaults API reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype); it is not a completed App Store privacy label or a claim about Yapper's backend data handling.

The original app mark and service identity retain their existing owners. The native implementation is an unofficial community client and is not endorsed by Yapper/Yapin', Vencord or YapBoard. No signing identity, private conversations or account sessions are included.
