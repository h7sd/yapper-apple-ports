# Yapper clients with Yapinplugger

**Experimental Yapinplugger extension:** [plugin manager, full upstream inventory and current compatibility](extensions/yappercord/README.md). Six limited Yapper feature adaptations are implemented; the remaining 161 public Vencord plugins are **not** compatible yet. [Native installer source](installer/README.md). This does not claim all Discord plugins work on Yapper.

**Fullscreen on iOS:** Yapper’s theme fills the display behind the status bar and home indicator; controls respect the device safe areas. The [iOS fullscreen hotfix](https://github.com/h7sd/yapper-apple-ports/releases/tag/v1.1.0-apple.3) also removes duplicated mobile header/navigation insets. [Viewport verification](docs/IOS-YAPPERCORD.md#fullscreen-viewport).

**Profile layout:** [reversible account strip, profile presentation and compact mobile navigation](appearance/README.md), using the original Yapper components, theme, artwork and actions. This is a local client layout enhancement; it does not change the hosted Yapper website for other users.

**Unofficial macOS, iOS, Windows, Linux and Android clients based on Yapper's official Linux AppImage.** This project is not affiliated with, endorsed by, or published by Yapper/Yapin’. The upstream names, artwork, and service belong to their respective owners. The repository keeps its original `yapper-apple-ports` address so existing links continue to work.

The supplied Linux client is an Electron shell around the live **[Yapper website](https://www.yapper.website)**. The desktop clients preserve that shell and desktop bridge. iOS uses native Swift/WKWebView; Android uses a native Java/WebView shell. All show the same live Yapper website with the locally bundled Yapinplugger and profile-layout adapters. This repository contains the native client source, upstream shell references, build scripts, tests, and verification records. It does not contain the website's server-side source.

## Downloads

Use [the multiplatform release for Linux, Windows and Android](https://github.com/h7sd/yapper-apple-ports/releases/tag/v1.1.0-multiplatform.1), [v1.1.0-apple.3 for the corrected iOS packages](https://github.com/h7sd/yapper-apple-ports/releases/tag/v1.1.0-apple.3) and [v1.1.0-apple.2 for the unchanged macOS Setup packages](https://github.com/h7sd/yapper-apple-ports/releases/tag/v1.1.0-apple.2). Each release includes its own asset checksums. All versions appear on the **[Releases page](https://github.com/h7sd/yapper-apple-ports/releases)**.

New platform packages:

- **Linux x64:** `Yapinplugger-1.1.0-plugins-0.1.0-linux-x64.AppImage`, plus an extractable `.tar.gz` alternative. The tarball includes a user-local desktop/protocol registration script. [Build and usage](desktop/README.md).
- **Windows x64:** `Yapinplugger-1.1.0-plugins-0.1.0-windows-x64-Setup.exe` installs for the current user; the `.zip` alternative can run after extraction. [Build and usage](desktop/README.md).
- **Android 10+:** `Yapper-1.1.0-Yapinplugger-0.1.0-android.apk` is a signed, directly sideloadable APK. Its local project certificate is separate from Yapper's official identity; the private key is not published. [Build, signing and capabilities](android/README.md).

Apple packages:

- `Yapinplugger-Setup-0.1.0-mac-arm64.zip`: self-contained installer and client for Apple Silicon Mac.
- `Yapinplugger-Setup-0.1.0-mac-x64.zip`: self-contained installer and client for Intel Mac.
- `Yapper-1.1.0-Yapinplugger-0.1.0-iOS-Simulator.zip`: an application for Xcode's iOS Simulator.
- `Yapper-1.1.0-Yapinplugger-0.1.0-ios-unsigned.ipa`: an iPhone/iPad build that **must be signed with your own Apple profile before installation**.
- `Yapinplugger-Installer-0.1.0-mac-universal.zip`: optional standalone installer; requires a compatible source app.
- `SHA256SUMS.txt`: hashes of the published release assets.

Mac builds are ad-hoc signed, not Apple-notarized. The iOS build is not an App Store/TestFlight release. See [macOS build instructions](macos/README.md) and [iOS build instructions](ios/README.md).

The new Windows/Linux clients are cross-packaged and inspected on macOS; native installation, calls and target-desktop execution have not been verified. Windows binaries are not Authenticode-signed. Android verification distinguishes policy/bridge tests and APK signature/manifest inspection from device execution. The same six optional feature adaptations are included; adding platforms does not make the remaining 161 Vencord plugins compatible.

The new platform build passed **28 shared desktop regressions, 18 desktop source checks, 55 desktop package checks and 18 Android policy/bridge tests**. The APK signatures, manifest and bundled resource bytes were verified separately. See [multiplatform results and execution limits](docs/MULTIPLATFORM-VALIDATION.md).

## Provenance: official Linux package, unofficial ports

The starting artifact is `Yapper-Setup.AppImage`, Yapper 1.1.0, 117,342,908 bytes.

```text
SHA-256 e54f1d3f638caeae0302c6e56bbcf5c272a774862aecafd3d4959bb8e5095b12
```

On **2026-10-30**, a fresh download through the [official Linux download endpoint](https://www.yapper.website/download/linux), linked by the [official downloads page](https://www.yapper.website/download), had **exactly the same SHA-256** as the supplied artifact. The Linux binary was extracted for source inspection; it was not executed on macOS. No temporary signed CDN download URLs are stored here.

The original shell, preload API, and game catalog are retained in [`macos/upstream/`](macos/upstream/). The original Electron version was 38.8.6. The published Mac port updates the runtime after a dependency audit; its exact version is pinned in [`macos/package-lock.json`](macos/package-lock.json). See the [provenance record](docs/PROVENANCE.json) and [security review](docs/SECURITY-REVIEW.md).

## Security and transparency

This repository offers **inspectable evidence**, not a blanket “malware-free” or “not a RAT” guarantee. No finite set of tests or scanner results can prove that guarantee. In particular, the remotely loaded Yapper website and its backend can change independently of a client release.

Reviewers can inspect and reproduce:

- Original-versus-port source differences, exact dependency locks, build scripts, and permission boundaries.
- Automated tests for deep-link containment, renderer/native isolation, media-origin checks, denied permissions, native process enumeration, and truthful unsupported iOS features.
- CI source checks, dependency-advisory reports, packaged native-binary architecture checks, code-signature verification, and SHA-256 release checksums.
- The [security review and limitations](docs/SECURITY-REVIEW.md), [iOS review](docs/IOS-REVIEW.md), and [recorded validation](docs/VALIDATION.md).

Apple release baseline results: 20 Mac regression tests, 20 package checks per architecture, 14 Yapinplugger Electron checks, 4 native appearance checks, 14 extension Node tests (with the pinned external checkout), 3 appearance guard tests plus three-viewport fixture checks, 28 installer Swift test functions, 12 original iOS bridge tests, and 45 iOS Swift/UI case executions passed. See the [new validation scope and remaining work](docs/YAPPERCORD-VALIDATION.md). The earlier baseline results are retained as historical reports. The full npm audit reported 0 known advisories on 2026-10-30 after the runtime update. GitHub-hosted jobs did not start because of an account-level restriction; these are local results, not a claim of green hosted CI. Anonymous UI screenshots: [macOS](docs/images/macos-login.png), [iOS](docs/images/ios-login.png).

The source does not add a remote shell/command-execution bridge, credential-export endpoint, or arbitrary native file-reading API. That statement is limited to the inspected client code, not a claim about every dependency, remote page, or future revision.

### Native permissions and data

The Mac client can enumerate running applications for game activity, forward idle state, handle configured global hotkeys, display notifications, and list/capture screens. These capabilities come from the upstream desktop design and are detailed in the security review. Accessibility and screen-recording permissions are sensitive; grant them only after reviewing the code and deciding you need those features.

The iOS app uses WebKit's persistent website store and normal iOS camera/microphone prompts. It does not provide a desktop process list, global keyboard hook, screen-sharing implementation, or background push service. Local notifications require opt-in. Signing credentials, provisioning profiles, browser sessions, account data, and private chat screenshots are excluded from this repository.

## Build and verify

```sh
cd macos
npm ci
npm test
node ../scripts/verify-macos.mjs
npm run build:mac:all
```

For iOS, open `ios/Yapper.xcodeproj` in Xcode, or use `ios/scripts/build-ios.sh`. No Apple team or signing credential is embedded. CI builds do not require repository secrets.

Checksums confirm byte identity with the uploader's assets; they do not certify the uploader's trustworthiness. Prefer reviewing and building the source yourself when assessing an unfamiliar client.

## Attribution and scope

This is a community port, not a new official client. Upstream source and assets retain their original ownership and notices. No blanket license grant is made over Yapper's recovered source, branding, or remote website. Third-party components retain their own licenses; Electron includes its runtime license notices in packaged applications.
