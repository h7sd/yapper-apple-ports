# Original Yapper UI evidence

This specification records the original served app rather than a new visual design. The official Windows Electron package loads the website; its ASAR is not a frozen copy of the full chat UI. See [WINDOWS-CLIENT-EVIDENCE.md](WINDOWS-CLIENT-EVIDENCE.md) for the upstream installer URL, version and hashes.

[ORIGINAL-UI-SPEC.json](ORIGINAL-UI-SPEC.json) contains hashed source identities, CSS selectors, media conditions, exact declarations and UTF-8 byte offsets. The three root stylesheets are applied in this order: `2qaucrxfial_d.css`, `3q6l1rmfnadsh.css`, `14w-0tmtea6a-.css`, followed by component styles when loaded. Later rules matter: the original mobile composer resolves to a 44-point-high pill with radius22, rather than the earlier radius14 rule.

The original base palette is rail `#141519`, sidebar `#1b1c21`, main `#222329`, input `#2d2e36`, text `#ececf1`, secondary `#a6a7b4`, accent `#ff6b4a`, filled primary button `#d4401e`. `html.new-look` has a separate palette in CSS, but no default activation was found in either frozen JavaScript closure or root HTML. The runtime reference below has no `new-look` class. Tint and light appearance are separate source branches.

The primary application font is Inter, with the original 24×24 stroke icon geometry. The native asset directory contains the official brand files, extracted SVG path data and a variable TTF derived from the official Inter WOFF2 without editing its tables. The Inter OFL text and an asset hash manifest are retained in `YapperNative/OriginalAssets`. CoreText registration and weight400/500/600/650/700/800 were tested, including German glyphs. Only the Latin font is registered: Latin-ext has the same PostScript name and is staged separately. Optional Poppins/Rubik styles are not the primary application font.

## Actual original React reference

The [reference directory](original-ui-reference/) contains eight screenshots and [computed geometry](original-ui-reference/original-react-runtime.json), rendered by the original React component `rt()` and its original descendants. The reference harness appends one export assignment inside a separate copy of the original module factory. It does not rewrite component bodies. The original authentication/bootstrap wrapper is not run; the observed store receives clearly synthetic users, channel UUIDs, messages and feature flags.

The fixture matches the current native DEBUG profile names and messages: Yapper Demo, Nova, Milo, Yapper iOS and Demo Community. Base reference flags are explicitly enabled for `mobile_nav`, `ui_panel`, `ui_refresh`, `user_search` and `mentions_inbox`. Two chat captures also enable the observed `calls`, `voice_messages`, `media`, `search` and `pins` flags. These chosen states do not prove a live account's rollout eligibility.

A new isolated headless Brave context loads only localhost assets. Fetch is intercepted before dispatch; WebSocket, EventSource, workers and service workers are disabled or inert; CSP forbids connections; external page requests are denied. No real browser storage, account, cookies, Keychain entries or credentials are read. Across all eight captures there were no render errors. The original `/api/stripe/region` request was rejected before network dispatch. No settings, messages, calls or files were sent.

The viewport is402×874 CSS pixels at scale1. Desktop mobile emulation gives CSS safe-area insets of zero: native comparisons must apply the original safe-area rules to the device's real insets. The reference text defaults to original English; persisted language opt-in is absent. The exact German chunk named by the frozen loader currently returns404, so a different build's translation was not mixed in. Browser locale is de-DE; the native app follows the user's requested device language. No software keyboard was opened. Rasterization differs between browser and CoreText, so compare geometry, source typography, colors and vectors separately.

Useful references:

- [Home and DM sidebar](original-ui-reference/original-react-mobile-reference.png)
- [Account popover](original-ui-reference/original-react-account-popover-reference.png)
- [Own profile](original-ui-reference/original-react-own-profile-reference.png)
- [Friend profile](original-ui-reference/original-react-friend-profile-reference.png)
- [My Account settings](original-ui-reference/original-react-settings-reference.png)
- [Conversation baseline](original-ui-reference/original-react-conversation-reference.png)
- [Conversation with observed feature flags](original-ui-reference/original-react-conversation-features-reference.png)
- [Typed composer and send control](original-ui-reference/original-react-conversation-typed-reference.png)

## Final mobile measurements

The rail is64 wide. The sidebar header is52 high in the home reference; rows are46 high, with32-point avatars and15-point labels. The bottom navigation is56 high plus the bottom safe inset, with24-point icons and11-point semibold labels. Chat hides the rail, sidebar and bottom navigation.

The floating account bar is64 high with margin6/8/10, horizontal padding12, gap8 and radius16. Its background equals the sidebar in the base theme. The account button has4-point padding around a40-point avatar and8-point text gap, producing48-point height. Name is14/600, status12 with a16-point visible height. Action buttons are40×40. Fallback avatars use a single uppercased username initial and a seven-color hash of the profile ID; they do not use display-name initials or one uniform accent fill.

The chat header is48 high plus the top safe inset, horizontal padding2/4, gap2 and44×44 icon controls. The title avatar is26 and title16/700. Messages use15-point type at21-point line height, flat full-width rows with padding3/10 and top margin10. The composer has44-point minimum height, radius22, padding0/4/0/0 and no gap. Upload is44×44 with a24-point glyph. Text is16/22 with padding11/6/11/0; tools are40×44. The send control is36×36 with radius18 and margin4/0/4/2. Original phone UI omits the standalone microphone because its recording gate explicitly excludes coarse-pointer devices. Exposing voice recording in a native action menu is an adaptation that preserves functionality.

The profile sheet uses a3:1 banner. Avatar content is96 with a7-point surrounding border, producing110 total. My Account uses a90-point fallback banner,80-point avatar plus6-point border, and horizontal mobile settings navigation with a52-point reserved close-control region. Exact fixture-dependent positions are in the geometry JSON.

These references establish concrete original visual evidence. They do not establish exact whole-app native visual parity, live functional acceptance, operator access or full Vencord plugin compatibility. The native implementation and its current validation reports must retain their own remaining-gap statements.

The account popover is300 points wide (limited to viewport minus16), radius12, fixed8 from the left. With mobile navigation visible its final bottom offset is116 plus the safe inset. The avatar is76 content plus a5-point rim on each side, giving86 total; it sits14 from the card left and52 from its top. The name is20/800/24, handle13/18.2; menu rows are14/19.6 with padding7/8 and gap10. Measured values and the final winning placement selector are now included in the JSON.

Message grouping requires the same author, no system messages, matching webhook identity, less than7 minutes between messages and the same local calendar date. A reply or the first unread-divider message breaks grouping. The actual message avatar is34×34 with a16-point fallback glyph. Full helper conditions, including the source's timestamp arithmetic and webhook null handling, are recorded in the JSON.

Original notification samples are served under `/sounds/message.mp3`, `/sounds/leave.mp3`, `/sounds/ring-in.mp3` and `/sounds/ring-out.mp3`, with Ogg alternatives chosen by browser capability. The evidence lane staged the four official MP3s with hashes; the native implementation remains root-owned. The account switch reads `store.sounds` and persists `yapper-sounds=on/off`. DND, channel/server mute levels, current visible focused conversation, duplicate events and sender throttles all affect actual message notification eligibility. The JSON preserves these guards and the original default gain rather than suggesting unconditional playback.
