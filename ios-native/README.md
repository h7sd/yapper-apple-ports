# Yapper Native for iOS

An early iOS client with **native SwiftUI conversations, messages and settings**, plus a temporary WebView exclusively for official web sign-in. This is a separate application (`website.yapper.native.ios`) alongside the existing iOS client. It does not import any existing Safari, browser or wrapper session or replace the other client's installation.

The welcome screen shows Yapper's mark, a localized welcome title and sign-in action; terms/privacy links stay at the bottom. German and English follow the device's preferred supported language, with English fallback. The official page handles email/username sign-in, CAPTCHA and TOTP, then the temporary window closes. Conversation lists, paginated messages, text sending, incoming updates, account settings, keyboard handling and Dynamic Type remain native.

## Official web sign-in

Version 0.1.0 attempted direct native password login; the user reported a required CAPTCHA response. On 31 October 2026 the user approved the narrow web-login exception while keeping all chat screens native.

Version 0.1.1 opens the official sign-in link `https://yapin.gg/?auth=in` in a fresh, nonpersistent app-owned WebView. The website's own `auth=in` route selects its login form instead of the public marketing page. Credentials and verification are submitted by the user to Yapper's own page. A scoped bridge observes only fresh successful authentication HTTP responses from that login. It never reads passwords/request bodies, cookies, browser storage, Safari or another client's existing session. The native client validates the new session against Yapper's authentication server and current profile before saving it in its device-only Keychain. A verified second factor requires the corresponding higher-assurance session before entering native chats.

The website's authenticated chat UI is covered while the native session is being validated; success dismisses the web component. Cancellation/restart invalidates the attempt. Brief app switching for an authenticator is supported without permitting a background session commit. CAPTCHA is completed normally by the user; no solver, fake verification, forged origin or browser-identity spoofing is added.

**Real-account sign-in and live message delivery still require the user's device validation.** Automated tests use synthetic sessions; the public-page smoke check never submits credentials or CAPTCHA. Google/external-provider popup compatibility is not claimed; use email/username for this login flow. The official identity-only developer OAuth route does not grant chat access and is not substituted for a chat session.

See [the authentication investigation](docs/AUTH-HANDOFF-INVESTIGATION.md) and [observed API contract](docs/API-CONTRACT.md) for source evidence and limitations.

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

Current scoped results appear in [the native test report](reports/tests.json) and [package inspection](reports/package-verification.json). The sign-in component is the only source directory permitted to import WebKit; chat screens and core requests remain native. Build checks include resource/localization packaging, archive integrity, separate app identity and excluded Debug entrypoints/signing credentials. Local results do not imply green hosted CI; the existing GitHub account restriction remains separate.

The [actual shipping JavaScript bridge tests](reports/web-login-bridge-tests.json) compile the Swift-generated script and exercise it against mocked transport in Node: 89 checks passed. These are synthetic policy tests, not live authentication. Current visual captures show the [German welcome](docs/images/welcome-0.1.1-de-iphone-pro.png), [English welcome](docs/images/welcome-0.1.1-en-iphone-pro.png), [public official login form](docs/images/official-login-0.1.1-iphone-pro.png), [Pro Max accessibility text](docs/images/welcome-0.1.1-de-promax-accessibility.png) and [iPad welcome](docs/images/welcome-0.1.1-en-ipad.png).

Screenshots under `docs/images/` are anonymous test fixtures or the public, signed-out web page. Earlier 0.1.0 captures and results are historical rather than proof of the new login flow. No real conversations or account credentials are included.

## Credentials and data

Session tokens use the app's device-only Keychain item. Passwords are held only during sign-in; account tokens never enter appearance preferences, app groups, an analytics system or the repository. Native REST requests use an ephemeral URLSession with cookies/cache/credential storage disabled and all redirects rejected. The temporary official sign-in WebView uses a nonpersistent website data store and normal TLS/WebKit behavior, separate from those native requests. Authentication and data requests are restricted to the observed service origins; TLS verification uses normal Apple defaults. The public anonymous Supabase project key is public client configuration, not a service-role key.

Signing out cancels pending operations, disconnects live updates and clears the local session and drafts. Service-side token revocation is not claimed. Messages and account details are sent to Yapper's own services as part of using the client. The privacy manifest declares access to the app's own appearance preferences under Apple's [UserDefaults API reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype); it is not a completed App Store privacy label or a claim about Yapper's backend data handling.

The original app mark and service identity retain their existing owners. The native implementation is an unofficial community client and is not endorsed by Yapper/Yapin', Vencord or YapBoard. No signing identity, private conversations or account sessions are included.
