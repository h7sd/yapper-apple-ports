# Yapper clients with Yapinplugger

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Yapper users who want clients for their devices. The current iOS work serves the user who requested this repository and native chat screens.

## Product Purpose

Access Yapper while retaining its recognizable identity. After the initial native iOS sign-in/DM milestone, the user explicitly requested the complete web-client feature set in native iOS and selected the official Windows client as additional reverse-engineering evidence.

## Operating Context

The repository already contains unofficial desktop clients and iOS/Android website shells. The native iOS app is a separate application so the existing working client and its session can be retained during development.

## Capabilities and Constraints

- Chat lists, messages and account settings use SwiftUI and direct service requests. On 31 October 2026, after CAPTCHA blocked the direct password login, the user explicitly approved a temporary WebView only for official web sign-in. No website UI is used for chats or account settings.
- The welcome screen contains the app mark, a welcome title in the device's supported language, a sign-in action, and terms/privacy links at the bottom. The user requested removal of the two introductory/preview paragraphs.
- Use observed service contracts; distinguish source inspection, simulated responses and live verification.
- The current scope expands to observed social, server, message, profile, call and settings flows. Existing WebView plugins are not automatically compatible with a native app. Track every observed feature and its implementation/verification separately; Windows-only OS hooks and operator-dependent services require explicit equivalents or documented limits.
- Never publish account sessions, credentials, private conversations or signing keys. iPhone installation requires the user's own Apple signing.
- Full native parity is the requested objective, not an achieved property of the earlier preview. Never advertise parity while required items remain incomplete or unverified.

## Brand Commitments

The user explicitly rejected the generic SwiftUI appearance of 0.2.0 and requires the same layout, design, typography, icons and controls as the official website/client. This supersedes earlier preferences for standard iOS chrome. Preserve Yapper's own colors, artwork and identity. Earlier references established an enhanced profile/account strip and mobile navigation, including correct centering on Pro Max screens. This is an unofficial port, not an official Yapper/Yapin' or Vencord release.

## Evidence on Hand

The inspected official Linux AppImage, publicly shipped client assets, existing client source, local verification reports and anonymous screenshots. User-provided private account screenshots are visual references only and must not become public assets.

## Product Principles

- Reproduce the official Yapper web/client interface exactly in native code; native accessibility and safe-area handling must preserve the original visible layout.
- Keep working sessions and the existing client available during native development.
- Make errors, unavailable capabilities and verification limits clear.
- Protect credentials and distinguish test fixtures from real conversations.
