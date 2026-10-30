# Yapinplugger 0.1.0 (experimental)

An **independent Yapper extension**, based on a source study of Vencord. It is not Vencord running on Yapper, and it does **not** make every Discord plugin work. Neither Yapper nor Vencord endorses this project.

The full pinned upstream inventory contains **167 public plugins, 14 API modules and 5 core modules**. All 186 source entries are searchable in the manager and linked to their immutable upstream files. Inventory coverage is not compatibility coverage. Optional third-party `userplugins` are outside this inventory.

## What works now

Six separately implemented, limited feature adaptations are available. All start disabled:

- **CharacterCounter** — counts characters in semantic Yapper message fields. Only shows a limit when the actual field supplies one.
- **ClearURLs** — explicitly cleans common tracking query parameters in a textarea draft or text workbench. Does not implement Vencord's full provider rules or intercept message sending. Review signed or otherwise sensitive links before sending.
- **ImageZoom** — Shift-click a loaded large image on Mac, or use the manager's image gallery on iOS. Does not retrieve message history.
- **PictureInPicture** — requests the system's video feature when supported. Video, browser and OS restrictions still apply. A successful picture-in-picture session has not been verified on a physical iPhone.
- **NoF1** — intercepts F1 while this page has focus; no global keyboard hook.
- **TextReplace** — manually applies saved literal replacement rules. Does not intercept messages or run regular expressions.

Quick CSS, JSON settings import/export, search, on/off controls and cleanup on disable are also implemented. Rich-text editors with unknown framework APIs use the explicit text workbench rather than rewriting editor internals. No action sends a message automatically.

**The other 161 public upstream plugins remain unported.** Entries such as ShowHiddenChannels, FakeNitro, SpotifyControls and MessageLogger depend on Discord-specific stores, patches, services or product behavior. A UI catalog cannot provide those APIs. Some features would require Yapper-specific frontend integration or server support. See [UPSTREAM.md](UPSTREAM.md) and each catalog entry's static dependency observations. No unsupported entry has an enable switch, and no API stubs claim success.

The public name is **Yapinplugger**. Internal `yappercord` directories, storage/configuration keys and the legacy `window.YapperCord` API alias are retained so preview users keep their settings. `window.Yapinplugger` is the current API; both names refer to the same object and are removed on disable.

## Enable on Mac

Use a Yapinplugger-compatible build from this repository. In the native menu choose **Yapinplugger → Enable Yapinplugger**, then **Open Plugin Manager** (Command–Shift–P). Disabling removes active effects and reloads the page. The original 17-member `yapperDesktop` bridge is unchanged.

The optional [native installer](../../installer/README.md) installs a compatible signed app copy and enables the bundled extension. It does not patch Discord, modify the supplied Linux AppImage, bypass code signatures, or download arbitrary plugin code. Older Apple port builds without the Yapinplugger integration must be upgraded first.

The native enable flag is `yappercord.json` (`{"schemaVersion":1,"enabled":true}`) in the client's user data directory. On Mac the default is `~/Library/Application Support/Yapper`. The script itself is bundled inside the signed app; it is never loaded from that directory. Local user settings are per website origin, under `yappercord.settings.v1`. Changing from a yapper.website origin to yapin.gg requires importing the settings on the new origin.

## Enable on iOS

In native app settings enable **Yapinplugger**, then open the plugin manager. The initial state is off. Only the bundled script is installed into trusted main-frame Yapper pages. Disabling removes it and reloads the page. The Mac installer cannot install plugins into an iOS app; install your own signed build of the integrated iOS app instead. See [iOS integration](../../docs/IOS-YAPPERCORD.md).

## Build and inspect

```sh
node extensions/yappercord/build.mjs
node ios/scripts/sync-yappercord.mjs
node extensions/yappercord/build.mjs --check
node --test extensions/yappercord/tests/*.cjs extensions/yappercord/tests/*.mjs
npm test --prefix macos
npm run build:mac:all --prefix macos
```

The iOS sync script name and invocation are documented in the iOS integration guide. `build.mjs --check` verifies that both platform copies equal the runtime plus pinned catalog. `bundle.sha256` records the bundle's hash. This is an integrity check, not a trusted publisher identity or independent security certification.

To regenerate the inventory, use the explicit upstream source checkout and command in [UPSTREAM.md](UPSTREAM.md). The generator reads plugin files as text; it never imports or executes them. The runtime contains neither a TypeScript compiler nor a Discord webpack shim.

## Review boundaries

The extension has the same DOM access as the website; it is not an isolation boundary from that website. It can read the focused draft for the selected feature. It does not collect drafts, message history, credentials or tokens, or send telemetry. Export includes only switches, CSS and replacement rules; those rules may contain personal text you typed yourself.

No remote JavaScript loader, filesystem bridge, shell command API, Discord token access or automatic updater is added. Direct CSS network loads, imports, escapes and comments are rejected by the deliberately limited Quick CSS validator. The native Electron sandbox, context isolation and existing media permissions remain enabled. The manager loads only on the four exact HTTPS Yapper/Yapin app hosts, on port 443, without URL credentials, and in the main frame.

Validation distinguishes real native/live-login checks from synthetic DOM feature fixtures. Authenticated Yapper channels, calls, rich-text editors and physical-device picture-in-picture have not been verified. The live service may change and break semantic selectors. See [validation](../../docs/YAPPERCORD-VALIDATION.md) for actual results and remaining work.

The extension code and inventory are offered under GPL-3.0-or-later; see [license](LICENSE.Vencord) and [upstream notices](UPSTREAM.md). This statement does not relicense recovered Yapper code, branding, or other dependencies.
