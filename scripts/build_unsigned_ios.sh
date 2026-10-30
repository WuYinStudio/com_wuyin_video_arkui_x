#!/usr/bin/env bash
#
# Build an unsigned iOS .ipa on macOS.
#
# Prerequisites:
#   1. macOS + Xcode (xcodebuild available)
#   2. .arkui-x/ios/frameworks/libarkui_ios.xcframework
#      (from the macOS ArkUI-X SDK; the Windows SDK does not include it)
#   3. .arkui-x/ios/arkui-x/{entry,systemres}
#      (prebuilt by `ace build bundle`)
#
# Usage:
#   bash scripts/build_unsigned_ios.sh
#   IOS_CONFIGURATION=Debug bash scripts/build_unsigned_ios.sh
#
# Output:
#   build/ios-unsigned/app-unsigned.ipa
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$ROOT/.arkui-x/ios"
PROJECT="$IOS_DIR/app.xcodeproj"
FRAMEWORK="$IOS_DIR/frameworks/libarkui_ios.xcframework"
ASSETS="$IOS_DIR/arkui-x"
OUT="${IOS_OUT_DIR:-$ROOT/build/ios-unsigned}"
CONFIG="${IOS_CONFIGURATION:-Release}"

log() { printf '[ios-unsigned] %s\n' "$*"; }
die() { printf '[ios-unsigned] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "iOS builds require macOS + Xcode (current: $(uname -s))."
fi

command -v xcodebuild >/dev/null 2>&1 \
  || die "xcodebuild not found; install Xcode and run xcode-select --install."

[[ -d "$PROJECT" ]] || die "Missing Xcode project: $PROJECT"
[[ -d "$FRAMEWORK" ]] || die "Missing framework: $FRAMEWORK
Copy libarkui_ios.xcframework from the macOS ArkUI-X SDK into that directory."
[[ -f "$ASSETS/entry/ets/modules.abc" ]] || die "Missing ArkTS assets: $ASSETS/entry/ets/modules.abc"
[[ -d "$ASSETS/systemres" ]] || die "Missing system resources: $ASSETS/systemres"

rm -rf "$OUT"
mkdir -p "$OUT/Products" "$OUT/ipa"

log "Xcode: $(xcodebuild -version | tr '\n' ' ')"
log "Building $CONFIG for iphoneos (code signing disabled)..."

set +e
xcodebuild \
  -project "$PROJECT" \
  -target app \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$OUT/Products" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  IPHONEOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}" \
  build
status=$?
set -e

if [ "$status" -ne 0 ]; then
  die "xcodebuild failed with exit code ${status}."
fi

APP="$OUT/Products/app.app"
[[ -d "$APP" ]] || die "Build succeeded but product not found: $APP"

mkdir -p "$OUT/ipa/Payload"
ditto "$APP" "$OUT/ipa/Payload/app.app"
( cd "$OUT/ipa" && /usr/bin/zip -qry "$OUT/app-unsigned.ipa" Payload )

log "Unsigned app: $APP"
log "Unsigned IPA: $OUT/app-unsigned.ipa"
log "Note: an unsigned IPA cannot be installed on a stock device; re-sign it first."
