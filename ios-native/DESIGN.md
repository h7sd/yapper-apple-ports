---
name: Original Yapper native iOS
description: Native reconstruction of the official Yapper web and client interface.
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
---

# Original Yapper interface in native iOS

## Overview

Mode: Operate. The user rejected the generic SwiftUI appearance in 0.2.0 and requires the exact official website/client UI with all functions. The original shipped CSS, SVG icons, fonts and component structure are the pinned visual authority. This document records that existing world and its native implementation; it does not authorize a new visual direction or a reinterpretation through iOS defaults.

All application UI remains native SwiftUI/UIKit and uses the existing service layer. Only the already-approved temporary official web login may use WebKit for login/CAPTCHA. Keep the requested minimal welcome: logo, localized welcome, sign-in action and bottom terms/privacy links.

Candidate 0.2.1/build 4 implements the primary source UI. Exact whole-app 1:1 parity remains **false**: legacy community, developer and call-management surfaces retain styling gaps; global presence, custom themes, full Vencord compatibility and backend push remain gaps; real-account acceptance is untested. Do not turn source reconstruction, fixture screenshots or successful protocol checks into a claim that all functions and screens match the live client.

**Source authority:** [ORIGINAL-UI-SPEC.md](docs/ORIGINAL-UI-SPEC.md), the hashed declarations/media contexts in [ORIGINAL-UI-SPEC.json](docs/ORIGINAL-UI-SPEC.json), and [ORIGINAL-PROFILE-SETTINGS.md](docs/ORIGINAL-PROFILE-SETTINGS.md). The actual original React references are [home](docs/original-ui-reference/original-react-mobile-reference.png), [account popover](docs/original-ui-reference/original-react-account-popover-reference.png), [own profile](docs/original-ui-reference/original-react-own-profile-reference.png), [friend profile](docs/original-ui-reference/original-react-friend-profile-reference.png), [My Account](docs/original-ui-reference/original-react-settings-reference.png), [conversation](docs/original-ui-reference/original-react-conversation-reference.png), [conversation with feature flags](docs/original-ui-reference/original-react-conversation-features-reference.png) and [typed composer](docs/original-ui-reference/original-react-conversation-typed-reference.png). These eight isolated original-component captures use synthetic fixtures, not authenticated account content.

## Colors

The base appearance uses closely spaced dark surfaces, pale text and Yapper's coral accent. The frontmatter records the currently implemented shared palette in [YapperTheme.swift](YapperNative/UI/YapperTheme.swift); light-prefixed entries are the source light branch. Light input shares light elevated, light accent uses accent-fill, and filled actions keep white text in both appearances. Source translucent accent selection, borders and profile colors retain their context-specific opacity.

**The Cascade Rule.** Resolve the winning selector, media condition and component stylesheet before copying a color or measurement. Root styles apply in order `2qaucrxfial_d.css`, `3q6l1rmfnadsh.css`, `14w-0tmtea6a-.css`, followed by loaded component CSS. The unproven `html.new-look` branch is not the default. Source light, tint and configured profile branches are distinct from that branch.

`NativeAvatar` uses one uppercased username initial and a seven-color hash of profile ID, falling back to username only when identity is absent. Preserve the source hash and palette in `OriginalAvatarFallback`; do not replace every fallback with coral or display-name initials. Source presence dots retain their online/idle/DND/offline shapes. Profile `accent_color`/`accent_color2`, public artwork, name banners and supported image cosmetics remain account data. `OriginalProfileContrast` uses the source average relative-luminance threshold (0.3) to select light profile ink and panel treatment. Broader custom-theme parity remains incomplete.

## Typography

Use the bundled original Inter variable font, registered through CoreText in [OriginalYapper.swift](YapperNative/UI/OriginalYapper.swift). Preserve its numeric weight axis, including message author weight (650), and `cv11`, `ss01`, `calt` features. The font is derived from the official WOFF2 with its tables retained; asset hashes and the Inter OFL are bundled. Optional upstream font branches do not replace primary Inter.

The frontmatter gives source typography at normal text size. Ordinary body, labels, handles, status, messages and composer text scale through `UIFontMetrics`; source text line boxes are minimums so larger text can grow. `NativeAvatar` initials and the `@` icon use `OriginalYapper.fixedFont`: these are fixed-size graphic glyphs inside fixed source geometry, hidden from accessibility as decoration. Do not scale them with body text or crop their contents at accessibility sizes.

**The Logical Pixel Rule.** Map a source CSS logical pixel to a native point at equivalent viewport and normal text size. Compare font family, numeric weight, features, line geometry and wrapping independently of browser/CoreText rasterization. Antialiasing differences are not evidence for changing the source typeface or spacing.

## Layout

`NativeAppShell` uses the original rail/sidebar/stage arrangement. Compact width is at most (760 points): rail (64), sidebar header (52), conversation rows (46) with avatars (32) and labels (15), and bottom navigation (56) plus the real bottom safe inset. Wider layouts use rail (72), sidebar (260), a divider and the main stage. Compact conversation navigation hides the home rail, sidebar and bottom navigation; preserve edge-back behavior.

The compact floating account bar is (64) high with top/horizontal/bottom margins (6/8/10), horizontal padding (12), gap (8), radius from the account-bar token, avatar (40) and account-button padding (4). Its visible action boxes are (40), with invisible interaction regions reaching at least (44). Wider layout keeps the existing source account-bar placement and dimensions.

The account popover is (300) wide, limited to viewport minus (16), placed (8) from the left and (116) above the compact safe-area bottom. Its avatar is (76) plus a rim (5) on each side, positioned (14) from the card left and (52) from its top. Keep the actual availability, activity-gated custom-status, notification-sounds and profile actions; the source menu has no invented Settings row. `ViewThatFits` preserves the natural card when it fits and uses a vertical scroll fallback when expanded status or larger text exceeds available height.

Profiles use a bottom overlay with dimmed background, source close control and maximum width (440). The banner stays (3:1); avatar content is (96) plus rim (7) on each side, overlapping by (52). Preserve the (16) horizontal body inset and the source footer actions. Own AppShell and Friends entrypoints use this overlay; remaining legacy entrypoints retain a page presentation. Tall profiles use the existing fit/scroll fallback.

**The Safe Area Rule.** Extend surface backgrounds continuously beneath system bars while keeping real control clearance. The welcome legal footer and profile footer retain the device's actual bottom safe inset; filling the bottom background must not remove that inset. Verify normal iPhone, Pro Max and iPad, portrait and supported wide layouts, keyboard presentation and larger text.

## Elevation & Depth

The shell and messages obtain separation from source surface colors, thin dividers and selection treatment. Preserve the actual account popover, profile dimming, banner/overlapping avatar and native modal hierarchy. Add depth only where the original component supplies it; generic floating cards, glass materials and new decorative shadows change the visual world.

## Shapes

Use the observed source radii in the frontmatter. The compact composer is a pill using the final CSS cascade; its earlier radius (14) does not win. Source avatars remain circles, selected rail tiles retain their source rounding/selection marker, and message rows stay flat and full width. Retain visible source dimensions while enlarging invisible hit regions to at least (44 points); a small glyph is not a reason to enlarge its visible box or surrounding gaps.

## Components

- **Native vectors and controls.** `OriginalYapperIcon` renders the original exported (24×24) SVG paths natively, with source stroke/fill geometry. Unknown keys fail closed rather than substituting another icon vendor. `OriginalYapperButtonStyle`, `OriginalYapperTextFieldStyle` and `OriginalYapperToggleStyle` provide the source button, input and switch treatments; preserve real disabled, pressed, loading, validation and error states, native input/keyboard behavior and accessibility labels. System confirmation semantics remain on the small security actions that still use native alerts.
- **Conditional shell.** Preserve source capability gates and account/server context for discovery, inbox, calls, voice messages and activity. The recent unread DM rail requires `ui_refresh`, a non-off `yapper-rail-dms` preference and an authoritative preference snapshot. It shows at most four recent unread non-server conversations, excludes active/muted/hidden conversations and uses the source ordering/age conditions. Do not invent a muted-with-mention exception without authoritative mention counts. Synthetic fixture flags do not prove a live account's eligibility.
- **Conversation header.** `NativeConversationView` uses compact header (48), horizontal padding (2/4), gap (2), avatar (26), title typography from the frontmatter and icon interaction boxes (44). Keep the source divider and call eligibility.
- **Message stream.** Preserve the conversation introduction, local-date separators and flat message rows: avatar (34), avatar glyph (16), horizontal/vertical padding (10/3), top separation (10) for ungrouped messages and source body typography. `NativeMessageGrouping` requires the same author, non-system messages, matching webhook identity, the same local date and an interval from zero to less than seven minutes. Replies and a supplied first-unread divider boundary break grouping. Do not reduce the helper to an author-only check or present an unwired unread-boundary state as complete parity.
- **Composer.** The compact minimum height, pill radius and send size/radius are in the frontmatter. Upload is (44×44) with glyph (24); text padding is (11/6/11/0), tools are (40×44), and send has top/bottom margin (4) and leading margin (2). Keep the typed/attachment/busy condition for showing send. The original phone branch excludes its standalone microphone on coarse-pointer devices; native recording remains available through the capability-gated action menu. Preserve drafts, retry state and existing send behavior.
- **Profile and settings.** `NativeProfileView`, `OriginalProfileSection` and `OriginalAccountMenuView` follow the actual PC2 banner/avatar/status/name/handle/chips/body/actions structure. Preserve About me, Links, join date and private notes where supplied; no Discord Main/Board/Activity/Wishlist tabs are invented. `NativeAccountView` uses horizontal mobile settings navigation, source account rows and edit actions, privacy and Bug Hunting. My Account retains fallback banner (90), avatar (80) plus rim (6), overlap (34) and reserved close-control region (52). Security/group editors use source modal header/body/footer spacing. Plugin controls reuse the native source-style settings components without claiming an official upstream counterpart.
- **Welcome and legal footer.** The localized minimal welcome uses the real sign-in action. The bottom terms/privacy links retain native link actions, (44)-point interaction height and a horizontal-fit/vertical fallback. Background coverage and safe-area clearance remain independent.
- **Notification sounds.** `NativeNotificationSound` plays the bundled official message sample through native audio and the account menu exposes its real persisted preference. Playback observes active-app state, current user, visible conversation, DND, mute/hidden/block policy, duplicate suppression and sender throttling; it leaves the existing audio session routing intact. Do not represent staged upstream leave/ring samples as integrated native call tones or this foreground implementation as backend push delivery.

## Do's and Don'ts

- Do preserve the original website/client visual world, exact source palette/cascade, density, font, vectors, responsive geometry and behavior while extending native coverage.
- Do use the same labelled DEBUG synthetic content for original/native comparisons; release UI must use real per-account content and configured cosmetics.
- Do keep native accessibility interaction regions, text growth, scroll fallbacks and actual device safe insets without changing normal-size visible source geometry.
- Do establish fidelity with source-derived measurements and side-by-side captures at the same logical viewport. The original offline reference has zero CSS safe insets; native devices require their actual insets.
- Don't introduce a system TabView, large navigation bars, grouped Form/List cards, substitute shell icons, rounded chat bubbles or a default `new-look` branch.
- Don't broaden the login-only WebKit exception or replace the app with a website wrapper.
- Don't claim whole-app 1:1 parity, authenticated acceptance, full Vencord support, global presence or backend push from fixture captures or protocol results.
- Don't publish private user screenshots, account sessions, credentials or conversations.

Current native comparison evidence is indexed in [the 0.2.1 capture manifest](reports/original-ui-captures-0.2.1.json): thirty default dark/light captures on iPhone Pro, Pro Max and iPad, plus five dark Pro Max accessibility-large captures. The final large-font run confirms fixed graphic glyphs, growing text lines and profile-footer clearance. [The independent finish review](reports/original-ui-finish-review.json) confirms the bounded primary visual pass and preserves its interaction and coverage qualifications. Invisible (44)-point regions do not establish independent effective target heights where adjacent shapes overlap; expanded status-menu overflow and physical boundary taps remain unverified. [Runtime validation](reports/native-0.2.1-validation.json) separately records merged functional runs and their exact timing. These checks do not establish authenticated acceptance or whole-app parity.
