# YapperCord Installer for macOS

A native SwiftUI installer and CLI for **compatible Yapper builds containing the built-in YapperCord 0.1.0 runtime**. Requires macOS 13 or newer. It does not inject code into an arbitrary Electron app or modify a signed app bundle.

Compatibility is limited to the packaged YapperCord 0.1.0 build and its reviewed runtime checksum. This is not a general Vencord installer or plugin fork. Catalog entries that still require a Yapper port do not become working plugins when the runtime is enabled.

The installer has no network downloader, privileged helper, updater, or Discord patching path. A compatible Yapper.app can be included in its Resources or placed beside the installer; otherwise choose an explicit local app in the GUI. A matching version marker and valid code signature establish compatibility and integrity, not publisher identity or harmless behavior. Locally built apps and this installer use ad-hoc signatures and are not Apple notarized.

## Install and enable

1. Open **YapperCord Installer.app**.
2. Choose the compatible source Yapper.app and an installation destination. The default is `~/Applications/Yapper.app`.
3. Quit Yapper, including its background helpers. The installer refuses to change a running source or destination.
4. If replacing an existing Yapper app, explicitly select **Allow replacement after creating a recovery backup**.
5. Click **Install & enable**. Open the installed Yapper separately when ready.

The installer checks the bundle ID, packed ASAR `package.json` marker, nested code signatures, relative bundle links, and the built-in runtime checksum against the reviewed 0.1.0 hash. It copies to staging and validates that copy before moving an existing destination into a same-volume recovery folder. It preserves quarantine metadata and never re-signs, patches, or launches Yapper.

Only `yappercord.json` in the selected Yapper profile is changed. Standard Yapper uses `~/Library/Application Support/Yapper`; this follows its `productName: "Yapper"`. If you launch Yapper with a custom `--user-data-dir`, select that same profile. The contract is a JSON object with `schemaVersion: 1` and `enabled: true` or `false`; existing plugin and unknown keys are preserved. Invalid or future-schema settings are refused rather than overwritten.

**Enable installed app** enables the runtime in an already-compatible app without copying it. **Disable** writes `enabled: false` and keeps plugin settings. Yapper must be closed; its own native menu can toggle the runtime during normal use.

## Restore, uninstall, and interrupted operations

**Restore / uninstall** uses the installation receipt. It restores the previous app when one was backed up, or removes the installer's new copy from its destination when no previous app existed. It disables YapperCord and preserves plugin settings. The removed app remains in the recovery folder, so this operation does not permanently delete it.

Recovery copies live beside the destination under `.YapperCord-Backups/`. Receipts and per-destination operation locks live under `~/Library/Application Support/YapperCord Installer/`. Interrupted installation/restore operations retain a journal; choose Restore again to recover. Stale locks are removed only when their recorded process no longer exists. Do not manually remove receipts while recovering.

If the installed app or backup changed after installation, Restore refuses to overwrite it. Use Disable, retain the copies, and inspect the recovery folder. Recovery may restore an older app version with its original security characteristics; review it before opening. Recovery folders can be removed manually after confirming the desired app and settings are intact.

## CLI

The GUI executable also provides a CLI:

```sh
installer="/path/YapperCord Installer.app/Contents/MacOS/YapperCordInstaller"
"$installer" inspect --app "/path/Yapper.app"
"$installer" install --source "/path/compatible/Yapper.app" --destination "$HOME/Applications/Yapper.app"
"$installer" install --source "/path/compatible/Yapper.app" --destination "$HOME/Applications/Yapper.app" --replace
"$installer" enable --app "$HOME/Applications/Yapper.app"
"$installer" disable --app "$HOME/Applications/Yapper.app"
"$installer" restore --destination "$HOME/Applications/Yapper.app"
```

`--user-data /absolute/profile/folder` can be supplied for a custom Yapper profile. `install` may omit `--source` only when a compatible local app is bundled or adjacent. Commands return JSON on success, exit 2 with an error on failure, and never silently overwrite an existing app. Destinations must be within the current user's home or directly in `/Applications`; no administrator escalation is attempted. User-selected symlink paths and nested app destinations are refused; protected macOS root aliases are handled explicitly.

## Build and test

Requires Xcode with Swift 6.2 or newer and Node.js for the build script. The resulting installer has no Node.js dependency.

```sh
xcrun swift test
node scripts/build-installer.mjs
```

The script runs tests, cross-compiles arm64 and x86_64, creates a universal app, signs it locally, verifies it, and writes the app, ZIP, checksum, and a small report to `installer/dist/`.

Add `--archive-only` to create the ZIP and reports while preserving any existing unpacked installer app, including an open instance.

Run `node scripts/verify-installer.mjs /absolute/path/to/installer-or-setup.zip` to independently extract and verify a finished artifact without opening its GUI or installing anything. See [the validation snapshot](VALIDATION.md) for test scope and remaining limits.

To make a self-contained installer with a locally built compatible client:

```sh
node scripts/build-installer.mjs --yapper-zip=/absolute/path/to/verified-arm64-yapper.zip --client-arch=arm64
node scripts/build-installer.mjs --yapper-zip=/absolute/path/to/verified-x64-yapper.zip --client-arch=x64
# or --yapper-app=/absolute/path/to/compatible/Yapper.app
```

Use only a locally built or independently reviewed source artifact. ZIP selection is a build-time convenience; the shipped installer itself accepts an app bundle and performs no downloads. A bounded native accessibility check confirmed readable GUI fields and actions; the end-to-end GUI workflow remains untested. File-operation tests use temporary fixture apps and profiles; they do not change the user's Yapper installation or settings.

Bundled builds are named `YapperCord-Setup-0.1.0-mac-arm64.zip` and `YapperCord-Setup-0.1.0-mac-x64.zip`. Both contain the universal native installer, with the matching client architecture in its Resources. Each variant is kept separately in `installer/dist/`; the standalone installer ZIP remains available as an option for selecting a source app.
