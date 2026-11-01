#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/.build/DerivedData}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/.build/artifacts}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PROJECT_ROOT/.build/YapperNative.xcarchive}"
MODE="${1:-simulator}"
VERSION="0.2.3"
mkdir -p "$OUTPUT_DIR"
args=(-project "$PROJECT_ROOT/YapperNative.xcodeproj" -scheme YapperNative -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO)
args+=(-onlyUsePackageVersionsFromResolvedFile)
if [[ -n "${SOURCE_PACKAGES_DIR:-}" ]]; then
  args+=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR")
fi

case "$MODE" in
  simulator)
    xcodebuild "${args[@]}" -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
    # Sign outside synced build directories, whose Finder metadata can be recreated while signing.
    simulator_staging="$(mktemp -d "${TMPDIR:-/tmp}/yapper-native-simulator.XXXXXX")"
    trap 'rm -rf "$simulator_staging"' EXIT
    simulator_app="$simulator_staging/YapperNative.app"
    ditto --norsrc --noextattr --noqtn "$DERIVED_DATA/Build/Products/Release-iphonesimulator/YapperNative.app" "$simulator_app"
    xattr -cr "$simulator_app"
    for dependency in "$simulator_app"/Frameworks/*.framework "$simulator_app"/Frameworks/*.dylib; do
      if [[ -e "$dependency" ]]; then codesign --force --sign - "$dependency"; fi
    done
    # Host signatures must not claim iOS-only restricted entitlements. The linker section above
    # supplies the Simulator's own identity, independently from the plain local host signature.
    codesign --force --sign - --identifier website.yapper.native.ios "$simulator_app"
    codesign --verify --deep --strict "$simulator_app"
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$simulator_app" "$OUTPUT_DIR/Yapinplugger-Native-$VERSION-iOS-Simulator.zip"
    ;;
  archive)
    xcodebuild "${args[@]}" -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" SKIP_INSTALL=NO archive
    package_staging="$(mktemp -d "$OUTPUT_DIR/.native-ipa.XXXXXX")"
    trap 'rm -rf "$package_staging"' EXIT
    mkdir "$package_staging/Payload"
    ditto --norsrc --noextattr --noqtn "$ARCHIVE_PATH/Products/Applications/YapperNative.app" "$package_staging/Payload/YapperNative.app"
    ditto --norsrc --noextattr --noqtn -c -k --keepParent "$package_staging/Payload" "$OUTPUT_DIR/Yapinplugger-Native-$VERSION-ios-unsigned.ipa"
    printf '%s\n' 'Sign the unsigned IPA with your own Apple profile before installing on an iPhone or iPad.'
    ;;
  test)
    : "${SIMULATOR_ID:?Set SIMULATOR_ID to a dedicated iOS simulator UDID}"
    xcodebuild "${args[@]}" -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" test
    ;;
  *) printf 'Usage: %s {simulator|archive|test}\n' "$0" >&2; exit 2 ;;
esac
