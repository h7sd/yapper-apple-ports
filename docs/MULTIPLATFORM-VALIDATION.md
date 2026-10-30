# Linux, Windows and Android validation

The community builds retain Yapper's live UI and the same six optional Yapinplugger feature adaptations. They do not make the remaining 161 public Vencord plugins compatible. This records local build and inspection results on 2026-10-30; it is not a malware certification or a test of the remote service.

## Desktop results

- All **28 shared desktop regression tests passed**, without skips. The platform cases cover native IPC origin/main-frame denial, inaccessible updates, plugin/menu access, absent tray icons, persisted zoom, Windows login settings, Wayland capability limits and rejected Linux autostart requests.
- All **18 source checks passed** in `node scripts/verify-macos.mjs`, including preserved upstream hashes, pinned runtime dependencies, sandbox/context isolation and the unchanged native bridge method set.
- All **55 package checks passed** against the final Linux and Windows builds. Checks inspect actual x64 PE/ELF headers and native modules, compare ASAR source bytes, invoke both extension checksum loaders, extract the ZIP/tar/AppImage filesystems, inspect Windows branding and installer content, and reject permissive package file modes.
- Complete and production-only npm advisory inventories both report zero known advisories. The complete inventory includes Electron; a production-only result would exclude this shipped runtime because it is declared as a build dependency.

Source and resource hashes, archive sizes, SHA-256 values and exact assertions are in [Linux build](../desktop/reports/build-linux-x64.json), [Windows build](../desktop/reports/build-win32-x64.json), [package verification](../desktop/reports/verification.json), [complete audit](../desktop/reports/npm-audit-all.json) and [production audit](../desktop/reports/npm-audit-production.json).

## Android results

The Android build compiles the native Java shell with checksum-pinned Maven/AOSP tools and bundles the exact shared addon/appearance assets with their license notices. The signed APK is checked for its application ID, minimum/target API levels, disabled debugging, absence of private signing keys and test fixtures, resource/DEX presence, ZIP integrity/alignment, and APK v2/v3 signatures. The published certificate fingerprint identifies this local project signing key; it is separate from any official Yapper identity.

All **18 Android policy/bridge tests passed**: seven JVM/JUnit URL-policy tests and eleven Node bridge tests. APK v1/v2/v3 signatures verify with zero warnings, and `debuggable` is false. The build uses AndroidX WebKit 1.18.0. The [Android package report](../android/reports/verification.json) and [policy/bridge test report](../android/reports/tests.json) record exact results. [Android build and signing instructions](../android/README.md) explain how to retain a private signing identity for future updates.

The [combined local record](reports/multiplatform-validation.json) and [release checksums](reports/SHA256SUMS-multiplatform.txt) tie these results to the final five binary packages.

## Execution limits

The new desktop packages were cross-packaged on macOS. No Linux/Windows desktop was launched, and the Windows installer/uninstaller, native media, GPU, notifications and system hooks were not exercised on those target systems. No Android emulator or physical Android device was attached; Android media/file-picker/notification/keyboard/system-bar behavior remains unverified on a device. Policy tests and package signatures are distinct from those runtime checks.

The repository includes read-only build/verification workflows, with pinned official action commits. Local success is not a claim of green GitHub-hosted CI; the previously observed account restriction is not bypassed or changed by this work. No account sessions, private chat screenshots, signing keys, passwords or provisioning profiles are published.
