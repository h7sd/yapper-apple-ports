# Enhanced profile layout

`appearance.js` is a reversible layout adapter for the existing Yapper account strip, full profile, and mobile navigation. It takes the reference's arrangement—avatar/status beside account actions, a prominent existing banner/avatar, readable profile sections/tabs, and compact floating navigation—and keeps Yapper's own palette, fonts, user artwork, labels, state, and handlers.

The adapter marks only the actual public component structures: `.app .user-bar`, the modal `.profile-card.pc2`, its `.pc2-frame`, and `.app nav.nl-tabbar`. It does not replace, move, clone, or read out message/profile trees. Existing identity, status, edit, close, mutual-list, and navigation actions continue to run through the original site listeners. Profile editor previews are excluded. The original app controls whether its navigation is visible; a hidden navigation bar is not forced into a chat or modal.

The richer profile uses the user's existing banner/avatar and real profile sections. The existing mutual-friends/mutual-servers tabs receive the reference's horizontal treatment. The source did not establish Board, Wishlist, quests, currency balances, or shop actions for Yapper, so those reference elements are not fabricated. No reference-image artwork or private account content is shipped.

## Native integration

Inject the self-contained file at document end, in the page world, for the main frame. Its independent guard permits only credential-free HTTPS URLs on `yapper.website`, `www.yapper.website`, `yapin.gg`, and `www.yapin.gg`, with the standard HTTPS port. It registers on trusted anonymous pages as well as authenticated pages; the logged-out page simply has zero matching app components.

```js
window.YapperAppearance.version;       // "0.1.0"
window.YapperAppearance.getState();    // counts/active/disposed flags, no account data
window.YapperAppearance.refresh();    // retag recognized current structure
await window.YapperAppearance.openProfile(); // forwards an existing own-profile action
window.YapperAppearance.destroy();    // restore attributes, remove styles/API/observers
```

`openProfile()` opens the original account menu if necessary and clicks its recognized View my profile action. Exact English, German, Spanish, French, and Portuguese labels were observed in the public locale bundles. It resolves false if the account/menu/action is absent, disabled, unrecognized, disposed, or fails to appear promptly. A true result means the original action was clicked; it does not claim a completed server request. It does not call private stores, synthesize a profile, or fetch account data.

`destroy()` removes the global property. A retained reference reports `disposed: true`; its refresh/open methods remain inactive. Mutation observers handle SPA additions, class changes, and removals; detached components are immediately restored and released. Only adapter-owned attributes/style are changed, and prior attribute values are restored. No state is written to localStorage, cookies, native IPC, or a service.

Build the native copies reproducibly:

```sh
node appearance/build.mjs
node appearance/build.mjs --check
```

Outputs are `macos/appearance/bundle.js`, its SHA-256 sidecar, `ios/Yapper/resources/YapperAppearance.js`, and the matching MIT notices in both native resource directories. The native client owns the persisted default-on appearance switch and script removal/reload policy; this file itself is active only when injected.

## Evidence and verification

[PROVENANCE.json](PROVENANCE.json) records 38 public deployment assets, their URLs/byte hashes, exact source byte anchors for the account/profile/navigation structures, and bounded REA evidence. The URLs contain deployment/content-style names, but permanent upstream immutability is not guaranteed. SHA-256 identifies the captured bytes if those URLs later change or disappear.

REA 6.5.0 parsed four selected UI bundles as inert text with zero parse failures. Its evidence ID and selection limitations are recorded; 35 inventoried files remained outside that selected analysis. Additional manual inspection used the captured styles and locale declarations. Static declarations establish an implementation contract to test; they are not a claim that a real account flow was executed.

`fixtures/real-structure.html` reconstructs the observed class/child/action relationships using synthetic content and fixture-only handlers. It contains no private source images, account sessions, chat messages, or downloaded user artwork. `fixture-base.css` supplies observed Yapper tokens and a small authored structural harness; the production adapter inherits the live site's CSS.

```sh
node --test appearance/tests/appearance.test.cjs
PLAYWRIGHT_MODULE=/path/to/installed/playwright node appearance/tests/browser.cjs
```

The headless fixture check covers desktop, tablet, phone, anonymous registration, viewport bounds, nonoverlapping account/navigation strips, preserved nodes/listeners/text/font/color, SPA removal/reinsertion, repeated injection, and destruction. It routes all fixture resources locally and blocks unexpected requests. These checks do not establish authenticated live-site compatibility, every future selector revision, every user theme/decoration, or all physical-device safe-area/keyboard states. Unknown structures remain unchanged for safe fallback.

The newly written adapter, build script, tests, and original fixture-harness code are MIT-licensed under [LICENSE](LICENSE). This grant excludes upstream Yapper source, its observed paint/token values and component identifiers, branding, design, service, and user artwork. Those references retain their existing ownership and are recorded as evidence; this folder does not relicense them or grant rights over the remote application.
