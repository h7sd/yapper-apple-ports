# Yapper for Mac

A macOS port of Yapper 1.1.0 recovered from the supplied `Yapper-Setup.AppImage`. It uses the recovered desktop shell, unchanged preload bridge, game catalog, and icon. The published port updates the original Electron 38.8.6 runtime to **45.1.0** to address known dependency advisories; it is not byte-identical to the upstream runtime.

The original app loads **https://www.yapper.website**. This port loads the same live interface and service; it requires an internet connection and your existing Yapper account. Website content and server behavior remain controlled by Yapper.

## Install

Requires macOS 13 or newer. The updated Electron runtime raises the minimum from the initial port's macOS 12 requirement.

1. Extract the ZIP for your Mac: `arm64` for Apple Silicon, `x64` for Intel.
2. Drag `Yapper.app` into Applications.
3. Open Yapper and sign in.

The app is signed locally with an ad-hoc signature and is not Apple notarized. If macOS blocks it, review the app in System Settings > Privacy & Security and use Open Anyway if offered.

## Mac integration

- Native application, Edit, View, Window, and Help menus, with Command-key editing and zoom shortcuts.
- Menu bar icon, close-to-background, Dock reopening, unread badges, native notifications, and `yapper://` invite links.
- Original desktop settings, screen/window picker, activity bridge, idle reporting, and push-to-talk/mute/deafen bridge.
- Microphone and camera permission prompts occur when requested by the site. Screen sharing requires Screen & System Audio Recording permission. Global hotkeys require Accessibility permission; in-app keys continue to work without it.
- Help > Mac Permissions opens the relevant macOS settings pane.
- Open at Login appears in the menu bar menu. Its saved Start Minimized preference is applied to login launches. Login behavior needs a real login cycle to verify and may depend on macOS approval of the locally signed app.

## Differences and limits

- The supplied release has no signed Mac update channel. Automatic binary updates are disabled; the live website continues to update normally. Yapper downloads opens the official download page.
- Screen/window **video** sharing is wired through the original picker. System-audio loopback remains disabled on Mac in this port. Microphone audio is separate.
- Native permissions, actual calls, notification delivery, and global hotkeys after consent need user verification. Automated checks avoid opening the microphone/camera or recording the screen.
- Mac activity detection uses running GUI applications, with conservative executable aliases. An application being present does not prove that its game window is visible. Generic Java/Minecraft processes and Windows games running through compatibility layers may not be detected automatically; custom games remain available.
- The Intel package is built and statically checked on Apple Silicon. It has not been run on an Intel Mac.

## Build from source

Requires macOS 13 or newer and Node.js 24 or newer. From this folder:

```sh
npm ci
npm test
npm run build:mac:arm64
npm run build:mac:x64
```

`npm run build:mac:all` builds both. The `.app` folders and ZIP archives are written to the repository's `dist/` directory. Build scripts generate the ICNS icon from the original PNG, prune development dependencies and foreign native binaries, package ASAR, sign all executables locally, and verify the resulting bundle.

From the repository root, `node scripts/verify-macos.mjs` checks the source invariants. After a build, `node scripts/verify-macos.mjs --arch=arm64` (or `x64`) additionally extracts the ZIP into temporary staging, compares the four application-owned source files with its ASAR, checks the native module architecture, and verifies the nested signatures. These checks do not launch the app or use camera, microphone, screen recording, Accessibility, or login items. `npm test` includes a read-only query for running GUI applications on macOS.

The GitHub Actions workflow builds both architectures and uploads CI artifacts and checksums. It has read-only repository permissions and does not publish releases, notarize, or use signing credentials. Read [the security review](../docs/SECURITY-REVIEW.md) before granting native permissions; a passing workflow does not establish that the app or its live service is harmless.

## Provenance

`upstream/` preserves the original application-owned JavaScript and manifest, including Yapper's original author and website metadata. `build/icon.png` is the original icon. `provenance.json` records the AppImage SHA-256, recovered runtime version, source hashes, and REA Evidence ID. [The public evidence summary](evidence/README.md) explains the analysis scope. Raw local investigation logs are excluded because they contain workstation paths.

The REA result covers the selected application-owned source files. It does not establish execution of the Linux app, analyze the remote website, or prove every feature works on macOS.
