# Yapinplugger for Linux and Windows

These are community builds of the supplied official Yapper 1.1.0 Linux AppImage, with the same live Yapper website, appearance adapter and optional local Yapinplugger extension used by the Apple ports. They are not official Yapper releases. The original AppImage SHA-256 is `e54f1d3f638caeae0302c6e56bbcf5c272a774862aecafd3d4959bb8e5095b12`.

Both platforms package the reviewed source from `../macos` at build time, with Electron **45.1.0** and the correct x64 native hotkey module. There is no separately maintained copy of the main process. Builds use their own **Yapinplugger** application name and profile; they do not patch an installed official client.

## Install and use

- **Windows x64:** run the `windows-x64-Setup.exe` package for a per-user installation with a Start-menu shortcut, `yapper://` registration and an uninstaller. No administrator access is requested. Close a running Yapinplugger before installing an update. The portable ZIP is an alternative: extract the complete folder, then run `Yapinplugger.exe`. Windows packages have no publisher signing certificate; a valid SHA-256 checksum does not identify a trusted publisher.
- **Linux x64:** make the AppImage executable and run it. The tarball is an alternative: extract the complete folder and run `./AppRun` within it. In the extracted folder, `./install-desktop.sh` optionally creates a user-local launcher and registers `yapper://` links. Keep that folder in place afterward. The AppImage also contains the integration script, available after `--appimage-extract`.

Press **Alt** to reveal the window menu if it is hidden. Use **Yapinplugger → Enable Yapinplugger**, then **Open Plugin Manager**, or **Ctrl+Shift+P**. The same controls are also available from the tray menu. Plugin injection is off by default; the appearance layout is on by default and can be disabled from **View → Enhanced Profile Layout**. The manager documents six independent adaptations and **161 unported public plugins**. The full inventory is not a claim that all Vencord plugins work.

The bridge retains window/tray controls, notifications, unread badges, `yapper://` links, selected-screen sharing, idle state, process-based game activity and requested global hotkeys. Windows screen sharing can request system audio for a whole screen. Linux has no system-audio loopback in this bridge. On Wayland, the native screen source is obtained through the PipeWire portal only when sharing is requested; global keyboard hooks and the app's custom source picker are unavailable. Linux close-to-tray starts disabled because some desktop environments do not show tray icons. Linux login autostart is not implemented by this client.

The Chromium sandbox is enabled. Linux needs compatible desktop libraries and an OS policy that supports Electron's sandbox and user namespaces. The launcher does not disable the sandbox or change system security settings. Both packages load the remote Yapper service and need network access to that service.

Automatic executable updates are disabled on all community builds. Download updates from this repository's releases and verify their checksums. Uninstalling the Windows package removes only its installed file manifest and its own registrations; the profile is retained.

## Build

On macOS or Linux with Node.js compatible with the pinned Packager version, install `zip`, `tar`, NSIS `makensis` and squashfs-tools (`mksquashfs`, `unsquashfs`). On macOS, the latter two are available through `brew install makensis squashfs`.

```sh
npm --prefix desktop ci --ignore-scripts
npm --prefix desktop run build:all
npm --prefix desktop run verify
```

`build:linux` and `build:windows` select one target. Verification currently expects both targets to have been built. Artifacts are written to `../dist/`:

- `Yapinplugger-1.1.0-plugins-0.1.0-linux-x64.AppImage`
- `Yapinplugger-1.1.0-plugins-0.1.0-linux-x64.tar.gz`
- `Yapinplugger-1.1.0-plugins-0.1.0-windows-x64.zip`
- `Yapinplugger-1.1.0-plugins-0.1.0-windows-x64-Setup.exe`

The AppImage runtime comes from AppImage/type2-runtime commit `fedfad51acc2860b2916a1eef32ba4a500ff31ef`, release asset `657374641`, and must match SHA-256 `617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46`. The upstream continuous URL can change; a changed digest stops the build and requires an explicit source update. The runtime notice is included as `LICENSE.AppImage-runtime`; its corresponding build source is available at the pinned [type2-runtime commit](https://github.com/AppImage/type2-runtime/tree/fedfad51acc2860b2916a1eef32ba4a500ff31ef). NSIS notices are preserved in `windows/LICENSE.NSIS`. No remote package code is executed by the build's initial npm install scripts. Packager downloads the pinned Electron platform runtime and verifies its upstream checksums.

## Validation and limits

`reports/build-linux-x64.json` and `reports/build-win32-x64.json` list artifact hashes and shared resource hashes. `reports/verification.json` records the actual ELF/PE header checks, native module selection, ASAR source comparisons, successful checksum-loader calls for **both** bundled extensions, archive extraction, AppImage filesystem extraction, preserved sandbox settings and mocked main-process regressions. Runtime and addon license notices are included in the packages.

These artifacts were cross-compiled on macOS. **Linux and Windows desktop execution, microphone/camera calls, real notifications, GPU behavior, OS installers/uninstallers and global hotkeys were not exercised on those target operating systems.** Packaging checks and mocked API tests do not replace those target-device tests. Production dependency audit results are bounded to the recorded audit and do not prove a package is free of malware or every vulnerability.

Implementation references: [Electron Packager options](https://electron.github.io/packager/main/interfaces/Options.html), [Electron display-media permissions](https://www.electronjs.org/docs/latest/api/session#sessetdisplaymediarequesthandlerhandler-opts), [Linux PipeWire capture](https://www.electronjs.org/docs/latest/api/desktop-capturer#linux), [AppImage manual packaging](https://docs.appimage.org/packaging-guide/manual.html), [NSIS scripting reference](https://nsis.sourceforge.io/Docs/Chapter4.html).
