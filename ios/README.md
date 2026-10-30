# Yapper for iOS

Unofficial iPhone/iPad port derived from the official Yapper Linux desktop client. Native Swift/WKWebView loads the same responsive live Yapper interface. The app does not embed Electron and does not include Yapper's server source.

## Build

Requires a Mac with Xcode 27.1 or later for the verified toolchain, plus Node.js to run the JavaScript bridge tests. Deployment target is iOS 17.0.

```sh
node --test tests/native-bridge.test.cjs
scripts/build-ios.sh simulator
scripts/build-ios.sh archive
```

The simulator ZIP runs in Xcode's iOS Simulator. The `ios-unsigned.ipa` is a device build, **not directly installable until signed**. Open `Yapper.xcodeproj`, select your own development team under Signing & Capabilities, and build to your device. No signing keys, profiles, Apple account, or development team are embedded.

To run the tests on an existing simulator:

```sh
SIMULATOR_ID=YOUR_SIMULATOR_UDID scripts/build-ios.sh test
```

By default, derived data and artifacts go into the ignored `.build/` folder. `DERIVED_DATA`, `OUTPUT_DIR`, `ARCHIVE_PATH`, and `RESULT_BUNDLE` can override those paths.

## Behavior

- Original responsive website, persistent WebKit login/session store, native file/photo pickers provided by WebKit, inline video, and normal iOS camera/microphone consent.
- `yapper://invite/code` deep links remain on Yapper's HTTPS origin.
- Third-party top-level links open outside the native-privileged web view. Discord import uses a separate popup with no native bridge and no camera/microphone permission.
- Load failure and process-termination screens offer Retry.
- The original 17-member desktop bridge is preserved as a compatibility API with `platform: 'ios'`; unsupported desktop features return unavailable values.
- Native local notifications and badges require opt-in and iOS consent. Open `yapper://app-settings` to reach native App Settings; the failure screen also has an App Settings button. The Home Screen quick action is provided as an additional entry point.

## Limits

This is not a full desktop-runtime clone. Screen capture/sharing, system-audio capture, global hotkeys, detection of other running apps, login items, and automatic binary updates are unavailable. There is no APNs/background push server or CallKit integration; calls and notifications must not be assumed to keep working after iOS suspends the web session.

The UI and account backend are remotely hosted by Yapper and can change without rebuilding this app. Simulator tests do not validate physical-device microphone/camera quality, background calling, notification delivery, or distribution signing. The unsigned IPA is not an App Store/TestFlight publication.

Email/username login uses the original web form. Google/external OAuth login has not been authenticated in this build; third-party restrictions or separate browser cookie stores may prevent it from returning a signed-in session to the app.

See the repository's provenance, security review, and validation records for the exact scope of testing. No “malware-free” certification is claimed.
