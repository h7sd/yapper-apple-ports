# Official Windows client: evidence and native reconstruction boundary

Checked 31 October 2026. The requested reference is the **official Windows Yapper installer**, not this repository's rebuilt Windows package. All inspection was static: the installer, Windows executable, native addons, package bootstrap and website scripts were never executed. No account, credentials, private browser storage, conversations or CAPTCHA responses were inspected.

## Artifact identity

The official [download page](https://yapin.gg/download) links to `/download/windows`. That route serves the Windows installer. The published desktop client also constructs the same [Windows download](https://files.yapper.website/desktop/Yapper-Setup.exe) in its screen-sharing upgrade action.

- Package name: `yapper-desktop`; product: `Yapper`; packaged version: **1.1.0**.
- Windows installer: `Yapper-Setup.exe`, **93,541,590 bytes**.
- Installer SHA-256: `690952ab0e31c764fda01b50e9271960fb10a04bbcd7ce7f862b47a5141b8f3a`.
- Ordinary 7-Zip inventory identifies an NSIS Unicode installer containing `$PLUGINSDIR/app-64.7z`; this payload contains `Yapper.exe`, `resources/app.asar` and `resources/app-update.yml`.
- ASAR SHA-256: `840db2c8834583a18ed15774dd1976ad9d38029aa4cce9edbe1877a5adb14e20`.
- Updater configuration: generic provider, `https://www.yapper.website/download`, cache name `yapper-desktop-updater`.

REA PE-resource Evidence: `ev_18de0bf63c8dc1b8580930b00b976d291e23da0cd0a0650a073647c7c6ab3899`.

REA JavaScript/ASAR Evidence: `ev_ab58a3ba831c982b70b9b615e6212e166b1b6f9d2deb6d5acd3fc5aef72ad54c`.

The complete canonical Evidence and installer/extraction provenance are retained locally. They are distinct from the sanitized findings here. The active session had no REA MCP tools; the pinned `rea-agents@6.5.0` CLI supplied the actual Evidence. Its read-only doctor reported Codex registration drift. No client configuration or analysis engine was installed or changed; this static CLI route did not require a native disassembler.

## What is actually packaged

The ASAR contains 371 file/directory entries. Its application-owned files are `package.json`, `main.js`, `preload.js`, `games.js` and `build/icon.png`; other entries are dependencies. The selected REA analysis read the four source/manifest files, parsed all three JavaScript files with **zero parse failures**, and left **256 inventoried dependency files outside semantic analysis scope**. That selection covers the observed application-owned Electron logic, not every dependency's implementation.

Source SHA-256 values preserve the Windows bytes, including CRLF:

```text
905e371a0826ccae284a2c59fd55109b5776087b7e3c222675996c0ee7ddde92  package.json
1fe870332839656d1ecb3e042dc427c3f0ee4da320fb369a128f57ff4ff6d3f3  main.js
a6abd09fab6f28053402db33a3822c2e3f19bb396728f275b50fb8a5ae0a7487  preload.js
9a874362dd241e646a4e9191323a6fe40dd9fea398ace877ceafc0821cc97894  games.js
```

Each of those four files equals its previously recovered **official Linux 1.1.0** counterpart after CRLF-to-LF normalization. This comparison concerns those exact source files; it does not equate the Windows and Linux executables, native addons or runtime behavior.

The important reconstruction observation is `main.js:11`, `SITE = 'https://www.yapper.website'`, followed by `createWindow()` calling `loadSite(SITE)` at line 266. **The Windows package loads the live website; it does not bundle the chat application's React interface or all server APIs.** Its package version therefore cannot freeze the version of every remotely served chat feature. Reconstructing native feature parity also requires the current website's entrypoint and lazy chunks, with their separate digests and coverage. See the [observed API contract](API-CONTRACT.md) and the evolving native parity inventory for that separate evidence.

## Complete observed desktop bridge surface

REA found one `BrowserWindow`, one preload entrypoint, one `window.yapperDesktop` API, **17 exposed members**, **17 literal IPC channels**, 12 main-process handlers and 12 uniquely paired renderer transmissions. These are syntax/relationship observations; they do not prove execution, permissions or successful service behavior.

All 17 preload members are accounted for below, with line references to the exact recovered Windows `preload.js`:

1. `version` (line 23): synchronous `yapper:version` request; main returns the packaged version.
2. `platform` (24): Electron's process platform identifier.
3. `setBadge(count)` (26): `yapper:badge`; unread overlay icon and taskbar attention. The preload draws the numeric PNG.
4. `notify({title,body,url})` (28): `yapper:notify`; native notification that opens an in-app service path when clicked.
5. `onActivity(callback)` (30): listens for `yapper:activity` and requests its current state using `yapper:activity:ask`; reports an observed game name and start timestamp.
6. `screenPicker` (33): desktop picker capability flag, false for the declared Linux Wayland case.
7. `screenSources()` (35): `yapper:screen-sources`; lists whole screens and windows, thumbnails and icons, filtering the app's own window.
8. `pickScreenSource(id)` (37): `yapper:screen-pick`; selects one source for the next `getDisplayMedia` call, with a 30-second lifetime.
9. `onUpdateReady(callback)` (39): listens for `yapper:update-ready` and asks using `yapper:update-ask`.
10. `installUpdate()` (41): `yapper:update-install`; asks Electron's updater to quit/install/restart a ready update.
11. `setHotkeys({ptt,mute,deafen})` (46): `yapper:hotkeys`; installs selected global keyboard/mouse bindings and returns which bindings were available.
12. `onPtt(callback)` (48): `yapper:ptt`; push-to-talk pressed/released events while another desktop window has focus.
13. `onHotkey(callback)` (50): `yapper:hotkey`; mute/deafen toggle actions.
14. `onSystemIdle(callback)` (52): `yapper:idle`; whole-computer idle seconds, sent every 15 seconds.
15. `getSettings()` (54): `yapper:settings-get`; desktop preferences plus login-item/platform/current hardware-acceleration information.
16. `setSettings(patch)` (55): `yapper:settings-set`; close-to-tray, hardware acceleration, activity detection, custom games, login/start-minimized settings.
17. `listPrograms()` (57): `yapper:programs`; running windowed programs for the custom-game picker.

Additional application-owned host behavior is visible outside that bridge: single-instance handling; `yapper://` deep links; tray open/quit/update/login-item actions; close-to-tray; stored zoom and keyboard/mouse zoom controls; fullscreen exit; spellcheck/cut/copy/paste menus; origin-bounded navigation/external-link handling; microphone/camera/notification/display/clipboard permissions; loading/crash/hang retry screens; updater scheduling; and process polling against the game/tool catalog. `main.js` contains custom `ownUrl`/`fromYapper` checks. REA's generic sender-validation counter does not recognize those custom functions, so a zero generic counter must not be read as their absence or as a security verdict.

## Consequences for the native iOS implementation

The shared user-facing chat features must be reconstructed from the website's observed service contracts, not implemented as an embedded web chat. The native bridge functions above are desktop integration dependencies, not additional hidden message/history endpoints.

Some require platform-specific equivalents rather than literal copies: iOS notification/badge and lifecycle handling; native keyboard/text editing and Dynamic Type; ReplayKit-based sharing; supported call audio/background behavior; and iOS-managed installation/update/signing. The Windows implementation's PowerShell/tasklist process discovery, `uiohook-napi` global input hooks, system tray, start-with-Windows setting, arbitrary desktop-window picker and silent Electron installer have no portable Swift implementation simply by copying their source. They must be mapped to supported iOS capabilities or explicitly identified as platform-specific gaps. Apple's [User Notifications](https://developer.apple.com/documentation/usernotifications), [ReplayKit](https://developer.apple.com/documentation/replaykit) and [Background Tasks](https://developer.apple.com/documentation/backgroundtasks) are the relevant platform integration starting points; linking them is not a claim that those integrations have already been implemented or verified.

## Coverage and remaining unknowns

- **Answered, static:** official Windows artifact identity, package version and hashes; complete application-owned entrypoint/bridge inventory; remote-site loading boundary; equality of the four normalized shared Linux/Windows source files.
- **Separate evidence required:** complete current remotely served frontend/lazy-module inventory, all conditional/flagged service contracts and operator-side availability.
- **Unverified:** Windows execution; microphone, video, sharing and notifications on a physical device; real-account CAPTCHA completion; service authorization/results for any native mutation; operator push/call integration; end-to-end feature parity.
- ASAR inventory identity covers the entire selected artifact. Relationships through unselected dependencies, dynamic selections and native bindings remain unknown. All source-derived behavior above is an observation/inference from inert code, not a runtime trace or malware-free certification.

This report establishes the requested Windows reference. It must not be used as proof that the existing native preview already implements every web feature.
