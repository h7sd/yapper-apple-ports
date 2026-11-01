# Native original profile and settings reconstruction

This visual checkpoint uses the frozen, shipped Yapper web assets underlying the official Windows Electron client. It does not introduce a product WebView. The profile, image viewer, editor, account menu and settings controls are SwiftUI/native image views. Authentication retains the separately approved login-only browser window.

The complete CSS rule index, media-query context and SHA-256 references are in [ORIGINAL-UI-SPEC.json](ORIGINAL-UI-SPEC.json). Profile/settings consumer offsets and immutable asset hashes are in [original-profile-settings-evidence.json](original-profile-settings-evidence.json). The frozen sources live outside the shipping app in `work/native-full-parity/web-complete` and `invite-route`; the official Windows packaging boundary is documented in [WINDOWS-CLIENT-EVIDENCE.md](WINDOWS-CLIENT-EVIDENCE.md).

## Reconstructed geometry

- `NativeProfileView` follows the PC2 profile card: 440px maximum width, 3:1 banner, 96px avatar with 7px rim, -52px avatar overlap, 16px horizontal body inset, 24px name (20px on compact mobile), username/pronouns/chips row, quick actions, 13px status and 12px-radius profile sections with 10px/12px padding. The original consumer has About me, Links, join date and private note sections; Discord Main/Board/Activity/Wishlist tabs were not invented.
- Actual profile `accent_color` and `accent_color2` drive the profile gradient. The shipped module6999 average relative-luminance threshold0.3 selects the matching dark-ink/white-panel branch for pale themes. Public community cosmetic assets and image crop/rotation remain native. Missing remote profile artwork uses the account's initials or Yapper accent; no private screenshot images are bundled.
- The profile editor uses original field typography and controls, the native image picker/crop renderer and a live 3:1 banner/avatar preview. Existing signed media upload, scanning, temporary avatars, profile/status expiry and saving behavior is preserved.
- `NativeAccountView` follows the final base CSS mobile settings cascade: horizontal navigation, 40px minimum navigation targets, 8px gap, 12px/12px/8px navigation padding, 16px main padding and bottom safe-area clearance. Selected pills use the original accent. The account card uses the actual 3:1 banner consumer (90px fallback when no banner exists), 80px avatar with 6px rim/-34px overlap, 20px account name and inline account rows.
- Security and plugin main pages use explicit original settings sections and controls instead of grouped system Form/List boxes. All existing actions remain wired, including security confirmations and login/session guards.
- `OriginalAccountMenuView` renders the 320px identity popover with actual profile banner/avatar/name, a real availability picker, custom-status/profile editing and profile/settings navigation. Unsupported notification tones or account switching are not presented as working switches.

## Scope and verification limits

These are source-derived geometry and native interaction changes. Static source evidence alone does not prove pixel equality against an authenticated account. The base CSS branch was selected because activation of `html.new-look` was not observed in the frozen JavaScript/root HTML. Source theme/tint branches, Dynamic Type, account-specific content and the final responsive cascade still require visual comparison on actual devices.

Email/password/Authenticator setup/removal and group creation now use the original modal geometry (header20px/20px/8px, body12px/20px, footer12px/20px/20px). Small security confirmations and passkey renaming still use native confirmation/alert semantics. Community, developer and account-data screens retain their separate existing implementations. Built-in CSS profile effects/name styles remain a functional parity gap; community image-based cosmetics are supported. The Yapinplugger plugin manager has no official upstream equivalent and intentionally adopts Yapper's existing settings controls rather than inventing upstream evidence. This checkpoint does not assert full 1:1 feature parity.

The Friends page now uses the original52px header, scrolling tabs,36px avatars,10px/8px rows with top dividers and round quick actions. Friend suggestions use the actual250px-minimum adaptive card grid,14px gaps,3:1 banners and52px avatars with4px rims. Server tags use the original96px-minimum badge-pick grid with10px gaps. Existing actions and accessibility identifiers remain available. The Online tab currently filters actually known cached participant presence; full global presence synchronization remains a functional gap.

Swift syntax parsing passes for the six changed/new UI files. Parent integration owns authoritative app builds and screenshots across the supported iPhone sizes. No real account/profile/security mutation was performed to validate this visual checkpoint.

## Actual React reference correction (2026-11-01)

The actual original React application was rendered offline against the synthetic fixture in `original-ui-reference/`. No real account or private screenshot assets were used. These captures exposed differences that static CSS reconstruction alone had missed. The native correction uses a transparent, dimmed PC2 bottom overlay with the source close button, identity-hash fallback banner, bottom edit action, user-ID copy action and actual friend composer. Own AppShell profiles and Friends profiles use this presentation; other legacy pushed profile entrypoints retain a page-mode fallback.

The measured account popover is300px wide, with a76px avatar plus5px rim, a3:1 banner,46px/16px/12px identity padding and33.6px action rows. Custom status is gated by the actual activity flag. The invented Settings row was removed; notification sounds uses the real native preference being integrated by root. The default account page now includes the three original account rows and their edit actions, privacy and Bug Hunting. Extra native client actions remain in their existing settings tabs rather than changing the original initial account page.

The corrected source batch passes an isolated Swift6 iOS17 typecheck using the real shared theme and OriginalYapper controls. Fresh native captures from the combined build still require comparison before claiming visual equality. Root owns packaging and final device-size QA.
