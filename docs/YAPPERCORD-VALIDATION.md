# Yapinplugger validation and remaining work

This records bounded local checks for the experimental Yapinplugger integration. It is not a malware-free certification, universal plugin compatibility report, or verification of Yapper's backend.

## Source and feature coverage

The Vencord inventory is pinned to commit `644434941b515a2626a2161e219653cb36e723e7`: 167 public plugins, 14 API modules and 5 core modules. Each entry records its exact source path/hash, target, imports and static porting blockers. The inventory is the union of shipped upstream entry points, including platform-specific entries, rather than a claim that one upstream build contains all platform targets.

Six independent feature adaptations are implemented. The other 161 public upstream plugins remain unported. No test below claims to execute the upstream plugins. Making all of them usable remains unfinished; Discord stores, webpack patches, native modules and service-specific behaviors need separate Yapper implementations and, for some features, frontend/server support unavailable in this client repository.

## Local results

- **14 Node tests passed, none skipped**, when explicitly pointed at the pinned Vencord checkout. This includes independent Git-tree inventory coverage, exact catalog regeneration, safe literal parsing, URL cleaning, settings validation, CSS validation and nonrecursive replacements. Without `VENCORD_SOURCE`, the external-checkout test intentionally skips; the other 13 run from this repository alone.
- **20 Mac regression tests passed**, including the existing permission/bridge tests and new opt-in/configuration/bundle-integrity checks.
- **14 Electron checks passed** in the real packaged Apple Silicon app. Live anonymous Yapper login and the manager were checked; semantic draft transformations and image zoom used a synthetic, explicitly routed HTML fixture. Keyboard focus survives toggling, disabled effects are removed, retained APIs cannot restart them, iframe execution is rejected, and native disabling reloads without the extension. [Machine-readable results](reports/yappercord-live-checks.json).
- Both Mac package architectures were rebuilt and inspected with the repository verifier. Their final package checksums/signature results are recorded alongside the downloadable artifacts.
- **Four additional native Mac appearance checks passed** for default-on initialization, the unchanged 17-member bridge, forwarding the original fixture profile action, and disabling/re-enabling independently from Yapinplugger. [Results](reports/appearance-native-macos.json).
- **20 source/package checks per Mac architecture passed** in the final appearance-enabled builds. [Apple Silicon](reports/yappercord-macos-arm64.json), [Intel](reports/yappercord-macos-x64.json).
- **45 iOS executions across 16 test functions passed** on the baseline, with no failures, skips or recorded runtime warnings, on a dedicated clean iPhone 17 Pro simulator running iOS 26.4.1. After the final header-inset correction, the expanded fullscreen test passed again for both original and new-look layouts (1 test, 0 failures; 10.949 seconds). Both unsigned Release artifacts embed the verified script/license bytes. The WebView covers the full display while controls respect nonzero safe areas exactly once; both edge bands matched the page theme in all sampled pixels before and after a red-to-teal change. [Red fixture](images/yapinplugger-ios-fullscreen-red-fixture.png), [teal fixture](images/yapinplugger-ios-fullscreen-teal-fixture.png). [Report](reports/yappercord-ios.json), [iOS hotfix checksums](reports/SHA256SUMS-ios-fullscreen.txt).
- **28 installer Swift test functions passed**, plus fresh-extraction checks of both self-contained setup ZIPs: universal installer binary, matching client architecture, nested signatures and exact Cord/appearance bytes. [Apple Silicon](reports/yappercord-setup-arm64.json), [Intel](reports/yappercord-setup-x64.json). The installer defaults to the bundled reviewed client; pre-rename receipts and selected interrupted operations have regression coverage. Compatible sources and older destinations with Finder metadata are checked on isolated validation copies. Only FinderInfo/resource-fork attributes are removed from the installer’s own staging copy, which must then pass full strict signature verification directly; original apps, quarantine and other attributes are preserved. Changed signed content remains rejected. A native harness also installed and restored the actual Finder-metadata-affected bundled Electron client under an isolated disposable home/profile; the installed app passed strict signatures and the original source and profile sentinels were preserved. [Actual-client smoke](reports/yapinplugger-installer-actual-client.json). The GUI smoke is bounded; full interactive installation was not automated. See [installer limits](../installer/VALIDATION.md).

The UI reviewer inspected desktop and narrow-width manager captures and requested one keyboard-focus correction, which was implemented and verified. The profile-layout adapter has its own fixture coverage and source evidence under [appearance](../appearance/README.md).

## Reproduce

```sh
node extensions/yappercord/build.mjs --check
node appearance/build.mjs --check
node --test extensions/yappercord/tests/*.cjs extensions/yappercord/tests/*.mjs
npm test --prefix macos
node scripts/verify-macos.mjs --arch=arm64
node scripts/verify-macos.mjs --arch=x64
```

To include independent upstream coverage, set `VENCORD_SOURCE` to a local checkout of the pinned upstream commit before the Node test command. The complete upstream source is obtained from the upstream repository; it is not executed by the tests.

The optional live/fixture Electron runner is `extensions/yappercord/verify-electron.cjs`. Run it with Node and `PLAYWRIGHT_MODULE` set to an existing Playwright module path; Playwright is not an application dependency. It launches the packaged Apple Silicon app with a new temporary user-data directory and writes reports/captures under `dist/`. It never needs an account login.

## Limits

Authenticated channels, sending messages, actual calls, arbitrary rich editors and physical-iPhone picture-in-picture were not exercised. Synthetic DOM fixtures establish the adapter's behavior for the inspected structures, not compatibility with every future Yapper frontend. No user account/session export, private screenshots, signing profiles or keys are included.

The previously configured GitHub-hosted workflows failed to start because of an account-level restriction. Local success is not green hosted CI. Dependency advisory checks are separate from code review and cannot certify the app, the remote service or its publisher.
