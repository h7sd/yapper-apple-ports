#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/.build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/.build/artifacts}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/.build/YapperNative.xcarchive}"
MODE="${1:-simulator}"
mkdir -p "$OUTPUT_DIR"
args=(-project "$PROJECT_ROOT/YapperNative.xcodeproj" -scheme YapperNative -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO)

case "$MODE" in
  simulator)
    xcodebuild "${args[@]}" -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$DERIVED_DATA/Build/Products/Release-iphonesimulator/YapperNative.app" "$OUTPUT_DIR/Yapinplugger-Native-0.1.0-iOS-Simulator.zip"
    ;;
  archive)
    xcodebuild "${args[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" SKIP_INSTALL=NO archive
    package_staging="$(mktemp -d "$OUTPUT_DIR/.native-ipa.XXXXXX")"
    trap 'rm -rf "$package_staging"' EXIT
    mkdir "$package_staging/Payload"
    ditto --norsrc --noextattr --noqtn "$ARCHIVE_PATH/Products/Applications/YapperNative.app" "$package_staging/Payload/YapperNative.app"
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$package_staging/Payload" "$OUTPUT_DIR/Yapinplugger-Native-0.1.0-ios-unsigned.ipa"
    printf '%s\n' 'Sign the unsigned IPA with your own Apple profile before installing on an iPhone or iPad.'
    ;;
  test)
    : "${SIMULATOR_ID:?Set SIMULATOR_ID to a dedicated iOS simulator UDID}"
    xcodebuild "${args[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" test
    ;;
  *) printf 'Usage: %s {simulator|archive|test}\n' "$0" >&2; exit 2 ;;
esac
