# Yapper clients with Yapinplugger

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Yapper users who want clients for their devices. The current iOS work serves the user who requested this repository and native chat screens.

## Product Purpose

Access Yapper conversations while retaining its recognizable identity. The user approved a first native iOS milestone containing sign-in, conversation lists and messages in SwiftUI.

## Operating Context

The repository already contains unofficial desktop clients and iOS/Android website shells. The native iOS app is a separate application so the existing working client and its session can be retained during development.

## Capabilities and Constraints

- Chat lists, messages and account settings use SwiftUI and direct service requests. On 31 October 2026, after CAPTCHA blocked the direct password login, the user explicitly approved a temporary WebView only for official web sign-in. No website UI is used for chats or account settings.
- The welcome screen contains the app mark, a welcome title in the device's supported language, a sign-in action, and terms/privacy links at the bottom. The user requested removal of the two introductory/preview paragraphs.
- Use observed service contracts; distinguish source inspection, simulated responses and live verification.
- Existing WebView plugins are not automatically compatible with the native app. Native calls, media capture, background push, full server management and plugin parity are outside the approved first milestone.
- Never publish account sessions, credentials, private conversations or signing keys. iPhone installation requires the user's own Apple signing.
- Future native feature scope remains open. Do not describe the first milestone as full feature parity.

## Brand Commitments

The user asked to preserve Yapper's own design, colors, artwork and identity. Earlier references established an enhanced profile/account strip and mobile navigation, including correct centering on Pro Max screens. This is an unofficial port, not an official Yapper/Yapin' or Vencord release.

## Evidence on Hand

The inspected official Linux AppImage, publicly shipped client assets, existing client source, local verification reports and anonymous screenshots. User-provided private account screenshots are visual references only and must not become public assets.

## Product Principles

- Preserve Yapper's identity while using native interaction and accessibility behavior.
- Keep working sessions and the existing client available during native development.
- Make errors, unavailable capabilities and verification limits clear.
- Protect credentials and distinguish test fixtures from real conversations.
