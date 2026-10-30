#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/.build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/.build/artifacts}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/.build/Yapper.xcarchive}"
MODE="${1:-simulator}"
VERSION="1.1.0"
EXTENSION_TAG="-YapperCord-0.1.0"
mkdir -p "$OUTPUT_DIR"

build_args=(-project "$PROJECT_ROOT/Yapper.xcodeproj" -scheme Yapper -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO)

case "$MODE" in
  simulator)
    xcodebuild "${build_args[@]}" -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
    APP_PATH="$DERIVED_DATA/Build/Products/Release-iphonesimulator/Yapper.app"
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$APP_PATH" "$OUTPUT_DIR/Yapper-$VERSION$EXTENSION_TAG-iOS-Simulator.zip"
    printf '\nSimulator application: %s\nArchive: %s\n' "$APP_PATH" "$OUTPUT_DIR/Yapper-$VERSION$EXTENSION_TAG-iOS-Simulator.zip"
    ;;
  test)
    if [[ -z "${SIMULATOR_ID:-}" ]]; then
      printf '%s\n' 'Set SIMULATOR_ID to an available iPhone or iPad simulator UDID.' >&2
      exit 2
    fi
    RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-$OUTPUT_DIR/Yapper-Tests-$(date -u +%Y%m%dT%H%M%SZ).xcresult}"
    xcodebuild "${build_args[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -resultBundlePath "$RESULT_BUNDLE_PATH" test
    printf '\nTest result bundle: %s\n' "$RESULT_BUNDLE_PATH"
    ;;
  archive)
    xcodebuild "${build_args[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" SKIP_INSTALL=NO archive
    STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.unsigned-ipa.XXXXXX")"
    trap 'rm -rf "$STAGING_DIR"' EXIT
    mkdir "$STAGING_DIR/Payload"
    ditto --norsrc --noextattr --noqtn "$ARCHIVE_PATH/Products/Applications/Yapper.app" "$STAGING_DIR/Payload/Yapper.app"
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$STAGING_DIR/Payload" "$OUTPUT_DIR/Yapper-$VERSION$EXTENSION_TAG-ios-unsigned.ipa"
    printf '\nUnsigned iOS archive: %s\nUnsigned IPA: %s\n' "$ARCHIVE_PATH" "$OUTPUT_DIR/Yapper-$VERSION$EXTENSION_TAG-ios-unsigned.ipa"
    printf '%s\n' 'This unsigned IPA must be signed with your own Apple development or distribution profile before installation on an iPhone or iPad.'
    ;;
  *)
    printf 'Usage: %s {simulator|test|archive}\n' "$0" >&2
    exit 2
    ;;
esac
