---
name: Original Yapper native iOS
description: Native Yapper interface with the user-pinned message-home arrangement.
colors:
  rail: "#141519"
  sidebar: "#1b1c21"
  main: "#222329"
  elevated: "#2b2c33"
  input: "#2d2e36"
  text: "#ececf1"
  secondary: "#a6a7b4"
  faint: "#9a9ca9"
  accent: "#ff6b4a"
  accent-fill: "#d4401e"
  on-accent: "#ffffff"
  border: "#ffffff12"
  hover: "#2f3038"
  active: "#383944"
  success: "#3fcf82"
  danger: "#f2555a"
  light-rail: "#e3e5e8"
  light-sidebar: "#f2f3f5"
  light-main: "#ffffff"
  light-elevated: "#ebedef"
  light-text: "#1d1f23"
  light-secondary: "#55575f"
  light-faint: "#5f616a"
  light-border: "#00000017"
  light-hover: "#e6e7ea"
  light-active: "#d7d9de"
  light-rail-action: "#208b58"
typography:
  body:
    fontFamily: Inter
    fontSize: 15px
    fontWeight: 400
    lineHeight: 21px
  message-author:
    fontFamily: Inter
    fontSize: 15px
    fontWeight: 650
  composer:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 400
    lineHeight: 22px
  chat-title:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 700
  account-name:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: 600
  home-title:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 700
  home-row-name:
    fontFamily: Inter
    fontSize: 15px
    fontWeight: 500
  home-preview:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 400
  home-metadata:
    fontFamily: Inter
    fontSize: 11px
    fontWeight: 400
  compact-account-name:
    fontFamily: Inter
    fontSize: 16px
    fontWeight: 600
  compact-account-status:
    fontFamily: Inter
    fontSize: 13px
    fontWeight: 400
  account-menu-name:
    fontFamily: Inter
    fontSize: 20px
    fontWeight: 800
    lineHeight: 24px
  account-menu-row:
    fontFamily: Inter
    fontSize: 14px
    fontWeight: 400
    lineHeight: 19.6px
rounded:
  control: 8px
  profile-section: 12px
  profile-card: 14px
  account-bar: 16px
  home-account-banner: 18px
  home-toolbar: 8px
  home-search: 10px
  home-friends: 10px
  home-panel: 24px
  composer: 22px
  send: 18px
spacing:
  tight: 4px
  compact: 6px
  regular: 8px
  row: 10px
  control: 12px
  content: 16px
  modal: 20px
components:
  button-primary:
    backgroundColor: "{colors.accent-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.control}"
    height: 40px
  button-secondary:
    backgroundColor: "{colors.elevated}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    height: 40px
  text-field:
    backgroundColor: "{colors.rail}"
    textColor: "{colors.text}"
    rounded: "{rounded.control}"
    height: 42px
  compact-composer:
    backgroundColor: "{colors.input}"
    textColor: "{colors.text}"
    typography: "{typography.composer}"
    rounded: "{rounded.composer}"
    height: 44px
  compact-send:
    backgroundColor: "{colors.accent-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.send}"
    size: 36px
  home-toolbar-secondary:
    backgroundColor: "{colors.elevated}"
    textColor: "{colors.secondary}"
    rounded: "{rounded.home-toolbar}"
    size: 32px
  home-toolbar-primary:
    backgroundColor: "{colors.accent-fill}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.home-toolbar}"
    size: 32px
---

# Original Yapper interface in native iOS

## Overview

Mode: Operate. The user rejected the generic SwiftUI appearance in 0.2.0 and requires Yapper's recognizable interface and functions in native code. The latest user-supplied mobile screenshot, reviewed on 1 November 2026, is the binding arrangement for the message home: left server rail, rounded message panel, search/inbox/friends/group toolbar, conversation previews and metadata, and a centered floating profile-art banner spanning the compact shell. This supersedes the earlier original-home arrangement. Preserve Yapper's existing palette, Inter, original vectors, actual account artwork and native application behavior; the screenshot's unrelated brand colors and private account content are not new assets or palette authority.

All application UI remains native SwiftUI/UIKit and uses the existing service layer. Only the already-approved temporary official web login may use WebKit for login/CAPTCHA. Keep the requested minimal welcome: logo, localized welcome, sign-in action and bottom terms/privacy links.

Candidate 0.2.3/build 6 retains the 0.2.2/build 5 home arrangement and adds bounded conversation Back, own-status, native gallery and send-confirmation fixes. The rail, floating account banner and source visual system remain binding. Other surfaces retain the original shipped CSS, SVG icons, fonts and component structure as their visual authority. Exact whole-app 1:1 parity remains **false**: legacy community, developer and call-management surfaces retain styling gaps; global presence, custom themes, full Vencord compatibility and backend push remain gaps; real-account acceptance is untested. Source reconstruction, fixture screenshots and successful protocol checks do not establish all account states or complete live-client parity.

**Source authority:** the latest user-pinned home screenshot and [PRODUCT.md](../PRODUCT.md) govern the current home arrangement. The screenshot remains a private visual reference and is not copied into distributable evidence. [ORIGINAL-UI-SPEC.md](docs/ORIGINAL-UI-SPEC.md), the hashed declarations/media contexts in [ORIGINAL-UI-SPEC.json](docs/ORIGINAL-UI-SPEC.json), and [ORIGINAL-PROFILE-SETTINGS.md](docs/ORIGINAL-PROFILE-SETTINGS.md) retain authority for Yapper's incumbent visual details and other surfaces. The original React references are [historical home](docs/original-ui-reference/original-react-mobile-reference.png), [account popover](docs/original-ui-reference/original-react-account-popover-reference.png), [own profile](docs/original-ui-reference/original-react-own-profile-reference.png), [friend profile](docs/original-ui-reference/original-react-friend-profile-reference.png), [My Account](docs/original-ui-reference/original-react-settings-reference.png), [conversation](docs/original-ui-reference/original-react-conversation-reference.png), [conversation with feature flags](docs/original-ui-reference/original-react-conversation-features-reference.png) and [typed composer](docs/original-ui-reference/original-react-conversation-typed-reference.png). These eight isolated original-component captures use synthetic fixtures, not authenticated account content. The historical home capture does not override the newer pinned arrangement.

## Colors

The base appearance uses closely spaced dark surfaces, pale text and Yapper's coral accent. The frontmatter records the currently implemented shared palette in [YapperTheme.swift](YapperNative/UI/YapperTheme.swift); light-prefixed entries are the source light branch except the home rail-action correction. Add/discover vectors use the darker light-only rail-action ink from [NativeOriginalShellViews.swift](YapperNative/UI/NativeOriginalShellViews.swift), retaining the existing success green in dark appearance. Light input shares light elevated, light accent uses accent-fill, and filled actions keep white text in both appearances. Source translucent accent selection, borders and profile colors retain their context-specific opacity.

**The Cascade Rule.** Resolve the winning selector, media condition and component stylesheet before copying a color or measurement. Root styles apply in order `2qaucrxfial_d.css`, `3q6l1rmfnadsh.css`, `14w-0tmtea6a-.css`, followed by loaded component CSS. The unproven `html.new-look` branch is not the default. Source light, tint and configured profile branches are distinct from that branch.

`NativeAvatar` uses one uppercased username initial and a seven-color hash of profile ID, falling back to username only when identity is absent. Preserve the source hash and palette in `OriginalAvatarFallback`; do not replace every fallback with coral or display-name initials. Source presence dots retain their online/idle/DND/offline shapes. Profile `accent_color`/`accent_color2`, public artwork, name banners and supported image cosmetics remain account data. `OriginalProfileContrast` uses the source average relative-luminance threshold (0.3) to select light profile ink and panel treatment. Broader custom-theme parity remains incomplete.

## Typography

Use the bundled original Inter variable font, registered through CoreText in [OriginalYapper.swift](YapperNative/UI/OriginalYapper.swift). Preserve its numeric weight axis, including message author weight (650), and `cv11`, `ss01`, `calt` features. The font is derived from the official WOFF2 with its tables retained; asset hashes and the Inter OFL are bundled. Optional upstream font branches do not replace primary Inter.

The frontmatter gives implemented typography at normal text size. Home titles use (16) bold, conversation names (15) medium or semibold for unmuted unread rows, previews (13), metadata (11), and compact account names/status (16/13). Other source roles retain their existing measurements. Ordinary body, labels, handles, status, messages and composer text scale through `UIFontMetrics`; text line boxes are minimums so larger text can grow. `NativeAvatar` initials and the `@` icon use `OriginalYapper.fixedFont`: these are fixed-size graphic glyphs inside fixed source geometry, hidden from accessibility as decoration. Do not scale them with body text or crop their contents at accessibility sizes.

**The Logical Pixel Rule.** Map a source CSS logical pixel to a native point at equivalent viewport and normal text size. Compare font family, numeric weight, features, line geometry and wrapping independently of browser/CoreText rasterization. Antialiasing differences are not evidence for changing the source typeface or spacing.

## Layout

`NativeAppShell` keeps the left rail and message panel at compact widths of at most (760 points). The rail is (72) wide with (48) tiles; the message panel fills the remaining width with a (24) top-leading corner and thin border. The current shell does not mount the earlier `NativeOriginalBottomBar`. Wider layouts retain that rail width, sidebar (260), a divider (1) and the main stage. Compact conversation navigation pushes the native conversation screen and hides the home shell; preserve edge-back behavior. Root entrypoints update `mobilePath` directly. Do not reintroduce a delayed selection observer that can push a conversation again after Back.

The message header uses (16) horizontal padding, top/bottom padding (18/14), title-to-toolbar stack spacing (4), and a toolbar stack with zero additional horizontal spacing. The (6) invisible padding around each toolbar box contributes to the visible title/control gap. Search, eligible inbox and new-group controls have visible (32×32) boxes and (18) glyphs, each with that padding for a (44×44) interaction region. The friends action has minimum visible height (32), minimum width (118), a semibold (13) full add-friend label, (10) radius and the same (6) outer interaction padding. Its normal-size label may wrap to two lines; `ViewThatFits` moves it to a separate row if the full toolbar does not fit. Conversation rows have minimum height (52), avatars (32), gap (12), horizontal/vertical padding (8/6), a (4) name-to-preview gap and selection radius (8). At accessibility sizes the toolbar wraps and row metadata moves below the preview while names/previews can occupy two lines.

The compact floating account banner is centered across the whole shell, including the rail, with maximum width (560), horizontal margins (12), bottom margin (10), minimum height (56), horizontal padding (12), no added vertical padding, radius (18), base avatar (48) and account-to-inbox gap (8). Avatar decoration can extend to (72), overlapping the slim banner; clip the banner background, not the identity artwork. The bell has an (18) glyph, visible (32×32) box and (6) outer padding for a (44×44) interaction region. The banner's actual measured height reserves content clearance in both rail and sidebar: height plus (24). It uses the signed-in account's public banner/crop, profile accent gradient and supported effect; banner artwork receives a black (0.5) readability overlay. Without artwork or accent metadata it uses the Yapper sidebar surface. Profile colors and artwork are account data, never copied from a reference account. Wider layout retains the source account bar: width (316), left/bottom margins (8), minimum height (66), radius (16) and avatar (32).

The account popover is (300) wide, limited to viewport minus (16). Compact placement is (12) from the left and the measured account height plus (20) above the safe-area bottom; wider placement remains left (8), bottom (82). Available height accounts for that placement before the existing `ViewThatFits`/scroll fallback. Its source avatar is (76) plus rim (5) on each side, positioned (14) from the card left and (52) from its top. Keep actual availability, activity-gated custom status, notification sounds and profile actions. The compact shell adds Settings and confirmed logout actions below those rows; those actions replace the removed compact settings/logout icons and bottom tabs.

Profiles use a bottom overlay with dimmed background, source close control and maximum width (440). The banner stays (3:1); avatar content is (96) plus rim (7) on each side, overlapping by (52). Preserve the (16) horizontal body inset and the source footer actions. Own AppShell and Friends entrypoints use this overlay; remaining legacy entrypoints retain a page presentation. Tall profiles use the existing fit/scroll fallback.

**The Safe Area Rule.** Extend surface backgrounds continuously beneath system bars while keeping real control clearance. The welcome legal footer and profile footer retain the device's actual bottom safe inset; filling the bottom background must not remove that inset. Verify normal iPhone, Pro Max and iPad, portrait and supported wide layouts, keyboard presentation and larger text.

## Elevation & Depth

The shell and messages obtain separation from Yapper surface colors, thin dividers and selection treatment. Preserve the pinned message-panel boundary, floating account-art banner, actual account popover, profile dimming, banner/overlapping avatar and native modal hierarchy. The home does not add generic cards, glass materials or decorative shadows. Activity cards require real, supported account activity data before any corresponding UI is introduced.

## Shapes

Use the observed source and current-home radii in the frontmatter. The home message panel has only its top-leading corner rounded (24), toolbar icon boxes use (8), search/friends controls use (10), and the compact account banner background uses (18). The compact composer is a pill using the final CSS cascade; its earlier radius (14) does not win. Source avatars remain circles, selected rail tiles retain their source rounding/selection marker, and conversation/message rows stay flat and full width. Retain visible dimensions while providing interaction regions of at least (44 points); a small glyph is not a reason to enlarge surrounding gaps.

## Components

- **Native vectors and controls.** `OriginalYapperIcon` renders the original exported (24×24) SVG paths natively, with source stroke/fill geometry. Unknown keys fail closed rather than substituting another icon vendor. `OriginalYapperButtonStyle`, `OriginalYapperTextFieldStyle` and `OriginalYapperToggleStyle` provide the source button, input and switch treatments; preserve real disabled, pressed, loading, validation and error states, native input/keyboard behavior and accessibility labels. System confirmation semantics remain on the small security actions that still use native alerts.
- **Conditional shell.** Preserve source capability gates and account/server context for discovery, inbox, calls, voice messages and activity. The recent unread DM rail requires `ui_refresh`, a non-off `yapper-rail-dms` preference and an authoritative preference snapshot. It shows at most four recent unread non-server conversations, excludes active/muted/hidden conversations and uses the source ordering/age conditions. Do not invent a muted-with-mention exception without authoritative mention counts. Synthetic fixture flags do not prove a live account's eligibility.
- **Message-home toolbar.** `NativeConversationList` exposes local conversation search, capability-gated inbox, a visibly labelled add-friend action and new group creation. Add friend opens username plus optional note (maximum 100 UTF-16 units), with a visible Show friends action leading to the friends list and its eligible user-search route. Its context menu remains an optional shortcut. Local search filters conversation titles and last-message text and has its own native field/close action. Do not place a static activity-card carousel above the rows when no real activity source is wired.
- **Conversation metadata.** Home rows show the real last-message preview when available, or a group member count when no preview exists. The trailing metadata carries pin/mute state, a relative timestamp and the unread badge when not muted. Keep these tied to the conversation/preference data rather than fixture values. The DEBUG notice labels synthetic comparison content.
- **Compact account banner.** `NativeOriginalAccountBar` shows the current identity and presence, or a nonexpired custom status when the activity flag permits it, with the account's actual artwork. The identity/chevron opens the account menu; the bell opens inbox only when eligible. Compact Settings and logout live in the account menu. Logout retains its confirmation; wide settings/logout buttons remain in the account bar. Cosmetic fetch failure keeps the last successful same-account banner and must not block the message list. Own availability comes from the independent authenticated `my_status_pref` read, without optional notification-preference or blocks prerequisites. A successful JSON `null` keeps the existing same-account preference, defaulting a fresh local preference to Online as in the observed official client; HTTP, malformed and invalid-value errors must not invent Online. Preserve known DND/invisible through profile/list refresh and failed reads; a late sound-policy response must retain a newer committed preference, and playback must recheck the latest DND choice. Label own invisible status **Unsichtbar** in the banner/menu while retaining offline public presentation. This is own-preference behavior, not global presence parity.
- **Conversation header.** `NativeConversationView` uses compact header (48), horizontal padding (2/4), gap (2), avatar (26), title typography from the frontmatter and ordinary icon interaction boxes (44). Back has a full rectangular (48×48) target around its (22) glyph. Its action removes composer focus, closes the active conversation and cancels history/feature work immediately before navigation, while late read callbacks are rejected for the closed conversation. Retain the draft for reopening. Keep the source divider and call eligibility.
- **Message stream.** Preserve the conversation introduction, local-date separators and flat message rows: avatar (34), avatar glyph (16), horizontal/vertical padding (10/3), top separation (10) for ungrouped messages and source body typography. `NativeMessageGrouping` requires the same author, non-system messages, matching webhook identity, the same local date and an interval from zero to less than seven minutes. Replies and a supplied first-unread divider boundary break grouping. Do not reduce the helper to an author-only check or present an unwired unread-boundary state as complete parity.
- **Composer.** The compact minimum height, pill radius and send size/radius are in the frontmatter. Upload is (44×44) with glyph (24); text padding is (11/6/11/0), tools are (40×44), and send has top/bottom margin (4) and leading margin (2). Keep the typed/attachment/busy condition for showing send. The original phone branch excludes its standalone microphone on coarse-pointer devices; native recording remains available through the capability-gated action menu. Preserve drafts and retry state.
- **Native gallery attachment.** The attachment menu offers the native PhotosUI image/video picker and existing Files route. Select one item without broad photo-library permission; selection prepares the attachment and preserves the draft without sending. Show real progress/cancel and import errors. Copy the selected provider file into app-owned temporary storage within the existing (10 MB) limit, then clean it up on completion, failure or cancellation. Convert HEIC/oriented stills to supported JPEGs with orientation applied to pixels, preserve supported animation, retain MOV/MP4 MIME and attach a Live Photo's still. Sending continues through the mandatory existing upload-and-scan policy and service sequence.
- **Send confirmation.** Generate lowercase outgoing UUIDs and compare message/channel/author UUID identity semantically. Accept a full object or one-row array acknowledgement only for that identity. Reconcile an ambiguous successful response or 409 duplicate through one authenticated GET scoped to the expected message, channel and author, with no additional insert during reconciliation. Missing, malformed or foreign reconciliation rows and real permission failures remain errors. Canonical rendered message identities merge the acknowledgement with history/realtime once; a retry keeps its original send identity and draft until confirmed.
- **Profile and settings.** `NativeProfileView`, `OriginalProfileSection` and `OriginalAccountMenuView` follow the actual PC2 banner/avatar/status/name/handle/chips/body/actions structure. Preserve About me, Links, join date and private notes where supplied; no Discord Main/Board/Activity/Wishlist tabs are invented. `NativeAccountView` uses horizontal mobile settings navigation, source account rows and edit actions, privacy and Bug Hunting. My Account retains fallback banner (90), avatar (80) plus rim (6), overlap (34) and reserved close-control region (52). Security/group editors use source modal header/body/footer spacing. Plugin controls reuse the native source-style settings components without claiming an official upstream counterpart.
- **Welcome and legal footer.** The localized minimal welcome uses the real sign-in action. The bottom terms/privacy links retain native link actions, (44)-point interaction height and a horizontal-fit/vertical fallback. Background coverage and safe-area clearance remain independent.
- **Notification sounds.** `NativeNotificationSound` plays the bundled official message sample through native audio and the account menu exposes its real persisted preference. Playback observes active-app state, current user, visible conversation, DND, mute/hidden/block policy, duplicate suppression and sender throttling; it leaves the existing audio session routing intact. Do not represent staged upstream leave/ring samples as integrated native call tones or this foreground implementation as backend push delivery.

## Do's and Don'ts

- Do preserve the latest pinned message-home arrangement, Yapper palette, Inter, original vectors and real account artwork; keep other surfaces grounded in their original client sources.
- Do use the same labelled DEBUG synthetic content for original/native comparisons; release UI must use real per-account content and configured cosmetics.
- Do keep native accessibility interaction regions, text growth, scroll fallbacks and actual device safe insets without changing normal-size visible source geometry.
- Do establish fidelity with source-derived measurements and side-by-side captures at the same logical viewport. The original offline reference has zero CSS safe insets; native devices require their actual insets.
- Don't restore the older compact bottom tabs or old home-row geometry over the latest pinned arrangement. Don't introduce a system TabView, large navigation bars, grouped Form/List cards, substitute shell icons, rounded chat bubbles or a default `new-look` branch.
- Don't invent home activity cards, unread counts, previews, timestamps, profile art or capability eligibility. Reference account content remains private visual evidence.
- Don't broaden the login-only WebKit exception or replace the app with a website wrapper.
- Don't claim whole-app 1:1 parity, authenticated acceptance, full Vencord support, global presence or backend push from fixture captures or protocol results.
- Don't publish private user screenshots, account sessions, credentials or conversations.

The [0.2.3 validation report](reports/native-0.2.3-validation.json) records 250 logical unit tests in 29 suites (296 expanded cases) passed on iPhone 17 Pro Simulator with iOS 26.4.1. Its synthetic status, send, gallery and store regressions validate their stated local contracts. [The fix evidence](docs/INTERACTION-FIXES-0.2.3.md) records the observed service/source contracts.

Six selected UI cases have passing coverage across iPhone 17 Pro, Pro Max and iPad Pro: eighteen successful case/device pairs assembled from initial and targeted runs, not one clean full-matrix invocation. They include Back/draft, own status, existing send/server flows and actual system-picker photo/video selection. Initial and intermediate gallery-selector failures remain recorded; opening Photos also produced `_UIReparentingView` runtime warnings. [The interaction captures](reports/interaction-captures-0.2.3.json) show the anonymous picker and prepared photo/video attachments. Real-account delivery, actual upload/scan, iCloud media retrieval and physical-device acceptance remain unverified.

The frozen 0.2.3 device Release archive and universal arm64/x86_64 Simulator Release build passed. [Package inspection](reports/package-verification-0.2.3.json) passed 217 checks against the delivered ZIP/IPA bytes, with all 83 shipping Swift source hashes matching the frozen source. The exact inspected Simulator ZIP was installed and launched on the owned iPad without fixture arguments; its [German welcome capture](docs/images/welcome-0.2.3-release-de-ipad.png) shows the minimal welcome and bottom legal links without an error. The iPhone IPA remains unsigned and requires the user’s own Apple provisioning. `SessionVault.swift` and `Models.swift` retain their exact 0.2.2 hashes; the prior isolated Keychain probe remains historical evidence for unchanged source, not a new 0.2.3 probe. Local success does not establish whole-app parity or a comprehensive security audit.

The retained home geometry follows the frozen 0.2.2 `NativeAppShell`, `NativeOriginalShellViews` and `NativeOriginalConversationList` baseline. [Historical 0.2.2 captures](reports/reference-ui-captures-0.2.2.json) contain thirty default dark/light primary-surface images across iPhone Pro, Pro Max and iPad, plus five dark Pro Max accessibility-large images. [The independent finish review](reports/reference-layout-finish-0.2.2.json) closed the three home findings in those supplied fixture states: geometry/banner silhouette, Friends discoverability and light rail-action contrast. [0.2.2 validation](reports/native-0.2.2-validation.json) records 219 logical unit tests in 25 suites (236 expanded cases), before the final UI-only geometry, label, navigation and accessibility corrections, and merged passing coverage for twelve selected UI cases across three devices (36 case/device pairs). It does not describe one clean final full-matrix invocation. That release's frozen Release builds, 208 package checks, isolated Keychain probe and exact-ZIP signed-out iPad launch also passed; those results do not validate new 0.2.3 artifacts.

The 0.2.2 fixture captures do not validate live banner artwork, every decorated-avatar fit, long lists or real-account acceptance. Its new home controls have source interaction regions of at least (44); representative flow tests do not independently establish every boundary-coordinate route, VoiceOver order or the previously qualified overlapping compact account-menu hit shapes. Expanded presence-menu overflow, all orientations and all accessibility configurations remain outside the bounded pass. Unit, screenshot and package success do not establish whole-app parity or a comprehensive security audit.

Historical 0.2.1 comparison evidence remains indexed in [its capture manifest](reports/original-ui-captures-0.2.1.json): thirty default dark/light captures on iPhone Pro, Pro Max and iPad, plus five dark Pro Max accessibility-large captures. Its final large-font run confirms fixed graphic glyphs, growing text lines and profile-footer clearance for that build. [The independent 0.2.1 finish review](reports/original-ui-finish-review.json) preserves the bounded primary visual findings and qualifications; [0.2.1 runtime validation](reports/native-0.2.1-validation.json) records the merged functional runs and their timing. Those older home captures do not validate the new 0.2.2 arrangement. Invisible (44)-point regions do not establish independent effective target heights where adjacent shapes overlap; expanded status-menu overflow and physical boundary taps remain unverified. These checks do not establish authenticated acceptance or whole-app parity.
