# Yapinplugger for Android

Unofficial Android port of the official Yapper 1.1.0 Linux AppImage. A native Java Activity and Android System WebView load Yapper's real responsive website and account backend. This is not an official Android release from Yapper and does not include its server source or Electron.

## Install

Use `Yapper-1.1.0-Yapinplugger-0.1.0-android.apk` on **Android 10 or newer**. Allow installation from the app that opens the APK when Android asks. The APK is a normal installable, self-signed sideload package with `debuggable=false`; it is not an unsigned APK and is not a Google Play publication. Its project certificate is independently generated and does not identify a verified publisher. Verify the APK SHA-256 and certificate fingerprint against `reports/verification.json`.

The private distribution key remains in the build owner's ignored local work directory and is reused for updates. Never publish it. An APK built by somebody else with a different certificate cannot update this installation in place. Removing an installed copy to change signing identity deletes its private login/settings store.

Long press the launcher icon and choose **App Settings**, open `yapper://app-settings`, or press Back on the initial app page and choose **App Settings**. Enhanced profiles start enabled; Yapinplugger plugins and local notifications start disabled. Save changes, then open App Settings again to use **Open Plugin Manager** after enabling plugins. Six independent adaptations are available; 161 public Vencord plugins still require a Yapper-specific port. The desktop installer and upstream Discord runtime do not run on Android.

## Build and test

Requires JDK 17+, Python 3.9+, Node.js for bridge tests, and `curl`. Build hosts: macOS, Linux, Windows. AAPT2's official macOS binary needs Rosetta when used on Apple Silicon. No Gradle installation, proprietary Android SDK installer, automatic license acceptance or Google account is required. Dependencies are public open-source Maven artifacts with exact hashes in `dependencies.lock.json`.

```sh
python3 android/scripts/build.py
python3 android/scripts/test.py
```

After intentionally rebuilding the shared extension bundle or appearance source, run `python3 android/scripts/sync-assets.py` before rebuilding Android. The build rejects mismatched copies.

The default work directory is `.build/android`; the resulting APK is in `.build/android/artifacts/`. Override locations when needed:

```sh
python3 android/scripts/build.py --work-dir /private/build/yapinplugger-android --output-dir dist
python3 android/scripts/test.py --work-dir /private/build/yapinplugger-android
```

Set `JAVA_HOME` to your JDK if it is not automatically found. For an existing distribution identity, set both `YAPINPLUGGER_ANDROID_KEYSTORE` and `YAPINPLUGGER_ANDROID_PASSWORD_FILE` to private local files. The keystore must be PKCS12 and use alias `distribution`. The script refuses to replace a partially missing identity. The build's default private key/password live under `<work-dir>/signing/`, protected with local owner permissions. Back up those files securely to retain the ability to publish compatible updates. CI creates an unrelated ephemeral certificate; it must not replace the publisher's distribution key.

Build steps are explicit: verify pinned downloads; link manifest/resources with AAPT2 and an Apache-licensed AOSP API-35 framework jar; compile Java; create release DEX with D8; sign with official Android `apksig`; independently verify v1/v2/v3 signatures, manifest, ZIP CRC/alignment and every bundled asset. The framework jar, annotation/Kotlin compiler libraries and test libraries are never packaged. See `BUILD-DEPENDENCIES.md`.

## Behavior and security boundary

- The original live Yapper UI fills the window. Transparent status/navigation bars show the page background. Native system-bar/cutout measurements become CSS variables; one app container owns control padding. The viewport adapter removes the already present duplicate classic-layout header padding. On Android 11+, IME insets resize the WebView once; Android 10 uses system `adjustResize`.
- The original 17-member `window.yapperDesktop` API remains, with `platform: 'android'` and truthful unavailable values for desktop-only functions. A separate `window.yapperAndroid` exposes lifecycle and native settings.
- Native messaging and document-start scripts use AndroidX WebKit's exact four HTTPS origin rules and independent native origin/main-frame checks. No `addJavascriptInterface` is exposed to arbitrary embedded frames. An obsolete System WebView lacking these features fails closed and asks for an update.
- Top-level third-party links open outside the privileged view. Discord import uses a separate popup without native messaging or scripts; its media requests are denied. File/content/javascript/intent top-level navigation, mixed content and invalid TLS are blocked. Third-party cookies are disabled.
- Camera/microphone requests require a trusted Yapper origin, a native confirmation and Android device permission. Pending consent is tied to the requesting document and request identity; navigation/cancellation invalidates it. No background service is installed.
- Uploads use Android's system document picker and only return user-selected `content:` URIs to the same requesting document. There is no broad storage permission. Downloads offer the external browser; in-app cookies are not transferred. Browser downloads that require the app's login and blob downloads may need to be opened directly on the website.
- Local notifications require opt-in and Android consent. They can originate while the web session runs; this build has no background push server or guaranteed background calling. Android launcher badge support is reported unavailable.
- The app has no process enumeration, global hotkeys, screen/system-audio capture, location permission, contacts access, automatic binary updater or accessibility service. Login and plugin settings use the app's private persistent WebView/preferences store; Android backup is disabled.

## Verification limits

`reports/tests.json` records seven executed JVM URL-policy tests and eleven JavaScript bridge tests. `reports/verification.json` records package, source-asset and signing verification. No Android emulator or physical Android device was attached to the build host. Camera/microphone quality, file-picker integration, notifications, keyboard behavior, edge-to-edge rendering, external OAuth and Android installation/launch therefore still require device verification. These checks are not a malware-free certification.

Yapper's hosted UI/backend can change independently. Keep Android System WebView or Chrome updated. Native dependency notices and the full Apache-2.0, GPL and appearance licenses are bundled in the APK's assets and corresponding source.
