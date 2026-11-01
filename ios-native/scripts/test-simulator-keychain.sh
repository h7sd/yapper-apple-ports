#!/bin/bash
set -euo pipefail

# Dedicated local Simulator probe; never builds or signs the physical-device client.
# SIMULATOR_ID must name an explicitly selected, already booted Simulator.
: "${SIMULATOR_ID:?Set SIMULATOR_ID to the explicitly selected booted Simulator UUID.}"
PROBE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE_NATIVE_DIR="$(cd "$PROBE_SCRIPT_DIR/.." && pwd)"
PROBE_BUNDLE_ID="website.yapper.native.ios.keychain-probe"
PROBE_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yapper-keychain-probe.XXXXXX")"
PROBE_APP="$PROBE_BUILD_DIR/KeychainProbe.app"
PROBE_INSTALLED=false

probe_cleanup() {
    if [ "$PROBE_INSTALLED" = true ]; then
        xcrun simctl terminate "$SIMULATOR_ID" "$PROBE_BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl uninstall "$SIMULATOR_ID" "$PROBE_BUNDLE_ID" >/dev/null 2>&1 || true
    fi
    rm -rf "$PROBE_BUILD_DIR"
}
trap probe_cleanup EXIT

xcrun simctl list devices booted -j > "$PROBE_BUILD_DIR/devices.json"
python3 - "$SIMULATOR_ID" "$PROBE_BUILD_DIR/devices.json" <<'PY'
import json, sys, uuid
target = str(uuid.UUID(sys.argv[1])).upper()
devices = json.load(open(sys.argv[2]))["devices"]
if not any(item["udid"].upper() == target and item["state"] == "Booted" for rows in devices.values() for item in rows):
    raise SystemExit("Selected Simulator must already be booted.")
PY

mkdir -p "$PROBE_APP"
PROBE_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PROBE_ARCH="$(uname -m)"
case "$PROBE_ARCH" in arm64|x86_64) ;; *) exit 2 ;; esac
PROBE_SOURCES=(
    "$PROBE_NATIVE_DIR/YapperNative/Core/SessionVault.swift"
    "$PROBE_NATIVE_DIR/YapperNative/Core/Models.swift"
    "$PROBE_NATIVE_DIR/YapperNative/Core/NativeImageCrop.swift"
    "$PROBE_NATIVE_DIR/tests/KeychainProbe.swift"
)
shasum -a 256 "${PROBE_SOURCES[@]}" > "$PROBE_BUILD_DIR/source-sha256.txt"
python3 - "$PROBE_APP/Info.plist" "$PROBE_BUILD_DIR/probe.entitlements" "$PROBE_BUNDLE_ID" <<'PY'
import plistlib, sys
bundle = sys.argv[3]
info = {"CFBundleIdentifier": bundle, "CFBundleExecutable": "KeychainProbe", "CFBundleName": "KeychainProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1, 2], "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "DTPlatformName": "iphonesimulator", "UILaunchScreen": {}}
entitlements = {"application-identifier": bundle, "keychain-access-groups": [bundle]}
with open(sys.argv[1], "wb") as output: plistlib.dump(info, output)
with open(sys.argv[2], "wb") as output: plistlib.dump(entitlements, output)
PY
xcrun --sdk iphonesimulator swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -target "$PROBE_ARCH-apple-ios17.0-simulator" -sdk "$PROBE_SDK" \
    -module-name KeychainProbe -framework UIKit -framework Security -framework Foundation \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$PROBE_BUILD_DIR/probe.entitlements" \
    "${PROBE_SOURCES[@]}" -o "$PROBE_APP/KeychainProbe"
shasum -a 256 -c "$PROBE_BUILD_DIR/source-sha256.txt" >/dev/null

# Simulator security reads these simulated entitlements from the Mach-O section.
# Restrictive iOS entitlements in the host ad-hoc signature instead deny launch (POSIX163).
python3 - "$PROBE_APP/KeychainProbe" "$PROBE_BUNDLE_ID" <<'PY'
import pathlib, plistlib, struct, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
if struct.unpack_from("<I", data)[0] != 0xfeedfacf: raise SystemExit("Expected one 64-bit Simulator architecture.")
offset, found = 32, None
for _ in range(struct.unpack_from("<I", data, 16)[0]):
    command, size = struct.unpack_from("<II", data, offset)
    if command == 0x19:
        for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
            section = offset + 72 + index * 80
            if data[section:section + 16].rstrip(b"\0") == b"__entitlements" and data[section + 16:section + 32].rstrip(b"\0") == b"__TEXT":
                length = struct.unpack_from("<Q", data, section + 40)[0]
                start = struct.unpack_from("<I", data, section + 48)[0]
                found = plistlib.loads(data[start:start + length])
    offset += size
expected = {"application-identifier": sys.argv[2], "keychain-access-groups": [sys.argv[2]]}
if found != expected: raise SystemExit("Probe entitlement section must grant only its own identity.")
PY

xattr -cr "$PROBE_APP"
codesign --force --sign - --timestamp=none --identifier "$PROBE_BUNDLE_ID" "$PROBE_APP" >/dev/null
codesign --verify --strict "$PROBE_APP"
xcrun simctl install "$SIMULATOR_ID" "$PROBE_APP"
PROBE_INSTALLED=true
PROBE_DATA_DIR="$(xcrun simctl get_app_container "$SIMULATOR_ID" "$PROBE_BUNDLE_ID" data)"
rm -f "$PROBE_DATA_DIR/Documents/keychain-report.json"
xcrun simctl launch "$SIMULATOR_ID" "$PROBE_BUNDLE_ID" >/dev/null

python3 - "$PROBE_DATA_DIR/Documents/keychain-report.json" "${PROBE_REPORT_PATH:-}" <<'PY'
import json, pathlib, sys, time
report = pathlib.Path(sys.argv[1])
for _ in range(150):
    if report.is_file(): break
    time.sleep(0.1)
else: raise SystemExit("Probe did not produce its own status report.")
value = json.loads(report.read_text())
expected = {"preflight", "write", "read", "update", "delete", "cleanup", "all_passed"}
if set(value) != expected | {key + "_status" for key in expected - {"all_passed"}}:
    raise SystemExit("Unexpected probe report fields.")
if not all(type(value[key]) is bool for key in expected): raise SystemExit("Invalid Boolean status report.")
if not all(type(item) in (bool, int) for item in value.values()): raise SystemExit("Report contains non-status data.")
if sys.argv[2]:
    output = pathlib.Path(sys.argv[2]); output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
print(json.dumps(value, sort_keys=True))
if not all(value[key] is True for key in expected): raise SystemExit(1)
if not all(value[key] == 0 for key in value if key.endswith("_status")): raise SystemExit(1)
PY
cat "$PROBE_BUILD_DIR/source-sha256.txt"
