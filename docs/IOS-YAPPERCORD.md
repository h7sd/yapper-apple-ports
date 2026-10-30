# YapperCord on iOS

The iOS client can load the bundled YapperCord runtime as an optional local extension. It is **off by default**. This is a Yapper adaptation of selected plugin ideas; the desktop Vencord installer and unmodified Discord/Vencord plugins cannot run inside this iOS app.

## Enable or disable

1. Open `yapper://app-settings` in the installed app to show App Settings.
2. Turn on **Enable YapperCord**. The choice is saved on this device and Yapper reloads.
3. Once loading finishes, select **Open Plugin Manager** to configure the available plugins and local CSS.

Turning YapperCord off calls the runtime's cleanup function, removes its document script, and reloads Yapper. The original desktop compatibility bridge remains available with its original 17 members. The native preference only controls whether the extension runtime is loaded; individual plugin choices are managed by YapperCord.

## iOS boundaries

- The extension runs in the main document only, at document end, on the trusted Yapper website HTTPS host allowlist. External hosts, embedded frames, URL credentials, and nonstandard ports are rejected.
- The extension adds no native message handlers, file access, shell execution, or native bridge methods. Its features operate through the web page's DOM and supported browser APIs.
- Keyboard, picture-in-picture, and image interactions depend on the iOS browser APIs and available input devices. No unsupported desktop capability is advertised as a native iOS feature.
- This integration includes no remote plugin loader. Updating bundled code requires rebuilding the app.
- This remains an unsigned iOS build. Sign it with your own Apple development or distribution configuration before installing it on a physical device.

## Sync and build

From the repository root, build the shared runtime and copy the validated bundle into the iOS resource directory:

```sh
node extensions/yappercord/build.mjs
node ios/scripts/sync-yappercord.mjs
```

The sync script parses the bundle before copying it. Xcode embeds `ios/Yapper/resources/YapperCord.js` and the full GPL-3.0 license `LICENSE.Vencord`; the iOS app adds its own origin/frame guard around that resource.

Build the simulator package or unsigned device archive:

```sh
ios/scripts/build-ios.sh simulator
ios/scripts/build-ios.sh archive
```

These commands produce separate artifacts named `Yapper-1.1.0-YapperCord-0.1.0-iOS-Simulator.zip` and `Yapper-1.1.0-YapperCord-0.1.0-ios-unsigned.ipa`. They do not overwrite the original 1.1.0 artifacts.

Run the iOS suite against an available simulator:

```sh
SIMULATOR_ID="<your simulator UDID>" ios/scripts/build-ios.sh test
```

The extension tests cover the default-off preference, the JavaScript origin/frame boundary in WebKit, an actual external document, same-origin iframe isolation, real runtime enable/disable, and preservation of the 17-member desktop bridge. Existing origin-policy tests remain in the suite. Login and manager UI checks use a DEBUG-only ephemeral session, so testing neither uses nor clears the owner's saved website login. Authenticated plugin actions and physical-device media behavior require separate account/device testing.

## Enhanced profile layout

The local profile/navigation appearance adapter is independent of YapperCord. It is enabled by default and reuses the profile information and controls already supplied by Yapper. **App Settings → Enhanced profile layout** can restore the original layout. Changing either native switch cleans up that feature and reloads the page without changing the other switch.

The appearance adapter adds no account data, network requests, or native bridge methods. It uses the same guarded, main-frame document-end injection policy. Its source is `appearance/appearance.js`; copy it into the iOS app before building:

```sh
node ios/scripts/sync-appearance.mjs
```

The independent appearance adapter uses the MIT license. Its complete notice is embedded as `LICENSE.Appearance`, alongside YapperCord's GPL notice.
